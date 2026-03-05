import SwiftUI

struct ConnectionFooterView: View {
    @Environment(SFTPService.self) var sftpService

    var body: some View {
        HStack(spacing: RD.Spacing.sm) {
            Image(systemName: sftpService.isConnected ? "lock.shield.fill" : "lock.slash")
                .font(.caption2)
                .foregroundStyle(sftpService.isConnected ? Color.riverPrimary : .secondary)

            Text(sftpService.isConnected ? "\(sftpService.connectedUsername)@\(sftpService.connectedHost)" : "Not connected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            StatusBadge(text: sftpService.connectionMethodLabel, color: .riverPrimary)
            StatusBadge(text: "Auth: \(sftpService.authenticationMethodLabel)", color: .secondary)
        }
        .padding(.horizontal, RD.Spacing.md)
        .padding(.vertical, RD.Spacing.xs + 2)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
}
