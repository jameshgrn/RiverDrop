import SwiftUI

struct PaywallView: View {
    @EnvironmentObject var storeManager: StoreManager
    @Environment(\.dismiss) private var dismiss

    @State private var appeared = false

    private let features: [(icon: String, title: String, description: String, tint: Color)] = [
        ("bolt.fill", "Rsync Transfers", "Faster file transfers using rsync with progress tracking", .orange),
        ("doc.text.magnifyingglass", "Content Search", "Search inside files using ripgrep", Color.riverPrimary),
        ("bookmark.fill", "Unlimited Bookmarks", "Save as many folder bookmarks as you need", .purple),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: RD.Spacing.xl) {
                    hero
                    featureCards
                    purchaseSection
                }
                .padding(RD.Spacing.xxl)
            }
        }
        .background(
            LinearGradient(
                colors: [
                    Color.riverPrimary.opacity(0.08),
                    Color.riverGlow.opacity(0.04),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(width: 420)
        .frame(idealHeight: 520)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) {
                appeared = true
            }
        }
    }

    // MARK: - Hero

    @State private var heroFloat = false

    private var hero: some View {
        VStack(spacing: RD.Spacing.sm) {
            Image(systemName: "drop.fill")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.riverPrimary, .riverGlow],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .riverGlow.opacity(heroFloat ? 0.4 : 0.15), radius: heroFloat ? 18 : 10)
                .offset(y: heroFloat ? -3 : 3)
                .animation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true), value: heroFloat)
                .padding(.bottom, RD.Spacing.xs)
                .onAppear { heroFloat = true }

            Text("RiverDrop Pro")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .tracking(0.3)

            Text("Unlock the full power of RiverDrop")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Feature Cards

    private var featureCards: some View {
        VStack(spacing: RD.Spacing.md) {
            ForEach(features, id: \.title) { feature in
                featureCard(feature)
            }
        }
    }

    private func featureCard(_ feature: (icon: String, title: String, description: String, tint: Color)) -> some View {
        HStack(spacing: RD.Spacing.lg) {
            Image(systemName: feature.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    LinearGradient(
                        colors: [feature.tint, feature.tint.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .shadow(color: feature.tint.opacity(0.25), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .fontWeight(.semibold)
                    .font(.callout)

                Text(feature.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .cardStyle(padding: RD.Spacing.md)
    }

    // MARK: - Purchase

    private var purchaseSection: some View {
        VStack(spacing: RD.Spacing.lg) {
            if let error = storeManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RD.Spacing.md)
                    .padding(.vertical, RD.Spacing.sm)
                    .background(.red.opacity(0.08), in: Capsule())
            }

            if let product = storeManager.proProduct {
                Text(product.displayPrice)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Button {
                    Task { await storeManager.purchase() }
                } label: {
                    if storeManager.isPurchasing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Get RiverDrop Pro")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(RDButtonStyle(isProminent: true))
                .disabled(storeManager.isPurchasing)
            } else {
                ProgressView("Loading...")
                    .controlSize(.small)
            }

            HStack(spacing: RD.Spacing.lg) {
                Button("Restore Purchases") {
                    Task { await storeManager.restorePurchases() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)

                Button("Not Now") {
                    dismiss()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
    }
}
