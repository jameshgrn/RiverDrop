import SwiftUI

// MARK: - Brand Colors

extension Color {
    static let riverPrimary = Color(red: 0.15, green: 0.45, blue: 0.85)
    static let riverAccent = Color(red: 0.02, green: 0.71, blue: 0.83)
    static let riverGlow = Color(red: 0.30, green: 0.58, blue: 0.98)
}

// MARK: - Namespace

enum RD {
    static let cornerRadius: CGFloat = 10
    static let cornerRadiusSmall: CGFloat = 6
    static let cornerRadiusLarge: CGFloat = 16

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }
}

// MARK: - File Type Icons

struct FileIconView: View {
    let filename: String
    let isDirectory: Bool
    var size: CGFloat = 16

    private var ext: String {
        (filename as NSString).pathExtension.lowercased()
    }

    private var config: (name: String, color: Color) {
        if isDirectory { return ("folder.fill", .blue) }
        switch ext {
        case "py": return ("doc.fill", Color(red: 0.2, green: 0.6, blue: 0.2))
        case "swift": return ("doc.fill", .orange)
        case "js", "ts", "jsx", "tsx": return ("doc.fill", .yellow)
        case "json", "yml", "yaml", "toml": return ("gearshape.fill", .purple)
        case "md", "txt", "rst": return ("doc.text.fill", .gray)
        case "csv", "tsv", "parquet": return ("tablecells.fill", .teal)
        case "tif", "tiff", "nc", "hdf", "h5", "geojson", "shp", "gpkg":
            return ("globe.americas.fill", .green)
        case "png", "jpg", "jpeg", "gif", "svg", "webp":
            return ("photo.fill", .pink)
        case "pdf": return ("doc.richtext.fill", .red)
        case "zip", "tar", "gz", "bz2", "xz", "7z":
            return ("doc.zipper", .brown)
        case "sh", "bash", "zsh": return ("terminal.fill", .mint)
        case "r", "rmd": return ("doc.fill", .blue)
        case "ipynb": return ("doc.fill", Color(red: 0.9, green: 0.5, blue: 0.1))
        default: return ("doc.fill", .secondary)
        }
    }

    var body: some View {
        Image(systemName: config.name)
            .font(.system(size: size))
            .foregroundStyle(config.color)
            .frame(width: size + 4, height: size + 4)
    }
}

// MARK: - Card Modifier

struct CardModifier: ViewModifier {
    var padding: CGFloat = RD.Spacing.lg

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: RD.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: RD.cornerRadius)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}

extension View {
    func cardStyle(padding: CGFloat = RD.Spacing.lg) -> some View {
        modifier(CardModifier(padding: padding))
    }
}

// MARK: - Gradient Button Style

struct RDButtonStyle: ButtonStyle {
    var isProminent: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(isProminent ? .white : .primary)
            .padding(.horizontal, RD.Spacing.xl)
            .padding(.vertical, RD.Spacing.md)
            .background {
                if isProminent {
                    LinearGradient(
                        colors: [.riverPrimary, .riverGlow],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: RD.cornerRadiusSmall))
                } else {
                    RoundedRectangle(cornerRadius: RD.cornerRadiusSmall)
                        .fill(.quaternary)
                }
            }
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    let icon: String?

    init(_ title: String, icon: String? = nil) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: RD.Spacing.sm) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            VStack { Divider() }
        }
    }
}

// MARK: - Breadcrumb Path Bar

struct BreadcrumbView<ID: Hashable>: View {
    let components: [(name: String, id: ID)]
    let onNavigate: (ID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(components.enumerated()), id: \.element.id) { index, component in
                    Button {
                        onNavigate(component.id)
                    } label: {
                        Text(component.name)
                            .font(.system(size: 12, weight: index == components.count - 1 ? .semibold : .regular))
                            .foregroundStyle(index == components.count - 1 ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.001))
                    .cornerRadius(4)

                    if index < components.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.quaternary)
                    }
                }
            }
            .padding(.horizontal, RD.Spacing.md)
            .padding(.vertical, RD.Spacing.xs + 1)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String?

    init(_ title: String, icon: String, subtitle: String? = nil) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(spacing: RD.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)

            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 200)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pane Header

struct PaneHeader: View {
    let title: String
    let icon: String
    let subtitle: String?

    init(_ title: String, icon: String, subtitle: String? = nil) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(spacing: RD.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.riverPrimary)

            Text(title)
                .font(.system(size: 12, weight: .semibold))

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(.horizontal, RD.Spacing.md)
        .padding(.vertical, RD.Spacing.sm)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }
}
