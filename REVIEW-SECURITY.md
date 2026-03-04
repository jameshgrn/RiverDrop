# RiverDrop Security Audit

Audited files: `SSHKeyManager.swift`, `RsyncTransfer.swift`, `KeychainHelper.swift`,
`SFTPService.swift`, `RemoteRipgrepSearch.swift`, `RiverDrop.entitlements`

---

## 1. Command Injection

### 1a. Askpass script embeds password in shell script (Medium)

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-security/RiverDrop/RsyncTransfer.swift:451-463`

The `createAskpassScript` writes a shell script containing the user's password:

```swift
let escaped = password.replacingOccurrences(of: "'", with: "'\\''")
let content = "#!/bin/sh\necho '\(escaped)'\n"
```

The single-quote escaping (`'` → `'\''`) is the correct POSIX technique and prevents shell breakout. However, `echo` has implementation-defined behavior for backslash sequences. A password containing `\n`, `\t`, `\c`, etc. may be silently mangled by some `echo` implementations, causing auth failures that are difficult to debug.

**Fix:** Replace `echo` with `printf '%s\n'`:
```swift
let content = "#!/bin/sh\nprintf '%s\\n' '\(escaped)'\n"
```

### 1b. Remote ripgrep command — escaping is correct (Info)

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-security/RiverDrop/RemoteRipgrepSearch.swift:54-59`

```swift
let escapedQuery = trimmed.replacingOccurrences(of: "'", with: "'\\''")
let escapedDir = directory.replacingOccurrences(of: "'", with: "'\\''")
let rgCommand = "rg --json --max-count \(maxCount) --max-columns \(maxColumns) -- '\(escapedQuery)' '\(escapedDir)' 2>/dev/null"
```

The escaping is correct. The `--` separator prevents query strings starting with `-` from being interpreted as flags. `maxCount`/`maxColumns` are `Int` types — cannot contain metacharacters. The command runs via `inShell: true` on the remote SSH server, so it's interpreted by the remote shell. POSIX single-quote escaping is safe for all POSIX-compatible shells (`sh`, `bash`, `zsh`, `dash`).

No action required.

### 1c. Rsync arguments use Process.arguments array, not shell (Info)

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-security/RiverDrop/RsyncTransfer.swift:150-161`

The `source` and `destination` strings (containing user-supplied hostname, username, and remote path) are passed as elements of `Process.arguments`. Swift's `Process` passes these as `argv` entries directly to `execve`, NOT through a shell. This means shell metacharacters in hostnames or paths cannot cause injection.

The `-e` ssh command string IS parsed by rsync and handed to a shell, but the only interpolated values within it are `shellQuote(knownHostsPath)` and `shellQuote(tempKeyPath)`, both UUID-based temp paths generated internally. The `shellQuote` function at line 507 uses the same correct `'\''` technique.

No action required.

### 1d. known_hosts file content not validated (Low)

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-security/RiverDrop/RsyncTransfer.swift:466-487`

```swift
let content = "\(host) \(openSSHKey)\n"
```

The `host` value is interpolated directly into the known_hosts file. If a hostname contains spaces, newlines, or hash characters, the known_hosts format would be malformed. This isn't command injection — SSH would reject the malformed file and rsync would fail to connect. But a crafted hostname like `evil.com ssh-ed25519 AAAA... \ngood.com` could inject a second known_hosts entry, though this requires controlling both the hostname field in the UI AND having the corresponding private key for the injected host. Practical exploitability is very low.

**Fix:** Validate hostname against a strict pattern (alphanumeric, hyphens, dots) before writing to known_hosts:
```swift
let hostnamePattern = /^[a-zA-Z0-9][a-zA-Z0-9.\-]+$/
guard host.wholeMatch(of: hostnamePattern) != nil else {
    throw RsyncError.invalidHostname(host)
}
```

---

## 2. SSH Key Handling

### 2a. Askpass script created world-readable before chmod (Medium)

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-security/RiverDrop/RsyncTransfer.swift:458-462`

```swift
FileManager.default.createFile(atPath: scriptPath, contents: content.data(using: .utf8))
try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: scriptPath
)
```

`createFile(atPath:contents:)` does not accept a permissions parameter. The file is created with the process's umask (typically 0022 on macOS), resulting in 0644 permissions — **world-readable**. The plaintext password/passphrase sits on disk in a world-readable file until `setAttributes` runs on the next line.

The sandbox container's temp directory (`~/Library/Containers/.../tmp/`) limits exposure to unsandboxed processes and root, but the TOCTOU window still exists.

**Fix:** Use POSIX `open()` with explicit mode to create the file atomically with correct permissions:
```swift
import Darwin

let fd = scriptPath.withCString { path in
    Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o700)
}
guard fd >= 0 else { throw /* error */ }
defer { Darwin.close(fd) }
let data = content.data(using: .utf8)!
data.withUnsafeBytes { buf in
    _ = Darwin.write(fd, buf.baseAddress!, buf.count)
}
```

### 2b. Temp SSH key copy inherits source permissions (Low)

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-security/RiverDrop/RsyncTransfer.swift:495-505`

```swift
try FileManager.default.copyItem(at: src, to: dst)
try FileManager.default.setAttributes(
    [.posixPermissions: 0o600],
    ofItemAtPath: dst.path
)
```

`copyItem` preserves the source file's permissions. If the user's key is properly 0600, the copy will also be 0600 before `setAttributes`. The `setAttributes` call is defense-in-depth. Unlike the askpass case, there's no TOCTOU window *if* the source file has restrictive permissions. If the user's key somehow has lax permissions (e.g., 0644), the copy would also be 0644 briefly.

The same POSIX `open()` + `write()` approach from 2a would eliminate any TOCTOU window.

**Fix:** Same as 2a — create the destination file with `open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)` and write the key data to the file descriptor rather than using `copyItem`.

### 2c. Temp file cleanup relies on defer — crash leaves secrets on disk (Low)

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-security/RiverDrop/RsyncTransfer.swift:119-120`

```swift
var tempFiles: [String] = []
defer { for path in tempFiles { try? FileManager.default.removeItem(atPath: path) } }
```

The `defer` block handles normal completion, throws, and cancellation. However, if the app is force-killed (SIGKILL, crash, power loss), temp files containing the SSH private key and password remain in the temp directory indefinitely. The files have UUID-based names so they're not discoverable by name, but `ls /tmp/` or `find` would reveal them.

**Fix:** Consider adding a startup sweep that deletes stale `riverdrop_*` files from the temp directory:
```swift
func cleanupStaleTempFiles() {
    let tmp = FileManager.default.temporaryDirectory
    let items = try? FileManager.default.contentsOfDirectory(atPath: tmp.path)
    for item in items ?? [] where item.hasPrefix("riverdrop_") {
        try? FileManager.default.removeItem(atPath: tmp.appendingPathComponent(item).path)
    }
}
```

---

## 3. Keychain Usage

### 3a. Missing kSecAttrAccessible on all keychain items (Medium)

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-security/RiverDrop/KeychainHelper.swift:19-24` and `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-security/RiverDrop/KeychainHelper.swift:104-110`

Neither `KeychainHelper.save` nor `HostKeyKeychainHelper.save` sets `kSecAttrAccessible`. The default is `kSecAttrAccessibleWhenUnlocked`, which means items are available whenever the device is unlocked. This is functionally acceptable but should be explicit. For host keys specifically, `kSecAttrAccessibleAfterFirstUnlock` would allow background reconnection after a reboot without requiring the user to unlock.

**Fix:** Add to both save queries:
```swift
kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
```

Or for host keys (to support background reconnection):
```swift
kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
```

### 3b. HostKeyKeychainHelper.save silently discards errors (Medium)

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-security/RiverDrop/KeychainHelper.swift:110`

```swift
SecItemAdd(addQuery as CFDictionary, nil)
```

The return value of `SecItemAdd` is discarded. If the save fails (keychain locked, disk full, quota), the host key isn't persisted but the app doesn't know. On the next connection, `HostKeyStore.load(for: host)` returns `nil`, so `TOFUHostKeyValidator` is initialized with `expectedOpenSSHKey: nil`, and **any key is accepted**. This creates a persistent TOFU-every-time condition — every connection to that host is vulnerable to MITM.

**Fix:** Make `save` throw on failure and propagate the error to the connection flow:
```swift
static func save(_ openSSHKey: String, for host: String) throws {
    // ... delete existing ...
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    guard status == errSecSuccess else {
        throw KeychainError.unexpectedStatus(operation: "save host key", status: status)
    }
}
```

In `SFTPService.connect`, handle the save error — at minimum log it, ideally warn the user.

### 3c. Keychain scoping is adequate for sandboxed apps (Info)

Both helpers use `kSecClassGenericPassword` with a unique `kSecAttrService` (`"com.riverdrop.sftp"` and `"com.riverdrop.hostkeys"`). In a sandboxed Mac app, keychain items are automatically scoped to the app's keychain access group (derived from the code-signing identity). Other sandboxed apps cannot read these items. No `kSecAttrAccessGroup` override is needed.

No action required.

---

## 4. Entitlements

### 4a. Entitlements are minimal and appropriate (Info)

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-security/RiverDrop/RiverDrop.entitlements`

| Entitlement | Purpose | Assessment |
|---|---|---|
| `com.apple.security.app-sandbox` | Enables sandbox | Required, correct |
| `com.apple.security.network.client` | Outbound network (SSH/SFTP) | Required for SSH connections |
| `com.apple.security.files.user-selected.read-write` | Read/write user-selected files | Required for file transfer |
| `com.apple.security.files.bookmarks.app-scope` | Security-scoped bookmarks | Required for remembering SSH keys and directories |

No overly broad entitlements. No `files.all.read-write`, no `network.server`, no `process.allow-unsigned-process`, no `temporary-exception.*`. This is a well-scoped entitlement set.

No action required.

---

## 5. Host Key Verification

### 5a. First connection silently accepts any host key (Medium)

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-security/RiverDrop/SFTPService.swift:497-511`

```swift
func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
    let observedKey = String(openSSHPublicKey: hostKey)
    if let expectedOpenSSHKey, expectedOpenSSHKey != observedKey {
        validationCompletePromise.fail(...)
        return
    }
    lock.withLock { acceptedKey = observedKey }
    validationCompletePromise.succeed(())
}
```

When `expectedOpenSSHKey` is `nil` (first connection to a host), the key is accepted without user confirmation. This is standard TOFU but means a MITM on the first connection is not detectable. The key is then stored in the keychain (assuming 3b doesn't silently fail) and subsequent connections are protected.

This is an inherent tradeoff of TOFU. Full mitigation would require showing the user the key fingerprint and asking for confirmation, as OpenSSH does with `StrictHostKeyChecking=ask`.

**Fix (recommended):** Display the server's key fingerprint (SHA-256 of the public key) to the user on first connection and require confirmation before proceeding. This could be done via a sheet/alert in the connection flow.

### 5b. Key mismatch shows raw base64 instead of fingerprints (Low)

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-security/RiverDrop/SFTPService.swift:523-524`

```swift
case let .hostKeyMismatch(expectedOpenSSHKey, observedOpenSSHKey):
    return "Host key mismatch. Expected \(expectedOpenSSHKey), received \(observedOpenSSHKey)"
```

The error message shows full OpenSSH public key strings (long base64 blobs). Users cannot meaningfully compare these. Industry standard is SHA-256 fingerprints (e.g., `SHA256:abc123...`).

**Fix:** Compute and display SHA-256 fingerprints of both keys.

### 5c. No UI path to accept a changed host key (Low)

When a host key changes (legitimate server rekey/reprovisioning), the connection fails with `hostKeyMismatch`. There's no mechanism in the app to delete the old stored key and accept the new one. The user would need to manually clear keychain entries.

**Fix:** Add a UI flow that, on key mismatch, shows both fingerprints and offers "Reject" / "Trust new key" options. If the user trusts the new key, call `HostKeyKeychainHelper.save` with the new key.

### 5d. Silent TOFU regression when keychain save fails (High)

This combines findings 3b and 5a. If `HostKeyKeychainHelper.save` fails silently (line 110), the host key is never persisted. Every subsequent connection to that host goes through TOFU again, silently accepting whatever key is presented. A MITM attacker doesn't even need to be present on the first connection — they can intercept any future connection and their key will be accepted.

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-security/RiverDrop/SFTPService.swift:59-61` + `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-security/RiverDrop/KeychainHelper.swift:110`

**Fix:** Same as 3b — make `HostKeyKeychainHelper.save` return or throw on failure. In `SFTPService.connect`, verify the save succeeded. If it fails, warn the user that host key verification is degraded.

---

## 6. Additional Findings

### 6a. SSH key bookmark data stored in UserDefaults (Low)

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-security/RiverDrop/SSHKeyManager.swift:47`

```swift
UserDefaults.standard.set(bookmarks, forKey: DefaultsKey.sshKeyBookmarks)
```

Security-scoped bookmark data is stored in `UserDefaults`, which writes to a plist on disk. Bookmark data is opaque blobs that resolve to file URLs — they don't contain the key material itself. However, they reveal the paths of SSH keys the user has imported, which is mild information disclosure. This is standard Apple API usage and the risk is minimal for a sandboxed app.

No action required.

### 6b. kinit/klog subprocess execution without output handling (Info)

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-security/RiverDrop/SFTPService.swift:152-176`

The `runKinitKlog()` method runs `/usr/bin/kinit -R` and `/usr/bin/klog` before each connection. These are standard Kerberos tools for HPC environments. The paths are hardcoded (no user input), arguments are static, and return values are checked. No security concern.

No action required.

---

## Summary

| # | Finding | Severity | File | Line(s) |
|---|---------|----------|------|---------|
| 5d | Silent TOFU regression when keychain save fails | **High** | KeychainHelper.swift + SFTPService.swift | 110, 59-61 |
| 2a | Askpass script world-readable before chmod (TOCTOU) | **Medium** | RsyncTransfer.swift | 458-462 |
| 3a | Missing kSecAttrAccessible on keychain items | **Medium** | KeychainHelper.swift | 19-24, 104-110 |
| 3b | HostKeyKeychainHelper.save silently discards errors | **Medium** | KeychainHelper.swift | 110 |
| 5a | First connection silently accepts any host key | **Medium** | SFTPService.swift | 497-511 |
| 1a | Askpass uses `echo` — backslash mangling risk | **Medium** | RsyncTransfer.swift | 456 |
| 1d | known_hosts hostname not validated | **Low** | RsyncTransfer.swift | 473 |
| 2b | Temp SSH key copy has minor TOCTOU window | **Low** | RsyncTransfer.swift | 499-503 |
| 2c | Crash leaves secrets in temp directory | **Low** | RsyncTransfer.swift | 119-120 |
| 5b | Key mismatch shows base64 instead of fingerprints | **Low** | SFTPService.swift | 523-524 |
| 5c | No UI to accept a legitimately changed host key | **Low** | SFTPService.swift | — |
| 6a | SSH key paths visible in UserDefaults plist | **Low** | SSHKeyManager.swift | 47 |
| 1b | Remote ripgrep escaping is correct | **Info** | RemoteRipgrepSearch.swift | 54-59 |
| 1c | Rsync uses argv array, no shell injection | **Info** | RsyncTransfer.swift | 150-161 |
| 3c | Keychain scoping adequate for sandboxed app | **Info** | KeychainHelper.swift | — |
| 4a | Entitlements are minimal and appropriate | **Info** | RiverDrop.entitlements | — |
| 6b | kinit/klog subprocess is safe | **Info** | SFTPService.swift | 152-176 |

### Priority fixes

1. **Make `HostKeyKeychainHelper.save` throw on failure** and handle the error in `SFTPService.connect`. This eliminates the High-severity silent TOFU regression (5d) and the Medium-severity silent discard (3b) in one change.
2. **Use POSIX `open()` with explicit mode** for askpass scripts and temp key files to eliminate the TOCTOU permission window (2a, 2b).
3. **Add explicit `kSecAttrAccessible`** to all keychain save operations (3a).
4. **Replace `echo` with `printf '%s\n'`** in askpass scripts (1a).
5. **Add startup temp file cleanup** for `riverdrop_*` files (2c).
