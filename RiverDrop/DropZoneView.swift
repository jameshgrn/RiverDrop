import SwiftUI

struct StagedItem: Identifiable {
    let id = UUID()
    let filename: String
    let size: UInt64
    let source: StagedSource

    enum StagedSource {
        case local(URL)
        case remote(String)
    }
}

struct DropZoneView: View {
    let direction: TransferDirection
    @Binding var stagedItems: [StagedItem]
    let onTransferAll: () -> Void

    @State private var isTargeted = false
    @State private var pulseAnimation = false

    enum TransferDirection {
        case upload
        case download

        var label: String {
            switch self {
            case .upload: return "Upload"
            case .download: return "Download"
            }
        }

        var icon: String {
            switch self {
            case .upload: return "arrow.up.circle.fill"
            case .download: return "arrow.down.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .upload: return .green
            case .download: return .blue
            }
        }

        var emptyIcon: String {
            switch self {
            case .upload: return "tray.and.arrow.up"
            case .download: return "tray.and.arrow.down"
            }
        }
    }

    var body: some View {
        if stagedItems.isEmpty {
            emptyDropZone
        } else {
            stagedFilesList
        }
    }

    // MARK: - Empty State

    private var emptyDropZone: some View {
        HStack(spacing: RD.Spacing.sm) {
            Image(systemName: direction.emptyIcon)
                .font(.callout)
                .foregroundStyle(isTargeted ? direction.color : .secondary.opacity(0.5))

            Text("Drop files to stage for \(direction.label.lowercased())")
                .font(.caption2)
                .foregroundStyle(isTargeted ? direction.color : .secondary.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: RD.cornerRadiusSmall)
                .strokeBorder(
                    isTargeted ? direction.color.opacity(0.6) : Color.primary.opacity(0.1),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .background(
                    isTargeted
                        ? direction.color.opacity(0.04)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: RD.cornerRadiusSmall)
                )
        )
        .padding(.horizontal, RD.Spacing.sm)
        .padding(.vertical, RD.Spacing.sm)
        .animation(.easeInOut(duration: 0.1), value: isTargeted)
    }

    // MARK: - Staged Files

    private var stagedFilesList: some View {
        VStack(spacing: 0) {
            HStack(spacing: RD.Spacing.sm) {
                Image(systemName: direction.icon)
                    .foregroundStyle(direction.color)
                    .font(.caption)

                Text("\(stagedItems.count) file\(stagedItems.count == 1 ? "" : "s") staged")
                    .font(.caption2.weight(.medium))

                Text(totalSizeText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    withAnimation(.easeOut(duration: 0.1)) {
                        stagedItems.removeAll()
                    }
                } label: {
                    Text("Clear")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)

                Button(action: onTransferAll) {
                    HStack(spacing: 4) {
                        Image(systemName: direction.icon)
                            .font(.caption2)
                        Text("\(direction.label) All")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(direction.color.gradient, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, RD.Spacing.md)
            .padding(.top, RD.Spacing.sm)
            .padding(.bottom, RD.Spacing.xs)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RD.Spacing.xs) {
                    ForEach(stagedItems) { item in
                        stagedItemChip(item)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.8).combined(with: .opacity),
                                removal: .scale(scale: 0.6).combined(with: .opacity)
                            ))
                    }
                }
                .padding(.horizontal, RD.Spacing.md)
                .padding(.bottom, RD.Spacing.sm)
                .animation(.spring(response: 0.16, dampingFraction: 0.82), value: stagedItems.count)
            }
        }
        .background(direction.color.opacity(0.03))
    }

    private func stagedItemChip(_ item: StagedItem) -> some View {
        HStack(spacing: 4) {
            FileIconView(filename: item.filename, isDirectory: false, size: 10)

            Text(item.filename)
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: 100)

            Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button {
                withAnimation(.spring(response: 0.14, dampingFraction: 0.82)) {
                    stagedItems.removeAll { $0.id == item.id }
                }
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .fontWeight(.bold)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(item.filename)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(direction.color.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(direction.color.opacity(0.12), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Staged: \(item.filename)")
    }

    private var totalSizeText: String {
        let total = stagedItems.reduce(UInt64(0)) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }
}
