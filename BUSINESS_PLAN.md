# RiverDrop: Business Plan

RiverDrop is a premium, native macOS utility designed to bridge the gap between local development environments and remote high-performance computing (HPC) or backend infrastructure. By leveraging the speed of `rsync` and the discovery power of `ripgrep`, RiverDrop provides a "Pro" alternative to generic SFTP clients.

---

### 1. Executive Summary
**Vision:** To be the default file management utility for researchers and developers who move large datasets and manage remote code.
**The Problem:** Traditional SFTP clients (Transmit, Cyberduck) use the SFTP protocol for all transfers, which is notoriously slow over high-latency or high-bandwidth connections. Developers often resort to the command line for `rsync` or `rg`, sacrificing the visual context of a GUI.
**The Solution:** A native SwiftUI application that wraps high-performance CLI tools (`rsync`, `ripgrep`, `ssh`) in a modern, drag-and-drop interface.

### 2. Market Analysis
**Target Audience:**
*   **Academic Researchers/HPC Users:** Users working on clusters (e.g., Big Red, Stampede) who frequently move data between "Home" and "Scratch" (`/not_backed_up`) directories.
*   **Data Scientists:** Professionals syncing large datasets to/from remote GPU instances.
*   **Backend Developers:** Engineers managing VPS instances who need fast, differential syncing of code and logs.

**Competitive Landscape:**
*   **Mass Market (Transmit/ForkLift):** Excellent UI, but focused on broad cloud support (S3, Dropbox). Often lack deep `rsync` integration.
*   **Open Source (Cyberduck/FileZilla):** Functional but lack native macOS "feel" and performance-centric workflows.
*   **CLI Tools:** Maximum speed, zero visual context.

### 3. Unique Value Propositions (UVP)
1.  **Differential Syncing by Default:** Uses `rsync` under the hood to transfer only changed parts of files, making it 5–10x faster than standard SFTP for updates.
2.  **Specialized Workflows:** Built-in "Scratch" and "Home" toggles specifically for cluster-based research environments.
3.  **Integrated Discovery:** Built-in `ripgrep` support for local file content searching, with a roadmap for remote execution.
4.  **Native Performance:** 100% SwiftUI and Swift, ensuring low memory footprint and alignment with macOS security (Sandboxing, Security-Scoped Bookmarks).

### 4. Revenue Model
**Pricing Strategy: "Prosumer Indie Utility"**
*   **Tier 1: Free (Standard SFTP):** Basic file browsing, standard SFTP uploads/downloads.
*   **Tier 2: Pro License ($14.99 one-time):** Unlocks `rsync` transfer engine, `ripgrep` content search, and unlimited bookmarks.
*   **Tier 3: Lab/Team License ($49.99/yr):** Priority support and site-wide deployment for research labs.

### 5. Roadmap
*   **Phase 1 (Current):** Stable SFTP browsing, basic `rsync` transfers, local `ripgrep`.
*   **Phase 2 (The "Killer Feature"):** **Remote Ripgrep.** Execute `rg` via SSH on the server and stream results back to the GUI. This allows searching terabytes of remote data in seconds.
*   **Phase 3:** Custom `rsync` flag profiles (e.g., "Archive Mode," "Delete Extra Files").
*   **Phase 4:** Terminal integration—right-click "Open Terminal Here" to launch iTerm2/Terminal.app at the remote path.

### 6. Marketing & Distribution
*   **Distribution:** Mac App Store (for visibility/trust) and Direct Download (via `uv` or Homebrew for the developer crowd).
*   **Channels:**
    *   **Academic Forums:** Outreach to university IT departments and research computing groups.
    *   **Developer Communities:** Product Hunt, Hacker News, and r/macapps.
    *   **GitHub:** Keep the core engine or a "Lite" version open-source to build trust within the dev community.

### 7. Technical Operations
*   **Stack:** Swift 5.10+, SwiftUI, Citadel (SSH/SFTP library).
*   **Dependencies:** Minimal. Relies on system-installed `rsync` and `rg` (with guidance to install via Homebrew), reducing app bundle size and maintenance overhead.
*   **Security:** Keychain integration for credentials, TOFU (Trust On First Use) for host keys.
