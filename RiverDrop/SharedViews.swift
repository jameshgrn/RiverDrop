import SwiftUI

// MARK: - Staged Chip

struct StagedChipView: View {
    let item: StagedItem
    let chipColor: Color
    let isUpload: Bool
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isUpload ? "arrow.up" : "arrow.down")
                .imageScale(.small)
                .fontWeight(.bold)
                .foregroundStyle(chipColor)

            FileIconView(filename: item.filename, isDirectory: false, size: 10)

            Text(item.filename)
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: 100)

            Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .fontWeight(.bold)
                    .foregroundStyle(isHovered ? .secondary : .tertiary)
                    .frame(width: 14, height: 14)
                    .background(Color.primary.opacity(isHovered ? 0.1 : 0.06), in: Circle())
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(item.filename)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(chipColor.opacity(isHovered ? 0.1 : 0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(chipColor.opacity(isHovered ? 0.2 : 0.12), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isUpload ? "Upload" : "Download") staged: \(item.filename)")
        .onHover { isHovered = $0 }
    }
}
