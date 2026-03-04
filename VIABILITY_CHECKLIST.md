# Viability & Trust Checklist

For a tool that manages remote servers and sensitive data, viability means **predictability** and **security**. Users need confidence the app won't delete their data or leak their credentials.

## 1. Security & Credential Management

- [x] **Keychain Integration:** Credentials stored in macOS Keychain with `com.riverdrop.sftp` service identifier.
- [x] **Host Key Validation (TOFU):** First-use fingerprint stored, verified on subsequent connections.
- [x] **SSH Key Support:** Supports `id_rsa`, `id_ed25519` via `SSHKeyManager` with security-scoped bookmarks for sandboxed access. Passphrase-protected keys handled via `SSH_ASKPASS`.
- [ ] **Host Key Management UI:** "View/Reset Key" interface for stored host fingerprints.
- [ ] **2FA / Keyboard-Interactive Auth:** Duo, Google Authenticator prompts during SSH connection.

## 2. Safety & Data Integrity

- [x] **Conflict Detection (Basic):** Detects if destination file exists; offers Replace/Rename/Cancel.
- [x] **Atomic Transfers:** Rsync `--partial` prevents corrupted files from partial transfers.
- [x] **Rsync Dry-Run Preview:** `DryRunPreviewView` shows diff of files to be added/modified/deleted; user confirms before apply executes.
- [ ] **Advanced Conflict Detection:** Warn when a file has been modified both locally and remotely since last sync.
- [ ] **Destructive Action Confirmation:** Explicit confirmation for `rsync --delete` or remote `rm` operations.

## 3. Robustness & Error Handling

- [x] **Actionable Errors:** All errors include description + "Suggested fix" text.
- [x] **Structured Logging:** OSLog with subsystem/category for transfer telemetry.
- [x] **Cancellation Support:** Both rsync (process kill) and SFTP transfers can be cancelled mid-flight.
- [ ] **Automatic Reconnection:** Pause transfers on Wi-Fi drop, resume when connection restores.
- [ ] **Path Validation:** Sanitize remote paths to prevent command injection.

## 4. Platform Compliance

- [x] **Security-Scoped Bookmarks:** Local file access and SSH keys persisted across launches via app-scoped bookmarks.
- [x] **Network Client Entitlement:** SSH/SFTP outbound connections allowed.
- [x] **App Sandbox:** Enabled (`com.apple.security.app-sandbox = true`) with user-selected read-write and bookmark entitlements.
- [ ] **Hardened Runtime & Notarization:** Required for direct-download distribution. *(in progress)*
- [ ] **Privacy Manifests:** `PrivacyInfo.xcprivacy` not yet added. Required for App Store submission. *(in progress)*

## 5. Performance

- [x] **Background Transfer Queue:** `TransferManager` handles queued transfers without blocking UI.
- [x] **Progress Metrics:** Real-time percentage, transfer rate (MiB/s), duration tracking.
- [x] **Rsync with SFTP Fallback:** Automatic fallback if rsync is unavailable or fails.
- [ ] **Directory Virtualization:** Large directories (10K+ files) need lazy loading to avoid UI freezes.
- [ ] **Transfer Rate Display in UI:** Surface the MiB/s and ETA metrics already computed in the log.

## 6. Monetization

- [x] **StoreKit 2 Integration:** `com.riverdrop.pro` non-consumable ($14.99) via `StoreManager` and `PaywallView`.
- [x] **Feature Gating:** Free tier = SFTP; Pro unlocks rsync, ripgrep, sync previews.
- [x] **Restore Purchases:** Restore flow implemented in `PaywallView`.
