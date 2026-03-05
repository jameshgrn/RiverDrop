import CryptoKit
import Foundation
import SwiftUI

// MARK: - SSH Fingerprint Helper

enum SSHFingerprint {
    /// Parses an OpenSSH public key string ("key-type base64-data [comment]"),
    /// SHA-256 hashes the decoded key data, and returns "SHA256:<base64hash>".
    static func sha256Fingerprint(from openSSHKey: String) -> String? {
        let parts = openSSHKey.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        guard let keyData = Data(base64Encoded: String(parts[1])) else { return nil }

        let hash = SHA256.hash(data: keyData)
        let base64 = Data(hash).base64EncodedString()
        // Strip trailing '=' padding to match OpenSSH output
        let trimmed = base64.replacingOccurrences(of: "=+$", with: "", options: .regularExpression)
        return "SHA256:\(trimmed)"
    }

    /// Extracts the key type from an OpenSSH public key string (e.g. "ssh-ed25519").
    static func keyType(from openSSHKey: String) -> String {
        let parts = openSSHKey.split(separator: " ", maxSplits: 2)
        guard let first = parts.first else { return "unknown" }
        return String(first)
    }

    /// Human-readable key type label.
    static func keyTypeLabel(from openSSHKey: String) -> String {
        switch keyType(from: openSSHKey) {
        case "ssh-ed25519": return "Ed25519"
        case "ssh-rsa": return "RSA"
        case "ecdsa-sha2-nistp256": return "ECDSA P-256"
        case "ecdsa-sha2-nistp384": return "ECDSA P-384"
        case "ecdsa-sha2-nistp521": return "ECDSA P-521"
        case let type: return type
        }
    }
}

// MARK: - Host Key Management View

struct HostKeyManagementView: View {
    @State private var hostKeys: [(host: String, openSSHKey: String)] = []
    @State private var pendingDeleteHost: String?

    var body: some View {
        VStack(spacing: 0) {
            if hostKeys.isEmpty {
                emptyState
            } else {
                keyList
            }
        }
        .onAppear {
            hostKeys = HostKeyKeychainHelper.listAll()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        EmptyStateView(
            "No Stored Host Keys",
            icon: "key.slash",
            subtitle: "Host keys are saved automatically on first connection using trust-on-first-use (TOFU)."
        )
        .frame(maxHeight: .infinity)
    }

    // MARK: - Key List

    private var keyList: some View {
        List {
            ForEach(hostKeys, id: \.host) { entry in
                hostKeyRow(entry)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func hostKeyRow(_ entry: (host: String, openSSHKey: String)) -> some View {
        HStack(spacing: RD.Spacing.md) {
            Image(systemName: "key.fill")
                .font(.title3)
                .foregroundStyle(Color.riverPrimary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: RD.Spacing.xs) {
                Text(entry.host)
                    .font(.body.weight(.medium))

                HStack(spacing: RD.Spacing.sm) {
                    StatusBadge(
                        text: SSHFingerprint.keyTypeLabel(from: entry.openSSHKey),
                        color: .riverAccent
                    )

                    if let fingerprint = SSHFingerprint.sha256Fingerprint(from: entry.openSSHKey) {
                        Text(fingerprint)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer()

            if pendingDeleteHost == entry.host {
                confirmDeleteButtons(for: entry.host)
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        pendingDeleteHost = entry.host
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Delete host key for \(entry.host)")
            }
        }
        .padding(.vertical, RD.Spacing.xs)
    }

    private func confirmDeleteButtons(for host: String) -> some View {
        HStack(spacing: RD.Spacing.sm) {
            Button("Cancel") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    pendingDeleteHost = nil
                }
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            Button("Delete") {
                HostKeyKeychainHelper.delete(for: host)
                withAnimation(.easeInOut(duration: 0.15)) {
                    hostKeys.removeAll { $0.host == host }
                    pendingDeleteHost = nil
                }
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.red)
        }
    }
}
