# Concurrency Review — RiverDrop

Reviewed files: `SFTPService.swift`, `TransferManager.swift`, `RsyncTransfer.swift`,
`RipgrepSearch.swift`, `RemoteRipgrepSearch.swift`, `StoreManager.swift`, `SSHKeyManager.swift`.

---

## Finding 1 — Main-thread blocking in `SFTPService.runProcess`

**Severity: HIGH**
**Failure mode: UI freeze (hang) during connect**

`SFTPService` is `@MainActor`. Its private helper `runProcess(path:args:)` (line 162)
calls `process.waitUntilExit()` — a synchronous blocking call. Despite being marked
`async`, the function body contains no suspension points (`await`), so the entire
function executes on the main thread. When `kinit -R` or `klog` hang (network timeout,
Kerberos KDC unreachable), the UI freezes for the full duration.

Call chain: `connect()` → `runKinitKlog()` → `runProcess()` × 2.

```
// SFTPService.swift:162-176
private func runProcess(path: String, args: [String]) async -> Bool {
    ...
    try process.run()
    process.waitUntilExit()   // ← blocks main thread
    ...
}
```

**Fix:** Replace the blocking `waitUntilExit` with a continuation-based approach:

```swift
private func runProcess(path: String, args: [String]) async -> Bool {
    guard FileManager.default.isExecutableFile(atPath: path) else { return false }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    return await withCheckedContinuation { continuation in
        process.terminationHandler = { proc in
            continuation.resume(returning: proc.terminationStatus == 0)
        }
        do {
            try process.run()
        } catch {
            continuation.resume(returning: false)
        }
    }
}
```

This suspends the async function at the continuation, freeing the main thread until the
process exits.

---

## Finding 2 — Retain cycle in `SFTPService.reconnectTask`

**Severity: HIGH**
**Failure mode: Memory leak — SFTPService never deallocated**

`startReconnectionTimer()` (line 141) creates a `Task` that implicitly captures `self`
(via the call to `ensureConnected()`). The task is stored in `self.reconnectTask`.
This forms a cycle: `self → reconnectTask → Task closure → self`.

The cycle is only broken when `disconnect()` is called. If the user closes a window
without disconnecting (or if the view is torn down by SwiftUI), the `SFTPService`
instance, its `SFTPSession`, and the NIO `SSHClient` all leak. The reconnection timer
also continues running forever, attempting SSH heartbeats on a dead connection.

```
// SFTPService.swift:141-149
private func startReconnectionTimer() {
    reconnectTask?.cancel()
    reconnectTask = Task {            // ← implicit strong capture of self
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            await ensureConnected()   // ← self.ensureConnected()
        }
    }
}
```

**Fix:** Use `[weak self]` and exit the loop when self is gone:

```swift
private func startReconnectionTimer() {
    reconnectTask?.cancel()
    reconnectTask = Task { [weak self] in
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            guard let self else { return }
            await self.ensureConnected()
        }
    }
}
```

---

## Finding 3 — Sequential pipe reads in `RsyncTransfer.runDryRun` (deadlock risk)

**Severity: MEDIUM**
**Failure mode: Deadlock — rsync hangs, dry-run never completes**

`runDryRun()` (line 348) uses separate pipes for stdout and stderr, then reads them
sequentially:

```
// RsyncTransfer.swift:414-416
let stdoutData = await Task.detached { stdoutHandle.readDataToEndOfFile() }.value
let stderrData = await Task.detached { stderrHandle.readDataToEndOfFile() }.value
await Task.detached { proc.waitUntilExit() }.value
```

`await Task.detached { ... }.value` creates a task and immediately awaits it. The second
task is not created until the first completes. If rsync writes >64 KB to stderr before
it finishes writing to stdout, the stderr pipe buffer fills, rsync blocks trying to
write to stderr, stdout never gets EOF, and the first `readDataToEndOfFile()` never
returns. Classic pipe deadlock.

For a dry run with many permission-denied errors, this is reachable.

**Fix:** Create both tasks before awaiting either:

```swift
let stdoutTask = Task.detached { stdoutHandle.readDataToEndOfFile() }
let stderrTask = Task.detached { stderrHandle.readDataToEndOfFile() }
let stdoutData = await stdoutTask.value
let stderrData = await stderrTask.value
proc.waitUntilExit()
clearProcess()
```

---

## Finding 4 — Unread stderr pipe in `RipgrepSearch`

**Severity: LOW** (theoretical deadlock, very unlikely in practice)
**Failure mode: `rg` hangs if stderr exceeds 64 KB**

`RipgrepSearch.search()` (line 148-150) assigns a `Pipe()` to `standardError` but
never reads from it:

```
// RipgrepSearch.swift:148-150
let pipe = Pipe()
proc.standardOutput = pipe
proc.standardError = Pipe()   // ← created, never drained
```

If `rg` writes more than the OS pipe buffer (64 KB on macOS) to stderr, it will block.
In practice `rg` writes minimal stderr output, making this nearly unreachable, but the
fix is trivial.

**Fix:** Either merge stderr into stdout, or redirect stderr to `/dev/null`:

```swift
proc.standardError = FileHandle.nullDevice
```

Since `rg --json` gives structured output on stdout, stderr is only diagnostics. Safe
to discard.

---

## Finding 5 — Structured Task cancellation not propagated to Process in RsyncTransfer

**Severity: MEDIUM**
**Failure mode: Orphaned rsync process after parent Task cancellation**

`RsyncTransfer.run()` and `runSync()` use `withCheckedThrowingContinuation` to bridge
between the process termination handler and Swift concurrency. However, when Swift's
cooperative cancellation fires (e.g., `Task.cancel()` called on the parent), there is
no `withTaskCancellationHandler` to forward the cancellation to the subprocess.

`TransferManager.cancelTransfer()` calls both `activeRsyncs[id]?.cancel()` (terminates
the process) and `activeTasks[id]?.cancel()` (cancels the Task). This covers the
normal user-cancel path. But if a Task is cancelled by the system (e.g., parent task
teardown), only cooperative cancellation fires — `RsyncTransfer.cancel()` is never
called, and the subprocess runs to completion.

```
// RsyncTransfer.swift:176-212  (same pattern in runSync)
try await withCheckedThrowingContinuation { continuation in
    // No withTaskCancellationHandler — Task.cancel() is silently ignored
    fileHandle.readabilityHandler = { ... }
    proc.terminationHandler = { ... }
}
```

**Fix:** Wrap the continuation in `withTaskCancellationHandler`:

```swift
try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
        fileHandle.readabilityHandler = { ... }
        proc.terminationHandler = { ... }
    }
} onCancel: { [weak self] in
    self?.cancel()
}
```

This ensures the subprocess is terminated if the Task is cancelled from any source.

---

## Finding 6 — `RipgrepSearch.search()` result / completion ordering

**Severity: LOW**
**Failure mode: Brief UI flicker — "0 results" shown before results populate**

In `RipgrepSearch.search()`, the `terminationHandler` and the `Task.detached` reading
stdout both hop to `@MainActor` independently. The termination handler sets
`searchCompleted = true` and `isSearching = false`, while the detached task later sets
`results` and `resultCount`. Their relative ordering on the main run loop is not
guaranteed.

A view observing `searchCompleted` may briefly render a "search complete" state with
empty results before the parsed results arrive in the next main-actor turn.

```
// RipgrepSearch.swift:156-197
proc.terminationHandler = { ... Task { @MainActor in
    self.isSearching = false       // ← may run first
    self.searchCompleted = true
}}

Task.detached { ...
    await MainActor.run {
        self.results = parsed      // ← may run second
        self.resultCount = parsed.count
    }
}
```

**Fix:** Move `searchCompleted = true` into the detached task's final `MainActor.run`
block, after results are set. Or consolidate into a single callback:

```swift
Task.detached { [weak self] in
    let data = fileHandle.readDataToEndOfFile()
    let parsed = parseRipgrepJSON(data)

    await MainActor.run { [weak self] in
        guard let self, self.currentSearchToken == token else { return }
        self.stopSecurityScopedAccess()
        self.results = parsed
        self.resultCount = parsed.count
        self.isSearching = false
        self.searchCompleted = true
        self.process = nil
    }
}
```

Then simplify the termination handler to only handle error-exit status reporting.

---

## Finding 7 — `RemoteRipgrepSearch` cannot cancel server-side command

**Severity: LOW (inherent limitation)**
**Failure mode: Wasted server resources after cancel**

`RemoteRipgrepSearch.cancel()` cancels the Swift Task, but the SSH `executeCommand` has
no way to signal the remote shell. After cancel, the user gets no results (correct), but
the `rg` process on the server runs to completion. For large directory trees this wastes
server CPU and I/O.

There is no clean fix within a single-channel SSH command execution. The standard
approach would be to open a separate SSH channel and send `kill` to the PID, but that
requires capturing the PID from the remote shell. This is an inherent limitation of the
current architecture — documenting it here for awareness.

---

## Finding 8 — `parseDryRunOutput` triple filter

**Severity: LOW**
**Failure mode: Unnecessary allocations, 3× iteration**

`parseDryRunOutput()` (line 575) filters the entries array three times:

```
// RsyncTransfer.swift:575-583
return DryRunResult(
    added: entries.filter { $0.change == .added },
    modified: entries.filter { $0.change == .modified },
    deleted: entries.filter { $0.change == .deleted }
)
```

For large dry-run outputs (thousands of files), this creates three temporary arrays and
iterates 3×.

**Fix:** Single-pass partition:

```swift
func parseDryRunOutput(_ output: String) -> DryRunResult {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
    var added: [DryRunFileEntry] = []
    var modified: [DryRunFileEntry] = []
    var deleted: [DryRunFileEntry] = []

    for line in lines {
        guard let entry = parseDryRunLine(String(line)) else { continue }
        switch entry.change {
        case .added: added.append(entry)
        case .modified: modified.append(entry)
        case .deleted: deleted.append(entry)
        }
    }

    return DryRunResult(added: added, modified: modified, deleted: deleted)
}
```

---

## Finding 9 — `DryRunResult.totalBytes` repeated allocation

**Severity: LOW**
**Failure mode: Temporary array allocation on every access**

```
// RsyncTransfer.swift:570
var totalBytes: Int64 { (added + modified).reduce(0) { $0 + $1.size } }
```

`added + modified` creates a new array on every call. Since `totalBytes` is a computed
property, SwiftUI views may call it multiple times per layout pass.

**Fix:**

```swift
var totalBytes: Int64 {
    added.reduce(into: Int64(0)) { $0 += $1.size }
        + modified.reduce(into: Int64(0)) { $0 += $1.size }
}
```

---

## Things done well

These patterns are correct and worth preserving:

1. **`SFTPSession` as a proper actor.** All mutable SSH/SFTP state is actor-isolated.
   `SFTPService` (@MainActor) delegates all network I/O to `SFTPSession`, keeping
   expensive operations off the main thread. Good separation.

2. **`TOFUHostKeyValidator` with `NIOLock`.** The `@unchecked Sendable` annotation is
   justified — `expectedOpenSSHKey` is immutable and `acceptedKey` is protected by the
   lock. Correct use of `NIOSSHClientServerAuthenticationDelegate` callback threading
   model.

3. **`RsyncTransfer` lock discipline.** All access to `process` and `isCancelled` goes
   through `lock.withLock`. The `storeProcessIfNotCancelled` / `clearProcess` /
   `isTransferCancelled` pattern is clean. `AtomicFlag` correctly prevents double-resume
   of the continuation.

4. **`RsyncTransfer.run()` / `runSync()` merged pipe.** Setting both `standardOutput`
   and `standardError` to the same pipe avoids the classic two-pipe deadlock for the
   live-transfer path. Only the dry-run path has the two-pipe issue (Finding 3).

5. **SFTP upload/download cancellation.** `SFTPSession.uploadFile` and `downloadFile`
   call `try Task.checkCancellation()` in the chunk loop, enabling cooperative
   cancellation during long transfers.

6. **`StoreManager` init with `[weak self]`.** Both Task closures in `init()` capture
   `[weak self]`, preventing a retain cycle with the stored `transactionTask`.
   `deinit` cancels the transaction listener. Correct lifecycle.

7. **`RipgrepSearch` token-based invalidation.** `currentSearchToken` ensures stale
   results from a previous search are discarded when a new search starts or cancel is
   called. All reads/writes happen on `@MainActor`. Clean pattern.

8. **`SSHKeyManager` is a stateless enum.** No concurrency concerns — all methods are
   static, synchronous, and operate on value types or thread-safe APIs (Keychain,
   FileManager).

9. **`TransferManager.cleanupTask` called on all paths.** Every Task code path
   (success, `CancellationError`, other errors) leads to `cleanupTask(id:)`, which
   removes the entry from `activeTasks` and `activeRsyncs`, breaking the temporary
   self-retention cycle.

---

## Summary by priority

| # | Severity | File | Issue |
|---|----------|------|-------|
| 1 | HIGH | SFTPService:162 | `waitUntilExit()` blocks main thread |
| 2 | HIGH | SFTPService:143 | Retain cycle via `reconnectTask` |
| 3 | MEDIUM | RsyncTransfer:414 | Sequential pipe reads → deadlock risk |
| 5 | MEDIUM | RsyncTransfer:176 | No `withTaskCancellationHandler` for subprocess |
| 4 | LOW | RipgrepSearch:150 | Unread stderr pipe (theoretical) |
| 6 | LOW | RipgrepSearch:156 | Result/completion ordering race |
| 7 | LOW | RemoteRipgrepSearch | Server-side cancel impossible (inherent) |
| 8 | LOW | RsyncTransfer:575 | Triple filter in dry-run parsing |
| 9 | LOW | RsyncTransfer:570 | Temporary allocation in `totalBytes` |
