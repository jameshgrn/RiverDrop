import SwiftUI

private enum AuthMode: String, CaseIterable {
    case password = "Password"
    case sshKey = "SSH Key"
    case keyboardInteractive = "2FA"
}

private let disabledAuthModes: Set<AuthMode> = [.keyboardInteractive]

struct ConnectionView: View {
    @Environment(SFTPService.self) var sftpService
    var prefill: ServerEntry? = nil

    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var authMode: AuthMode = .password
    @State private var sshKeyPath = ""
    @State private var passphrase = ""
    @State private var discoveredKeys: [SSHKeyInfo] = []
    @State private var isConnecting = false
    @State private var appeared = false
    @State private var connectTask: Task<Void, Never>?

    private var canConnect: Bool {
        guard !host.isEmpty, !username.isEmpty, !isConnecting else { return false }
        switch authMode {
        case .password:
            return !password.isEmpty
        case .sshKey:
            return !sshKeyPath.isEmpty
        case .keyboardInteractive:
            return false
        }
    }

    var body: some View {
        ZStack {
            backgroundGradient

            VStack(spacing: RD.Spacing.xl) {
                heroSection

                formSection
                    .disabled(isConnecting)
                    .opacity(isConnecting ? 0.5 : 1)

                if let error = sftpService.errorMessage {
                    errorCard(error)
                }

                connectButton
            }
            .cardStyle(padding: RD.Spacing.xxl)
            .frame(maxWidth: 380)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.98)
            .animation(.easeOut(duration: 0.2), value: appeared)
        }
        .frame(minWidth: 400, minHeight: 400)
        .onAppear {
            discoveredKeys = SSHKeyManager.discoverKeys()
            restoreSavedState()
            withAnimation(.easeOut(duration: 0.2)) {
                appeared = true
            }
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.riverPrimary.opacity(0.06),
                    Color.riverAccent.opacity(0.02),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.riverGlow.opacity(0.06),
                    Color.clear,
                ],
                center: .center,
                startRadius: 50,
                endRadius: 350
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Hero

    @State private var heroGlow = false

    private var heroSection: some View {
        VStack(spacing: RD.Spacing.sm) {
            Image(systemName: "drop.fill")
                .font(.system(size: 42))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.riverPrimary, .riverAccent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .riverGlow.opacity(heroGlow ? 0.5 : 0.15), radius: heroGlow ? 16 : 8)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                        heroGlow = true
                    }
                }

            Text("RiverDrop")
                .font(.title.weight(.bold))
                .tracking(0.3)

            Text("Secure File Transfer")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Form

    private var formSection: some View {
        VStack(spacing: RD.Spacing.md) {
            SectionHeader("Server", icon: "server.rack")

            inputField(icon: "globe", placeholder: "Host", text: $host)
            inputField(icon: "person", placeholder: "Username", text: $username)

            Spacer().frame(height: RD.Spacing.xs)

            SectionHeader("Authentication", icon: "lock.shield")

            authModePicker

            Group {
                switch authMode {
                case .password:
                    secureInputField(icon: "key", placeholder: "Password", text: $password)
                case .sshKey:
                    sshKeySection
                case .keyboardInteractive:
                    keyboardInteractiveNotice
                }
            }
            .animation(.easeInOut(duration: 0.1), value: authMode)
        }
    }

    // MARK: - Auth Mode Picker

    @Namespace private var authPickerNS

    private var authModePicker: some View {
        HStack(spacing: 0) {
            ForEach(AuthMode.allCases, id: \.self) { mode in
                authModeButton(mode)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func authModeButton(_ mode: AuthMode) -> some View {
        let isDisabled = disabledAuthModes.contains(mode)
        let isSelected = authMode == mode
        return Button {
            guard !isDisabled else { return }
            withAnimation(.spring(response: 0.16, dampingFraction: 0.82)) {
                authMode = mode
            }
        } label: {
            authModeLabel(mode: mode, isSelected: isSelected, isDisabled: isDisabled)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(isDisabled ? KeyboardInteractiveAuth.unsupportedReason : "")
    }

    private func authModeLabel(mode: AuthMode, isSelected: Bool, isDisabled: Bool) -> some View {
        HStack(spacing: RD.Spacing.xs) {
            Image(systemName: authModeIcon(mode))
                .font(.caption2)
            Text(mode.rawValue)
                .font(.callout.weight(.medium))
        }
        .foregroundStyle(
            isDisabled ? AnyShapeStyle(.quaternary) :
                isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, RD.Spacing.sm)
        .background {
            if isSelected, !isDisabled {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.riverPrimary, .riverGlow],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .matchedGeometryEffect(id: "authPill", in: authPickerNS)
                    .shadow(color: .riverPrimary.opacity(0.3), radius: 6, y: 2)
            }
        }
    }

    private func authModeIcon(_ mode: AuthMode) -> String {
        switch mode {
        case .password: return "key.fill"
        case .sshKey: return "key.radiowaves.forward"
        case .keyboardInteractive: return "lock.trianglebadge.exclamationmark"
        }
    }

    // MARK: - SSH Key Section

    private var sshKeySection: some View {
        VStack(spacing: RD.Spacing.sm) {
            HStack(spacing: RD.Spacing.sm) {
                Image(systemName: "key.viewfinder")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                Picker("", selection: $sshKeyPath) {
                    Text("Select a key\u{2026}").tag("")
                    ForEach(discoveredKeys) { key in
                        Text(key.filename).tag(key.path)
                    }
                }
                .labelsHidden()

                Button("Browse\u{2026}") { browseForKey() }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.riverPrimary)
            }
            .padding(RD.Spacing.md)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: RD.cornerRadiusSmall))

            if !sshKeyPath.isEmpty {
                HStack(spacing: RD.Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text(sshKeyPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, RD.Spacing.sm)
                .padding(.vertical, RD.Spacing.xs)
                .background(Color.green.opacity(0.08), in: Capsule())
            }

            secureInputField(icon: "lock", placeholder: "Passphrase (optional)", text: $passphrase)
        }
    }

    // MARK: - Keyboard Interactive Notice

    private var keyboardInteractiveNotice: some View {
        HStack(alignment: .top, spacing: RD.Spacing.sm) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
                .font(.callout)
            Text(KeyboardInteractiveAuth.unsupportedReason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .padding(RD.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: RD.cornerRadiusSmall))
    }

    // MARK: - Input Fields

    private func inputField(icon: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: RD.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
        }
        .padding(RD.Spacing.md)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: RD.cornerRadiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: RD.cornerRadiusSmall)
                .strokeBorder(
                    !text.wrappedValue.isEmpty ? Color.riverPrimary.opacity(0.2) : Color.primary.opacity(0.06),
                    lineWidth: 0.5
                )
        )
    }

    private func secureInputField(icon: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: RD.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
        }
        .padding(RD.Spacing.md)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: RD.cornerRadiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: RD.cornerRadiusSmall)
                .strokeBorder(
                    !text.wrappedValue.isEmpty ? Color.riverPrimary.opacity(0.2) : Color.primary.opacity(0.06),
                    lineWidth: 0.5
                )
        )
    }

    // MARK: - Error Card

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: RD.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red.opacity(0.8))
                .font(.callout)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .padding(RD.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: RD.cornerRadiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: RD.cornerRadiusSmall)
                .strokeBorder(Color.red.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - Connect Button

    private var connectButton: some View {
        HStack(spacing: RD.Spacing.sm) {
            if isConnecting {
                Button {
                    connectTask?.cancel()
                    connectTask = nil
                    isConnecting = false
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RDButtonStyle(isProminent: false))
                .keyboardShortcut(.cancelAction)
            }

            Button {
                performConnect()
            } label: {
                HStack(spacing: RD.Spacing.sm) {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.caption)
                    }
                    Text(isConnecting ? "Connecting\u{2026}" : "Connect")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RDButtonStyle(isProminent: true))
            .disabled(!canConnect)
            .opacity(canConnect ? 1 : 0.4)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, RD.Spacing.xs)
    }

    // MARK: - Actions

    private func performConnect() {
        isConnecting = true
        sftpService.errorMessage = nil

        UserDefaults.standard.set(username, forKey: DefaultsKey.lastUsername)
        UserDefaults.standard.set(host, forKey: DefaultsKey.lastHost)
        UserDefaults.standard.set(authMode.rawValue, forKey: DefaultsKey.lastAuthMode)

        if authMode == .password {
            do {
                try KeychainHelper.save(username: username, host: host, password: password)
            } catch {
                sftpService.errorMessage = "Save credentials failed for \(username): \(error.localizedDescription). Suggested fix: unlock Keychain access for RiverDrop and retry."
            }
        }

        if authMode == .sshKey {
            UserDefaults.standard.set(sshKeyPath, forKey: DefaultsKey.lastSSHKeyPath)
        }

        connectTask = Task {
            switch authMode {
            case .password:
                await sftpService.connect(host: host, username: username, password: password)
            case .sshKey:
                await sftpService.connect(
                    host: host,
                    username: username,
                    keyPath: sshKeyPath,
                    passphrase: passphrase.isEmpty ? nil : passphrase
                )
            case .keyboardInteractive:
                break // Unreachable: connect button is disabled for this mode
            }
            isConnecting = false
            connectTask = nil
        }
    }

    private func restoreSavedState() {
        if let server = prefill {
            if host.isEmpty { host = server.host }
            if username.isEmpty { username = server.user }
            if let keyPath = server.identityFile, sshKeyPath.isEmpty {
                sshKeyPath = keyPath
                authMode = .sshKey
            }
            return
        }

        let savedHost = UserDefaults.standard.string(forKey: DefaultsKey.lastHost) ?? ""
        let savedUser = UserDefaults.standard.string(forKey: DefaultsKey.lastUsername) ?? ""

        if host.isEmpty { host = savedHost }
        if username.isEmpty { username = savedUser }

        if let savedMode = UserDefaults.standard.string(forKey: DefaultsKey.lastAuthMode),
           let mode = AuthMode(rawValue: savedMode),
           !disabledAuthModes.contains(mode)
        {
            authMode = mode
        }

        if authMode == .sshKey {
            let savedKeyPath = UserDefaults.standard.string(forKey: DefaultsKey.lastSSHKeyPath) ?? ""
            if !savedKeyPath.isEmpty, discoveredKeys.contains(where: { $0.path == savedKeyPath }) {
                sshKeyPath = savedKeyPath
            }
        }

        if authMode == .password, !username.isEmpty, !host.isEmpty {
            do {
                if let savedPassword = try KeychainHelper.load(username: username, host: host) {
                    password = savedPassword
                }
            } catch {
                sftpService.errorMessage = "Load credentials failed for \(username): \(error.localizedDescription). Suggested fix: remove the saved keychain entry and reconnect."
            }
        }
    }

    private func browseForKey() {
        let panel = NSOpenPanel()
        panel.title = "Select SSH Private Key"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try SSHKeyManager.saveBookmark(for: url)
            } catch {
                sftpService.errorMessage = "Failed to save SSH key bookmark: \(error.localizedDescription)"
                return
            }
            let newKey = SSHKeyInfo(path: url.path, filename: url.lastPathComponent)
            if !discoveredKeys.contains(where: { $0.path == newKey.path }) {
                discoveredKeys.append(newKey)
            }
            sshKeyPath = url.path
        }
    }
}
