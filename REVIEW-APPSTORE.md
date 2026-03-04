# App Store Review Audit — RiverDrop

macOS 14+ SFTP/rsync file-transfer app targeting researchers & HPC users.
$14.99 one-time Pro upgrade via StoreKit 2.

---

## Severity Legend

| Label | Meaning |
|---|---|
| **BLOCKER** | Will be rejected. Must fix before submission. |
| **HIGH** | Very likely rejection or upload-time failure. |
| **MEDIUM** | May trigger reviewer questions; fix proactively. |
| **LOW** | Unlikely rejection but worth addressing. |

---

## 1. BLOCKER — Subprocess Spawning Violates Sandbox

**Files:**
- `RiverDrop/RsyncTransfer.swift` — spawns `/usr/bin/rsync` (or Homebrew variants) via `Process()`
- `RiverDrop/RipgrepSearch.swift` — spawns `/usr/bin/rg` (or Homebrew variants) via `Process()`
- `RiverDrop/SFTPService.swift:152-176` — spawns `/usr/bin/kinit` and `/usr/bin/klog` via `Process()`

**Why it's rejected:**
Mac App Store sandbox prohibits `Process()` / `NSTask`. Sandboxed apps cannot launch external binaries. There is no entitlement to allow this. Apple's sandbox profile blocks `posix_spawn` for arbitrary executables. This is the single most common macOS App Store rejection reason.

**Additionally:** `RsyncTransfer.swift:452-463` writes a shell script to `temporaryDirectory` with `0o700` permissions and passes it as `SSH_ASKPASS` to the rsync subprocess. App Review flags writing executable scripts as a sandbox circumvention technique even if the subprocess issue were somehow resolved.

**Mitigation options (pick one):**

| Option | Effort | Tradeoff |
|---|---|---|
| A. Remove rsync/rg/kinit features entirely from MAS build | Low | Pro features gutted; keep SFTP-only in MAS, offer direct download for Pro |
| B. Reimplement rsync delta-sync in-process (e.g., librsync via C interop) | Very high | Maintains feature parity but massive engineering lift |
| C. XPC Service helper tool with its own sandbox profile | High | Apple allows XPC helpers but they must also be sandboxed; rsync still can't run inside a sandbox |
| D. Distribute outside MAS only (notarized direct download) | Low | Loses MAS discoverability; hardened runtime + notarization sufficient |

**Recommendation:** Option A (dual distribution) or Option D. Ship a free SFTP-only version on MAS for discoverability, sell Pro via direct download with notarization. Or skip MAS entirely.

---

## 2. BLOCKER — Missing Export Compliance Declaration

**Problem:**
The app uses SSH encryption via NIOSSH/Citadel (`SFTPService.swift`, `SSHKeyManager.swift`). The generated Info.plist has no `ITSAppUsesNonExemptEncryption` key. App Store Connect will block the binary at upload time and force you to answer export compliance questions interactively.

**Fix:**
Add to `project.yml` under `settings.base`:

```yaml
INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
```

SSH/TLS for authentication and data transfer qualifies for the EAR License Exception TSU (encryption used solely for authentication/data integrity, standard protocols, no custom crypto). Setting this to `NO` means "the app uses only exempt encryption" which is correct for SSH client usage.

If you're unsure, consult Apple's [export compliance documentation](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations). You may also need to file a SNAP-R self-classification with BIS (one-time, ~30 minutes).

**Severity if unfixed:** Upload to App Store Connect will stall until answered manually every single time.

---

## 3. HIGH — Privacy Manifest Missing File Timestamp Declaration

**Files using `contentModificationDateKey`:**
- `RiverDrop/LocalBrowserView.swift:921,938,949` — `URLResourceValues` with `.contentModificationDateKey`

**Files using `attributesOfItem(atPath:)`:**
- `RiverDrop/TransferManager.swift:1119`
- `RiverDrop/MainView.swift:1196`
- `RiverDrop/LocalBrowserView.swift:1043`
- `RiverDrop/SFTPService.swift:405`

**Problem:**
Apple's required-reason API list (WWDC23, enforced since Spring 2024) requires `NSPrivacyAccessedAPICategoryFileTimestamp` in the privacy manifest when accessing file modification dates. The current `PrivacyInfo.xcprivacy` only declares `NSPrivacyAccessedAPICategoryUserDefaults`.

**Fix:**
Add to `PrivacyInfo.xcprivacy` under `NSPrivacyAccessedAPITypes`:

```xml
<dict>
    <key>NSPrivacyAccessedAPIType</key>
    <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
    <key>NSPrivacyAccessedAPITypeReasons</key>
    <array>
        <string>C617.1</string>
    </array>
</dict>
```

Reason code `C617.1`: "Declare this reason to access the timestamps, size, or other metadata of files inside the app container, app group containers, or the app's CloudKit container." If accessing user-selected files outside the container, use `DDA9.1` instead (or both).

**Note:** `attributesOfItem(atPath:)` reading `.size` does not currently require a privacy manifest entry (only timestamp access is listed), but Apple may expand the list. The modification date access definitively requires it.

---

## 4. HIGH — Keychain Access Without Entitlement

**Files:**
- `RiverDrop/KeychainHelper.swift` — `SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete` with `kSecClassGenericPassword`
- Used for: SSH passwords (`com.riverdrop.sftp` service), host key fingerprints (`com.riverdrop.hostkeys` service)

**Problem:**
The entitlements file does not include `com.apple.security.keychain-access-groups`. Under sandbox, Keychain access is limited to the app's own Keychain access group (derived from the team ID + bundle ID). This *may* work without an explicit entitlement because sandboxed apps get implicit access to their own group — but behavior is inconsistent across macOS versions.

**Risk:** If Keychain calls fail silently, credentials won't persist. Worse, if they throw, the error messages surface to the user. App Review may not catch this, but users will.

**Mitigation:**
Test Keychain operations thoroughly in a sandboxed release build (not just debug). If any `SecItem*` calls return `errSecMissingEntitlement` (-34018), add:

```xml
<key>com.apple.security.keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)com.riverdrop.app</string>
</array>
```

**Severity:** HIGH because credential storage is core UX. Won't cause *rejection* but will cause broken functionality post-approval.

---

## 5. MEDIUM — Hardcoded User-Specific Paths in Go Menu

**File:** `RiverDrop/RiverDropApp.swift:79-98`

```swift
if FileManager.default.fileExists(atPath: "/Users/\(NSUserName())/projects") { ... }
if FileManager.default.fileExists(atPath: "/not_backed_up/\(NSUserName())") { ... }
```

**Problem:**
- The "Cluster Scratch" menu item references `/not_backed_up/\(NSUserName())` — a path specific to IU's HPC clusters. App Review runs on Apple's test machines where this path won't exist, so the menu item won't appear. Not a rejection risk, but if it *did* appear, the reviewer would question why the app accesses a root-level directory outside the user's home.
- Under sandbox, `FileManager.default.fileExists(atPath:)` for paths outside the container/home may return `false` regardless of actual existence (sandbox denies the stat call). This means these menu items may never appear in the MAS build.
- More importantly, even if the menu item appears, navigating to `/not_backed_up/` without a security-scoped bookmark would fail under sandbox.

**Mitigation:** Remove hardcoded paths; let users configure quick-access directories in Settings (using NSOpenPanel + bookmarks, which you already have).

---

## 6. MEDIUM — Free Tier Functionality Assessment

**Gated behind Pro:**
- Rsync transfers (delta sync, progress) — `TransferManager.swift:84,122,270,500`
- Dry-run previews — `TransferManager.swift:650,690,732,817,924,1015`
- Remote ripgrep search — `MainView.swift:309,405,440` / `LocalBrowserView.swift:234,269`
- Bookmarks beyond `freeBookmarkLimit` — `LocalBrowserView.swift:720`

**Free tier provides:**
- SFTP connection, browsing, upload, download (the core functionality)
- Basic local file browsing
- Limited bookmarks

**Assessment:** The free tier is *functional enough* to avoid Guideline 3.1.1 rejection ("apps that unlock features with IAP must offer a meaningful free experience"). SFTP browsing + transfer is a complete workflow. App Review should accept this split.

**One concern:** The "Rsync Acceleration" Pro feature requires rsync to be installed on the user's machine (`/usr/bin/rsync` or Homebrew). If the user pays $14.99 and rsync isn't available, they get an error. The PaywallView doesn't mention this dependency. Consider adding a footnote: "Requires rsync installed on your Mac."

---

## 7. MEDIUM — `kinit`/`klog` Spawning on Every Connection

**File:** `RiverDrop/SFTPService.swift:152-176`

**Problem beyond sandbox (covered in #1):** Even outside MAS, calling `kinit -R` and `klog` unconditionally on every `connect()` and reconnect is problematic:
- `kinit` is a Kerberos utility that may not exist on consumer Macs
- `klog` is an AFS utility specific to institutional HPC environments
- Running these unconditionally adds latency and generates confusing errors for non-HPC users

**Mitigation:** Gate Kerberos/AFS renewal behind a user preference or detect the HPC environment. For MAS build, remove entirely (subprocess spawning is blocked regardless).

---

## 8. LOW — In-App Purchase Implementation Review

**File:** `RiverDrop/StoreManager.swift`, `RiverDrop/PaywallView.swift`

| Requirement | Status |
|---|---|
| Restore Purchases button | Present (`PaywallView.swift:166`) |
| Price from StoreKit (not hardcoded) | Yes — `product.displayPrice` (`PaywallView.swift:137`) |
| Pro features described | Yes — three feature cards in PaywallView |
| Transaction verification | Yes — `checkVerified()` validates JWS |
| Transaction listener | Yes — `listenForTransactions()` for background updates |
| Revocation handling | Yes — checks `transaction.revocationDate` |
| Pending transactions | Handled (no-op, which is correct) |
| Error messages | Clear and actionable |

**No issues found.** The StoreKit 2 implementation is clean and follows Apple's recommended patterns.

---

## 9. LOW — Entitlements Review

| Entitlement | Justified? | Notes |
|---|---|---|
| `com.apple.security.app-sandbox` | Yes | Required for MAS |
| `com.apple.security.network.client` | Yes | SSH/SFTP requires outbound network |
| `com.apple.security.files.user-selected.read-write` | Yes | File transfer app needs local file access via panels |
| `com.apple.security.files.bookmarks.app-scope` | Yes | Persisting directory access across launches |

**Missing but may be needed:**
- `com.apple.security.keychain-access-groups` — see finding #4
- `com.apple.security.temporary-exception.*` — none present, which is good (Apple scrutinizes these)

**No unnecessary entitlements.** This is a clean, minimal set. Apple won't question any of these.

---

## 10. LOW — Hardened Runtime

**Status:** Enabled for both Debug and Release in `project.pbxproj` (lines 265, 301, 350, 380).

**No runtime exceptions requested** (no `com.apple.security.cs.*` entitlements). This means:
- No `cs.allow-unsigned-executable-memory`
- No `cs.disable-library-validation`
- No `cs.allow-jit`

This is correct for a pure Swift app. Citadel/NIOSSH are pure Swift and don't need JIT or unsigned memory.

**However:** If the subprocess spawning issue (#1) were "solved" by embedding rsync/rg as helper tools, you'd need `cs.disable-library-validation` to load unsigned helpers, which Apple rejects for MAS apps. This reinforces that the subprocess approach is fundamentally incompatible with MAS.

---

## 11. LOW — UserDefaults Reason Code

**Current declaration:** `CA92.1` — "Access info from same app, app clips, or app extensions."

**Assessment:** Correct. All `@AppStorage` and `UserDefaults.standard` usage is within the same app (no app groups, extensions, or clips). The reason code is appropriate.

---

## Summary — Action Items by Priority

| # | Severity | Issue | Fix |
|---|---|---|---|
| 1 | **BLOCKER** | `Process()` subprocess spawning | Remove rsync/rg/kinit from MAS build or distribute outside MAS |
| 2 | **BLOCKER** | Missing `ITSAppUsesNonExemptEncryption` | Add `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO` to project.yml |
| 3 | **HIGH** | Privacy manifest missing file timestamp API | Add `NSPrivacyAccessedAPICategoryFileTimestamp` with reason `DDA9.1` |
| 4 | **HIGH** | Keychain access may fail under sandbox | Test in sandboxed release build; add keychain-access-groups entitlement if needed |
| 5 | **MEDIUM** | Hardcoded HPC paths in Go menu | Replace with user-configurable bookmarks |
| 6 | **MEDIUM** | PaywallView doesn't disclose rsync dependency | Add footnote about rsync requirement |
| 7 | **MEDIUM** | kinit/klog runs unconditionally | Gate behind preference or remove for MAS |
| 8 | **LOW** | IAP implementation | No issues |
| 9 | **LOW** | Entitlements | Clean and minimal |
| 10 | **LOW** | Hardened runtime | Correctly configured |
| 11 | **LOW** | UserDefaults privacy reason | Correct code |

---

## Strategic Recommendation

The subprocess spawning (#1) is architectural — it's not a "fix one line" problem. The Pro features (rsync acceleration, ripgrep search, dry-run previews) all depend on shelling out to external binaries, which is fundamentally incompatible with the Mac App Store sandbox.

**Recommended distribution strategy:**

1. **Mac App Store build:** SFTP-only (free). Remove all `Process()` code paths. This gives you MAS discoverability and handles the free tier naturally.
2. **Direct download build:** Full-featured with Pro IAP (or license key). Notarize with hardened runtime. Distribute via your website. This is where the $14.99 value lives.

This dual-distribution model is common among macOS developer tools (e.g., BBEdit, Transmit, Tower) and avoids fighting the sandbox.
