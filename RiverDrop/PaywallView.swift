import SwiftUI

struct LicenseView: View {
    @Environment(LicenseManager.self) private var licenseManager
    @State private var keyInput = ""
    @FocusState private var isKeyFieldFocused: Bool

    private static let purchaseURL = URL(string: "https://riverdrop.gumroad.com/l/riverdrop")!

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: RD.Spacing.xxl) {
                header
                inputSection
                errorSection
                purchaseLink
            }
            .frame(maxWidth: 420)
            .cardStyle(padding: RD.Spacing.xxl)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.riverSurface)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: RD.Spacing.md) {
            Image(systemName: "key.fill")
                .font(.largeTitle)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.riverPrimary, .riverAccent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("Activate RiverDrop")
                .font(.title2.weight(.semibold))

            Text("Enter the license key from your purchase email.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Input

    @MainActor
    private var inputSection: some View {
        VStack(spacing: RD.Spacing.md) {
            TextField("License key", text: $keyInput)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .padding(RD.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: RD.cornerRadiusSmall)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RD.cornerRadiusSmall)
                        .strokeBorder(
                            isKeyFieldFocused ? Color.riverPrimary.opacity(0.5) : Color.primary.opacity(0.1),
                            lineWidth: 1
                        )
                )
                .focused($isKeyFieldFocused)
                .onSubmit { activateKey() }
                .disabled(licenseManager.isValidating)

            Button(action: activateKey) {
                HStack(spacing: RD.Spacing.sm) {
                    if licenseManager.isValidating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(licenseManager.isValidating ? "Validating..." : "Activate")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RDButtonStyle())
            .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || licenseManager.isValidating)
        }
    }

    // MARK: - Error

    @ViewBuilder
    private var errorSection: some View {
        if let error = licenseManager.validationError {
            HStack(spacing: RD.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .padding(RD.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RD.cornerRadiusSmall)
                    .fill(Color.red.opacity(0.08))
            )
        }
    }

    // MARK: - Purchase Link

    private var purchaseLink: some View {
        HStack(spacing: RD.Spacing.xs) {
            Text("Don't have a license?")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("Purchase RiverDrop", destination: Self.purchaseURL)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.riverPrimary)
        }
    }

    // MARK: - Actions

    private func activateKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Task {
            await licenseManager.validate(key: key)
        }
    }
}
