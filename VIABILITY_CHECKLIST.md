# Viability & Trust Checklist

For a tool that manages remote servers and sensitive data, "viability" isn't just about features; it's about **predictability** and **security**. Users need to know the app won't delete their data or leak their credentials.

## 1. Security & Credential Management
*   **[ ] SSH Key Support:** Most pro users (HPC/Backend) disable password login entirely. The app *must* support `id_rsa`, `id_ed25519`, and `ssh-agent` integration.
*   **[ ] Proper Keychain Integration:** Credentials must be stored in the macOS Keychain with appropriate access controls (currently partially implemented).
*   **[ ] Host Key Validation:** Prevent Man-in-the-Middle (MITM) attacks by rigorously verifying host fingerprints (implemented via TOFU, but needs a "View/Reset Key" UI).
*   **[ ] Two-Factor Authentication (2FA):** Support for Duo/Google Authenticator prompts during SSH connection (keyboard-interactive authentication).

## 2. Safety & Data Integrity (The "Don't Break It" Layer)
*   **[ ] Rsync Dry-Run Preview:** Before a massive sync, show a "diff" or a list of files that will be added/deleted.
*   **[ ] Conflict Detection:** Warning if a file has been modified on the server *and* locally since the last sync.
*   **[ ] Destructive Action Confirmation:** Explicit "Are you sure?" prompts for `rm` operations or `rsync --delete`.
*   **[ ] Atomic Transfers:** Ensure partial transfers don't leave corrupted files (rsync handles this well, but the UI must report it).

## 3. Robustness & Error Handling
*   **[ ] Automatic Reconnection:** If the Wi-Fi drops, the app should pause transfers and resume once the connection is back.
*   **[ ] Path Validation:** Sanitize remote paths to prevent accidental command injection or "Directory Traversal" attacks.
*   **[ ] Permission Checks:** Clearly explain *why* an upload failed (e.g., "Permission Denied on /root" vs. "Disk Full").

## 4. Platform Compliance
*   **[ ] App Sandbox Compliance:** If targeted for the App Store, all file access must be via Powerbox (NSOpenPanel) and Security-Scoped Bookmarks (implemented).
*   **[ ] Hardened Runtime & Notarization:** Required for any app distributed outside the App Store to pass macOS Gatekeeper.
*   **[ ] Privacy Manifests:** Declare usage of any sensitive APIs to comply with modern Apple privacy standards.

## 5. Performance for "Big Data"
*   **[ ] Directory Pagination/Virtualization:** Large directories (10,000+ files) should not freeze the UI.
*   **[ ] Background Transfer Queue:** Ability to queue up 1,000+ files without blocking the main browser view (implemented via `TransferManager`).
*   **[ ] Progress Metrics:** Real-time throughput (MB/s) and Estimated Time of Arrival (ETA).
