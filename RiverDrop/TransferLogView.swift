import SwiftUI

struct TransferLogView: View {
    @Environment(TransferManager.self) var transferManager

    @AppStorage(DefaultsKey.isTransferLogExpanded) private var isTransferLogExpanded = false

    var navigateRemoteTo: (String) async -> Void
    @Binding var localCurrentDirectory: URL

    private var transferSummary: String {
        let transfers = transferManager.transfers
        guard !transfers.isEmpty else { return "No transfers" }
        let active = transfers.filter { $0.status == .inProgress }.count
        let completed = transfers.filter { $0.status == .completed }.count
        let failed = transfers.filter { $0.status == .failed }.count
        let cancelled = transfers.filter { $0.status == .cancelled }.count
        var parts: [String] = []
        if active > 0 { parts.append("\(active) active") }
        if completed > 0 { parts.append("\(completed) done") }
        if failed > 0 { parts.append("\(failed) failed") }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        return parts.isEmpty ? "No transfers" : parts.joined(separator: ", ")
    }

    private var hasActiveTransfers: Bool {
        transferManager.transfers.contains { $0.status == .inProgress }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: RD.Spacing.sm) {
                Button {
                    withAnimation(.spring(response: 0.16, dampingFraction: 0.85)) {
                        isTransferLogExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isTransferLogExpanded ? 90 : 0))
                        .animation(.spring(response: 0.16, dampingFraction: 0.85), value: isTransferLogExpanded)
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isTransferLogExpanded ? "Collapse transfer log" : "Expand transfer log")

                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.riverPrimary)

                Text("Transfers")
                    .font(.caption.weight(.semibold))

                StatusBadge(text: transferSummary, color: hasActiveTransfers ? .riverAccent : .secondary)

                Spacer()

                if hasActiveTransfers {
                    ProgressView()
                        .controlSize(.mini)
                }

                if !transferManager.transfers.isEmpty {
                    Button {
                        transferManager.transfers.removeAll(where: { $0.status != .inProgress })
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Clear completed transfers")
                    .accessibilityLabel("Clear completed transfers")
                }
            }
            .padding(.horizontal, RD.Spacing.md)
            .padding(.vertical, RD.Spacing.xs + 2)

            if isTransferLogExpanded && !transferManager.transfers.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(spacing: RD.Spacing.xs) {
                        ForEach(transferManager.transfers) { item in
                            transferRow(item)
                        }
                    }
                    .padding(RD.Spacing.sm)
                }
                .frame(minHeight: 60, maxHeight: 150)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: hasActiveTransfers) { _, active in
            if active {
                withAnimation(.easeInOut(duration: 0.12)) {
                    isTransferLogExpanded = true
                }
            }
        }
    }

    // MARK: - Transfer Row

    private func transferRow(_ item: TransferItem) -> some View {
        HStack(spacing: RD.Spacing.sm) {
            Image(systemName: item.isUpload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.callout)
                .foregroundStyle(item.isUpload ? .green : .blue)

            Text(item.filename)
                .lineLimit(1)
                .font(.caption)

            Spacer()

            if item.status == .inProgress {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 80, height: 5)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.riverPrimary, .riverAccent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, 80 * item.progress), height: 5)
                        .shadow(color: .riverAccent.opacity(0.3), radius: 3)
                        .animation(.easeOut(duration: 0.12), value: item.progress)
                }
                .frame(width: 80)

                Text("\(Int(item.progress * 100))%")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)

                Button {
                    transferManager.cancelTransfer(id: item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.7))
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Cancel transfer")
                .accessibilityLabel("Cancel transfer of \(item.filename)")
            } else {
                transferStatusView(item)
            }
        }
        .padding(.horizontal, RD.Spacing.sm)
        .padding(.vertical, RD.Spacing.xs)
        .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: RD.cornerRadiusSmall))
    }

    // MARK: - Transfer Status

    @ViewBuilder
    private func transferStatusView(_ item: TransferItem) -> some View {
        switch item.status {
        case .completed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                StatusBadge(text: "Done", color: .green)
                if !item.destinationDirectory.isEmpty {
                    Button {
                        if item.isUpload {
                            Task { await navigateRemoteTo(item.destinationDirectory) }
                        } else {
                            localCurrentDirectory = URL(fileURLWithPath: item.destinationDirectory)
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.right.circle")
                                .font(.caption2)
                            Text("Show")
                                .font(.caption2)
                        }
                        .foregroundStyle(.blue)
                    }
                    .buttonStyle(.borderless)
                    .help(item.isUpload ? "Navigate to remote directory" : "Navigate to local directory")
                }
            }
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                StatusBadge(text: "Failed", color: .red)
            }
        case .cancelled:
            HStack(spacing: 4) {
                Image(systemName: "pause.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                StatusBadge(text: "Cancelled", color: .orange)
            }
        case .skipped:
            StatusBadge(text: "Skipped", color: .secondary)
        case .inProgress:
            EmptyView()
        }
    }
}
