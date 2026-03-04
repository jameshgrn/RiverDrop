# App Sandbox Review — RiverDrop

Reviewed files: `RsyncTransfer.swift`, `RipgrepSearch.swift`, `RemoteRipgrepSearch.swift`, `SFTPService.swift`, `SSHKeyManager.swift`, `RiverDrop.entitlements`, `LocalBrowserView.swift`, `TransferManager.swift`, `ConnectionView.swift`, `MainView.swift`, `KeychainHelper.swift`.

Entitlements in scope:

```xml
com.apple.security.app-sandbox            = true
com.apple.security.network.client         = true
com.apple.security.files.user-selected.read-write = true
com.apple.security.files.bookmarks.app-scope      = true
```

---

## 1. Process Spawning Under Sandbox

### 1A — Executing Homebrew binaries (rsync, rg)

**Files:** `RsyncTransfer.swift:13-20`, `RipgrepSearch.swift:73-80`

```swift
// RsyncTransfer.swift
for path in ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/usr/bin/rsync"] {
    if FileManager.default.isExecutableFile(atPath: path) { ... }
}

// RipgrepSearch.swift
for path in ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"] {
    if FileManager.default.isExecutableFile(atPath: path) { ... }
}
```

**Behavior:** Works under sandbox. The default App Sandbox profile allows `file-read*` and `process-exec*` for binaries outside protected directories. `/opt/homebrew/bin/` and `/usr/local/bin/` are not privacy-restricted, so `isExecutableFile(atPath:)` returns the correct result and `Process.run()` succeeds.

**Child sandbox inheritance:** The child process (rsync, rg) inherits the parent's full sandbox profile, including:
- `com.apple.security.network.client` — rsync's SSH subprocess can make outbound TCP connections
- Active sandbox extensions from `startAccessingSecurityScopedResource()` — child can access user-selected files IF the extension is active when the child is spawned
- Container access — child can read/write the app's sandbox container (including temp directory)

**Verdict:** No issue with binary execution itself.

---

### 1B — rsync cannot read SSH keys: `copySSHKeyToTemp` missing security-scoped access

**File:** `RsyncTransfer.swift:495-505`

```swift
private func copySSHKeyToTemp(_ keyPath: String) throws -> String {
    let src = URL(fileURLWithPath: keyPath)              // e.g. ~/.ssh/id_ed25519
    let dst = FileManager.default.temporaryDirectory
        .appendingPathComponent("riverdrop_sshkey_\(UUID().uuidString)")
    try FileManager.default.copyItem(at: src, to: dst)  // SANDBOX VIOLATION
    ...
}
```

**Severity: HIGH — will throw at runtime, rsync transfers fail silently or with a confusing error.**

`~/.ssh/` is inside the user's home directory and is not accessible under App Sandbox by default. The user selected the key via `NSOpenPanel` in `ConnectionView.browseForKey()` (line 398-421) and `SSHKeyManager.saveBookmark(for:)` saved a security-scoped bookmark. But `copySSHKeyToTemp` never resolves that bookmark — it reads the raw path.

Meanwhile, `SSHKeyManager.buildAuthMethod` (line 90-103) correctly calls `startAccessing(path:)` to read the key for Citadel's in-process SSH. The same pattern is needed here.

**Call chain:**
1. `TransferManager.resolveRsyncAuth()` extracts the raw `keyPath` string from `sftpService.connectedAuthConfig`
2. `RsyncTransfer.run()` receives `.sshKey(path: keyPath, ...)`
3. `copySSHKeyToTemp(keyPath)` tries `FileManager.copyItem` on the raw path — **sandbox denies it**

**Fix:**

```swift
private func copySSHKeyToTemp(_ keyPath: String) throws -> String {
    let dst = FileManager.default.temporaryDirectory
        .appendingPathComponent("riverdrop_sshkey_\(UUID().uuidString)")

    // Resolve security-scoped bookmark so the sandbox allows reading the key.
    if let scopedURL = SSHKeyManager.startAccessing(path: keyPath) {
        defer { scopedURL.stopAccessingSecurityScopedResource() }
        try FileManager.default.copyItem(at: scopedURL, to: dst)
    } else {
        // Fallback for paths inside the container or already accessible.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: keyPath), to: dst)
    }

    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: dst.path
    )
    return dst.path
}
```

---

### 1C — rsync accessing user-selected local files

**Files:** `RsyncTransfer.swift:150-170` (upload), `RsyncTransfer.swift:257-276` (download)

rsync receives local file paths as string arguments. For the child process to access those paths, the parent must have an active security-scoped extension when the child is spawned (extensions are inherited via the sandbox).

**Current state:** `LocalBrowserView` maintains `activeSecurityScopedURL` which is started when the user navigates to a directory and stopped in `onDisappear` (line 114-116). As long as the view is on screen, rsync can access the directory.

**Risk:** If `LocalBrowserView` disappears while an rsync transfer is in progress (unlikely in the current two-pane layout but possible during window close or view rebuild), `stopSecurityScopedAccess()` fires and revokes the extension. The rsync child may lose access mid-transfer.

**Verdict:** Low risk in practice. Would become a problem if the UI architecture changes (e.g., tab-based views where the local pane can be hidden). A safer design would have `TransferManager` independently start/stop security-scoped access for the duration of each transfer.

---

## 2. Security-Scoped Resources

### 2A — SSH key reading in `SSHKeyManager.buildAuthMethod` — correctly handled

**File:** `SSHKeyManager.swift:83-103`

```swift
if let scopedURL = startAccessing(path: keyPath) {
    defer { scopedURL.stopAccessingSecurityScopedResource() }
    keyString = try String(contentsOf: scopedURL, encoding: .utf8)
} else {
    keyString = try String(contentsOfFile: keyPath, encoding: .utf8)  // fallback
}
```

This is correct. `startAccessing` resolves the bookmark, starts scoped access, and the `defer` stops it. Used by Citadel for in-process SSH connections.

### 2B — Temp directory usage is correct

**File:** `RsyncTransfer.swift:452, 471, 497`

`FileManager.default.temporaryDirectory` resolves to the app's sandbox container temp dir (`~/Library/Containers/<bundle-id>/Data/tmp/`). All temp files (askpass scripts, known_hosts, SSH key copies) are written here. Child processes inherit container access, so rsync and its SSH subprocess can read these files.

### 2C — Stale bookmark refresh

**File:** `SSHKeyManager.swift:69-70`

```swift
if isStale {
    try? saveBookmark(for: url)
}
```

Stale bookmarks are refreshed on access. The `try?` silently discards errors, which means a stale bookmark that can't be refreshed will work this session but fail on next launch. Consider logging the failure.

### 2D — `RipgrepSearch` double-scoping is safe

**File:** `RipgrepSearch.swift:118-122`

`RipgrepSearch.search()` calls `startAccessingSecurityScopedResource()` on the same URL that `LocalBrowserView` already has active. This is fine — `startAccessing`/`stopAccessing` is reference-counted. The extra start/stop pair from `RipgrepSearch` doesn't interfere.

---

## 3. File Access Patterns

### 3A — `MainView.navigateLocalToCommandPath` does not save bookmark or start scoped access

**File:** `MainView.swift:712-725`

```swift
private func navigateLocalToCommandPath(_ path: String) {
    if path == AppCommandPayload.openPanel {
        let panel = NSOpenPanel()
        ...
        if panel.runModal() == .OK, let url = panel.url {
            localCurrentDirectory = url   // NO bookmark saved, NO scoped access started
        }
        return
    }
    localCurrentDirectory = URL(fileURLWithPath: path)  // same problem
}
```

**Severity: MEDIUM — works on first use, breaks on relaunch.**

When the user selects a folder via this code path, the sandbox temporarily grants access (NSOpenPanel's implicit extension lasts until the next event loop tick or longer). `LocalBrowserView.requestInitialAccess()` will fire on appear and may catch it, but:
- No bookmark is persisted, so next launch the directory is inaccessible
- If the URL from the panel is consumed after the implicit extension expires, `loadDirectory()` silently returns empty results

**Fix:** Mirror the pattern from `LocalBrowserView.openPanel()`:

```swift
if panel.runModal() == .OK, let url = panel.url {
    // Save bookmark for persistence across launches.
    let data = try? url.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    )
    if let data {
        UserDefaults.standard.set(data, forKey: DefaultsKey.sandboxBookmarkPrefix + url.path)
    }
    localCurrentDirectory = url
}
```

### 3B — `LocalBrowserView` bookmark management is well-implemented

**File:** `LocalBrowserView.swift:842-913`

The `requestInitialAccess` → `restoreSavedBookmark` → `beginSecurityScopedAccess` → `saveBookmark` chain is correct:
- NSOpenPanel results are bookmarked with `.withSecurityScope`
- Bookmarks are resolved with `.withSecurityScope` on restore
- Stale bookmarks are refreshed
- `beginSecurityScopedAccess` properly stops previous access before starting new access
- `stopSecurityScopedAccess` is called in `onDisappear`

### 3C — `ConnectionView.browseForKey` correctly saves bookmark

**File:** `ConnectionView.swift:398-421`

```swift
if panel.runModal() == .OK, let url = panel.url {
    try SSHKeyManager.saveBookmark(for: url)   // correct
    ...
}
```

NSOpenPanel result is immediately bookmarked. No issue.

### 3D — Default bookmarks to hardcoded paths

**File:** `LocalBrowserView.swift:44-48`

```swift
("Projects", "/Users/\(NSUserName())/projects"),
("Home", "/Users/\(NSUserName())"),
("Cluster Scratch", "/not_backed_up/\(NSUserName())"),
```

These paths are not accessible under sandbox by default. `navigateToBookmark` (line 791-808) handles this correctly: it tries to restore a saved bookmark, checks readability, and falls back to prompting via `NSOpenPanel`. No issue.

---

## 4. Network Access

### 4A — `com.apple.security.network.client` covers all outbound connections

The entitlement grants unrestricted outbound TCP/UDP. This covers:
- **Citadel SSH** (NIO raw TCP sockets) on any port — works
- **rsync over SSH** (rsync → ssh → TCP) — works, child inherits the sandbox extension
- **SFTP** (over SSH) — works

No port restriction exists in `network.client`. SSH on non-standard ports is covered.

### 4B — No inbound entitlement

The app does not have `com.apple.security.network.server`. This is correct — the app is a client, not a server. If a future feature needs to listen (e.g., receiving push notifications via a local socket), this would need to be added.

---

## 5. Process Lifecycle

### 5A — `SFTPService.runProcess` blocks the main thread

**File:** `SFTPService.swift:162-176`

```swift
private func runProcess(path: String, args: [String]) async -> Bool {
    ...
    try process.run()
    process.waitUntilExit()  // BLOCKS CALLING THREAD
    return process.terminationStatus == 0
}
```

**Severity: MEDIUM — UI freeze.**

`runProcess` is called from `runKinitKlog()`, which is called from `connect()`, which runs on `@MainActor`. Despite the `async` signature, `waitUntilExit()` is a synchronous blocking call that holds the main thread until the process terminates. If `kinit -R` hangs (network timeout, waiting for input), the entire UI freezes.

**Fix:** Move to async process monitoring:

```swift
private func runProcess(path: String, args: [String]) async -> Bool {
    guard FileManager.default.isExecutableFile(atPath: path) else { return false }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return false
    }

    return await withCheckedContinuation { continuation in
        process.terminationHandler = { proc in
            continuation.resume(returning: proc.terminationStatus == 0)
        }
    }
}
```

### 5B — No zombie risk in `RsyncTransfer`

**File:** `RsyncTransfer.swift:195-212`

`Process` in Foundation uses `kqueue`/dispatch to monitor child PIDs. When the child exits, the internal handler calls `waitpid`. Setting `terminationHandler` ensures the process is reaped. Even if the `RsyncTransfer` instance is deallocated (via `[weak self]` in the handler), Foundation's internal monitoring still reaps the child. No zombie risk.

### 5C — No zombie risk in `RipgrepSearch`

**File:** `RipgrepSearch.swift:156-166, 200-206`

On `cancel()`, `process?.terminate()` sends SIGTERM and `process = nil` drops the reference. The `terminationHandler` closure captures `[weak self]` so it handles deallocation gracefully. Foundation reaps the child regardless. No zombie risk.

### 5D — `RsyncTransfer.cancel()` is safe

**File:** `RsyncTransfer.swift:24-30`

```swift
func cancel() {
    let proc = lock.withLock {
        isCancelled = true
        return process
    }
    proc?.terminate()
}
```

The lock ensures `isCancelled` and `process` are read atomically. `terminate()` sends SIGTERM. The `terminationHandler` checks for cancellation and resumes the continuation with `CancellationError()`. The `AtomicFlag` (line 513-525) ensures the continuation is resumed exactly once even if the readability handler and termination handler race. No double-resume risk.

### 5E — Pipe deadlock risk in dry run

**File:** `RsyncTransfer.swift:414-416`

```swift
let stdoutData = await Task.detached { stdoutHandle.readDataToEndOfFile() }.value
let stderrData = await Task.detached { stderrHandle.readDataToEndOfFile() }.value
await Task.detached { proc.waitUntilExit() }.value
```

Both stdout and stderr are read on separate detached tasks before waiting for exit. This avoids the classic deadlock where the child blocks writing to a full pipe buffer while the parent blocks on `waitUntilExit`. Correct pattern.

---

## 6. Additional Security Observations

### 6A — Passwords written to disk in askpass scripts

**File:** `RsyncTransfer.swift:451-463`

```swift
let content = "#!/bin/sh\necho '\(escaped)'\n"
FileManager.default.createFile(atPath: scriptPath, contents: content.data(using: .utf8))
```

The SSH password or key passphrase is written to a shell script in the temp directory. While the file has mode `0700`, uses a UUID filename, and is cleaned up in a `defer` block, the plaintext secret is on disk for the duration of the rsync transfer.

**Risks:**
- If the app crashes between creating the script and the `defer` cleanup, the secret persists until the OS cleans temp files
- Any process with sandbox container access (same app, or via a vulnerability) can read it
- The file may be captured by Time Machine or Spotlight indexing (though the sandbox container temp dir is usually excluded)

**Mitigation:** This is a known limitation of the `SSH_ASKPASS` mechanism — it requires an executable that prints the password. There is no cleaner alternative for non-interactive SSH password entry in subprocess-based workflows. The current approach (UUID filename, mode 0700, defer cleanup) is the standard best practice.

### 6B — Keychain access works correctly under sandbox

**File:** `KeychainHelper.swift`

Sandboxed apps have full access to their keychain access group. The `SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete` calls use `kSecClassGenericPassword` with a per-app service identifier (`com.riverdrop.sftp`, `com.riverdrop.hostkeys`). These are scoped to the app's keychain group automatically. No issue.

### 6C — Shell injection in rsync SSH command

**File:** `RsyncTransfer.swift:125, 140`

```swift
var sshCommand = "ssh -T -o ... -o UserKnownHostsFile=\(shellQuote(knownHostsPath))"
sshCommand += " -i \(shellQuote(tempKeyPath)) -o IdentitiesOnly=yes"
```

The `sshCommand` string is passed as a single argument to rsync's `-e` flag. rsync then passes it to `system()` or `popen()` to spawn SSH. The paths are wrapped in `shellQuote` (single-quote escaping, line 507-509) which prevents injection. The only user-controlled values in the SSH command are paths generated by the app (temp directory + UUID), so injection is not possible. No issue.

---

## Summary Table

| # | Issue | Severity | Symptom | File:Line |
|---|-------|----------|---------|-----------|
| 1B | `copySSHKeyToTemp` missing security-scoped access | **HIGH** | rsync transfers fail — `copyItem` throws permission error when reading `~/.ssh/*` | `RsyncTransfer.swift:495-505` |
| 3A | `navigateLocalToCommandPath` doesn't save bookmark | **MEDIUM** | Folder access lost on relaunch; directory listing may silently empty | `MainView.swift:712-725` |
| 5A | `runProcess` blocks main thread with `waitUntilExit` | **MEDIUM** | UI freeze if `kinit -R` or `klog` hangs | `SFTPService.swift:170-171` |
| 1C | Security scope revoked if `LocalBrowserView` disappears during transfer | **LOW** | rsync loses file access mid-transfer; unlikely in current UI | `LocalBrowserView.swift:114-116` |
| 2C | Stale bookmark refresh error silently discarded | **LOW** | Bookmark works this session, silently fails next launch | `SSHKeyManager.swift:69-70` |
| 6A | Password plaintext in temp askpass script | **INFO** | Acceptable tradeoff; standard SSH_ASKPASS pattern | `RsyncTransfer.swift:451-463` |
