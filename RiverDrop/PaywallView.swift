import SwiftUI

struct PaywallView: View {
    @EnvironmentObject var storeManager: StoreManager
    @Environment(\.dismiss) private var dismiss

    private let features: [(icon: String, title: String, description: String)] = [
        ("bolt.fill", "Rsync Transfers", "Faster file transfers using rsync with progress tracking"),
        ("doc.text.magnifyingglass", "Content Search", "Search inside files using ripgrep"),
        ("bookmark.fill", "Unlimited Bookmarks", "Save as many folder bookmarks as you need"),
    ]

    var body: some View {
        VStack(spacing: 20) {
            header
            Divider()
            featureList
            Divider()
            purchaseSection
        }
        .padding(30)
        .frame(width: 420, height: 480)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "drop.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text("RiverDrop Pro")
                .font(.title)
                .fontWeight(.bold)

            Text("Unlock the full power of RiverDrop")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(features, id: \.title) { feature in
                HStack(spacing: 12) {
                    Image(systemName: feature.icon)
                        .frame(width: 24)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title)
                            .fontWeight(.medium)
                        Text(feature.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }

    private var purchaseSection: some View {
        VStack(spacing: 12) {
            if let error = storeManager.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }

            if let product = storeManager.proProduct {
                Button {
                    Task { await storeManager.purchase() }
                } label: {
                    if storeManager.isPurchasing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 200)
                    } else {
                        Text("Buy Pro — \(product.displayPrice)")
                            .frame(width: 200)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(storeManager.isPurchasing)
            } else {
                ProgressView("Loading...")
                    .controlSize(.small)
            }

            Button("Restore Purchases") {
                Task { await storeManager.restorePurchases() }
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Button("Not Now") {
                dismiss()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
