# Feature Tiers for RiverDrop

## 1. Executive Summary
RiverDrop should keep the full SFTP workflow free and monetize the performance/safety multiplier layer. Right now, only local content search is gated, which is not the strongest pay trigger; the strongest paid value in the current codebase is rsync acceleration, and the strongest near-term paid value is remote ripgrep at scale. At $14.99 one-time, Pro is viable if Pro clearly means faster sync + safer large sync decisions, not basic file browsing friction.

## 2. FREE Tier Features (with rationale)
- SFTP core workflow: connect, browse, upload, download, drag/drop, and transfer progress (`ConnectionView.swift`, `SFTPService.swift`, `MainView.swift`, `LocalBrowserView.swift`, `TransferManager.swift`).
Rationale: This is the product hook and baseline expectation versus Cyberduck/FileZilla/VS Code.

- Authentication and trust primitives: password auth, SSH key auth, host key TOFU validation, and Keychain credential storage (`ConnectionView.swift`, `SSHKeyManager.swift`, `SFTPService.swift`, `KeychainHelper.swift`).
Rationale: Gating security basics is an anti-pattern and blocks trust.

- Local and remote filename filtering/navigation UX: fuzzy filter, path breadcrumbs, Home/Scratch switcher, copy-path actions (`MainView.swift`, `LocalBrowserView.swift`).
Rationale: These are table-stakes usability, not premium differentiation.

- Conflict prompts and cancel controls for transfers (`TransferManager.swift`, `MainView.swift`).
Rationale: Data safety and reversibility should remain available to all users.

- Local content search as a limited free teaser (`LocalBrowserView.swift`, `RipgrepSearch.swift`).
Rationale: Keep discovery in free so users experience value early; reserve heavy/remote search power for Pro.

## 3. PRO Tier Features (with rationale)
- Rsync transfer engine with automatic SFTP fallback (`TransferManager.swift`, `RsyncTransfer.swift`).
Rationale: This is the clearest monetizable value: faster differential sync and better throughput on large datasets. Rsync now supports both password and SSH key authentication (`RsyncAuth` enum with `.password` and `.sshKey` cases).

- Remote content search over SSH (`MainView.swift`, `RemoteRipgrepSearch.swift`).
Rationale: This is the roadmap "killer feature" and maps directly to HPC/dev pain (searching large remote trees quickly).

- Sync preview/dry-run workflows with one-click apply (`TransferManager.swift`, `RsyncTransfer.swift`, `DryRunPreviewView.swift`, `MainView.swift`).
Rationale: Safety plus scale is premium value. Both dry-run preview and apply-sync are fully wired — user sees the diff, confirms, and `applySyncUpload`/`applySyncDownload` executes the real sync. Works with both password and SSH key auth.

- Advanced transfer controls once shipped: rsync profiles, delete-mode safeguards, and resumable/reconnect behavior (aligned with `VIABILITY_CHECKLIST.md`).
Rationale: Power users pay for predictable high-volume operations, not just UI polish.

- Remove "Unlimited Bookmarks" from paid positioning unless an actual limit exists (`PaywallView.swift`, `RiverDrop.storekit`, `LocalBrowserView.swift`).
Rationale: Current code does not enforce a meaningful free bookmark cap, so this is weak/possibly misleading as a paid differentiator.

## 4. Features That Should NOT Be Gated (anti-patterns)
- Basic upload/download/browse/connect.
- SSH key support and host key verification.
- Error visibility, cancellation, and conflict prompts.
- Core local folder access/bookmark persistence needed for sandboxed macOS operation.

These are trust and baseline competence layers; gating them increases churn and support burden.

## 5. Pricing Analysis: Is $14.99 right?
- Relative positioning (as of March 2026 assumptions): Cyberduck is free/donation-supported, FileZilla client is free, VS Code Remote SSH is free, and Transmit is around $45 one-time.
- Conclusion: $14.99 is reasonable as an entry Pro price, but only if paid value is obvious within minutes.
- Current risk: with local ripgrep as the primary gate, value can feel thin; many users will perceive "free alternatives + command line" as good enough.
- Recommendation: keep $14.99 while strengthening Pro around rsync + remote ripgrep + safe sync preview/apply. Re-test at $19.99 after those are complete and stable.

## 6. Recommendations for Future Pro Features
- Gate remote ripgrep as a flagship Pro feature, with a small free trial quota per session/day.
- Add rsync profile presets (archive, delete-extra, excludes) with clear destructive-action warnings.
- Add resumable/background transfer queue behavior for unstable Wi-Fi/long jobs.
- Add sync conflict intelligence (changed both sides) before apply.
- Add team/lab features only after single-user Pro conversion is strong: exportable connection profiles, managed host key trust, and shared preset bundles.

