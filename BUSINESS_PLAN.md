# RiverDrop: Business Plan

RiverDrop is a native macOS file transfer utility built for researchers and developers who work with remote HPC clusters and backend servers. It wraps `rsync` and `ripgrep` in a drag-and-drop SwiftUI interface — **the speed of CLI tools with the context of a GUI.**

---

### 1. Executive Summary

**Vision:** The default file management tool for anyone who moves large datasets between local machines and remote servers.

**The Problem:** SFTP clients (Transmit, Cyberduck) transfer entire files on every sync. Over high-latency or high-bandwidth links, this is painfully slow. Researchers and devs fall back to terminal `rsync`, losing visual context. Nobody has combined rsync's differential transfer engine with a native macOS GUI.

**The Solution:** A SwiftUI app that uses `rsync` for transfers and `ripgrep` for search — both local and remote. Drag-and-drop interface with first-class support for HPC directory conventions (Home/Scratch).

### 2. Market Analysis

**Target Audience:**

| Segment | Pain Point | What They Use Now |
|---------|-----------|-------------------|
| HPC/Academic Researchers | Moving GBs between Home and Scratch dirs on clusters | Terminal rsync, Cyberduck |
| Data Scientists | Syncing datasets to/from remote GPU instances | scp, Transmit, VS Code Remote |
| Backend Developers | Fast differential sync of code and logs to VPS | rsync scripts, ForkLift |

### 3. Unique Value Propositions

1. **Rsync-First Transfers:** Differential syncing by default — only changed bytes move over the wire. Dramatically faster than SFTP for iterative workflows.
2. **HPC-Native Workflows:** Home/Scratch directory toggles, cluster-aware path conventions, SSH key and 2FA support for institutional login.
3. **Remote Ripgrep:** Execute `rg` on the server via SSH and stream results back. Search terabytes of remote data without downloading anything.
4. **Native macOS:** SwiftUI, Keychain credential storage, security-scoped bookmarks, low memory footprint.

### 4. Revenue Model: "Free + Pro One-Time"

RiverDrop follows an "Indie Pro" model: a high-quality free core with a one-time purchase to unlock professional performance features.

| Tier | Price | Value Proposition (The "Hook") |
|------|-------|-------------------------------|
| **Free** | $0 | **SFTP Core:** Connect, browse, upload/download, drag/drop, SSH Key support, and Keychain integration. |
| **Pro** | **$14.99** (One-Time) | **Performance & Safety:** Rsync differential engine, Remote Ripgrep search, and Sync Dry-Run previews. |

**Rationale:** 
- **The "Hook" (Free):** Competes with Cyberduck and VS Code by offering a superior, native browsing experience. Build trust with free SSH key support and security.
- **The "Power" (Pro):** Users pay for time saved (rsync) and advanced remote capabilities (ripgrep). A one-time purchase avoids "subscription fatigue" common in the developer/researcher community.

### 5. Roadmap

**Phase 1 — Core (Done):**
- SFTP browsing and file transfers
- Rsync transfers (Password-only)
- Local ripgrep content search
- Keychain credential storage, TOFU host key validation

**Phase 2 — Viability & Pro (Next):**
- **SSH Key support for Rsync:** Enable rsync engine for key-only HPC environments.
- **Remote Ripgrep:** SSH-backed remote search implementation.
- **StoreKit 2 Integration:** $14.99 Paywall and feature gating.
- **Rsync Dry-Run Preview:** Visual diff before execution.

**Phase 3 — Polish:**
- 2FA / keyboard-interactive authentication.
- Custom rsync flag profiles (Archive, Mirror, etc.).
- Directory virtualization for 10K+ file listings.

### 6. Marketing: "GUI Polish, CLI Speed"

**Tagline:** *"The speed of `rsync` with the context of a Mac app."*

**Distribution:**
- **Mac App Store:** Visibility and trust.
- **Homebrew Cask:** Direct reach to the power-user audience: `brew install --cask riverdrop`.

**Channels:**
- **Academic:** University IT departments, research computing Slack/Discord (e.g., Pangeo).
- **Developer:** Show HN (Hacker News), Product Hunt, r/macapps.
