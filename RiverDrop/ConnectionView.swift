import SwiftUI

private enum AuthMode: String, CaseIterable {
    case password = "Password"
    case sshKey = "SSH Key"
}

struct ConnectionView: View {
    @EnvironmentObject var sftpService: SFTPService

    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var authMode: AuthMode = .password
    @State private var sshKeyPath = ""
    @State private var passphrase = ""
    @State private var discoveredKeys: [SSHKeyInfo] = []
    @State private var isConnecting = false

    private var canConnect: Bool {
        guard !host.isEmpty, !username.isEmpty, !isConnecting else { return false }
        switch authMode {
        case .password:
            return !password.isEmpty
        case .sshKey:
            return !sshKeyPath.isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("RiverDrop")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("SFTP File Transfer")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            Form {
                TextField("Host", text: $host)
                    .textFieldStyle(.roundedBorder)
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)

                Picker("Auth", selection: $authMode) {
                    ForEach(AuthMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch authMode {
                case .password:
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                case .sshKey:
                    HStack {
                        Picker("Key", selection: $sshKeyPath) {
                            Text("Select a key...").tag("")
                            ForEach(discoveredKeys) { key in
                                Text(key.filename).tag(key.path)
                            }
                        }
                        .frame(minWidth: 140)

                        Button("Browse...") { browseForKey() }
                    }

                    if !sshKeyPath.isEmpty {
                        Text(sshKeyPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    SecureField("Passphrase (optional)", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 350)

            if let error = sftpService.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }

            Button {
                performConnect()
            } label: {
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 120)
                } else {
                    Text("Connect")
                        .frame(width: 120)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canConnect)
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 400)
        .onAppear {
            discoveredKeys = SSHKeyManager.discoverKeys()
            restoreSavedState()
        }
    }

    private func performConnect() {
        isConnecting = true
        sftpService.errorMessage = nil

        UserDefaults.standard.set(username, forKey: "lastUsername")
        UserDefaults.standard.set(host, forKey: "lastHost")
        UserDefaults.standard.set(authMode.rawValue, forKey: "lastAuthMode")

        if authMode == .password {
            do {
                try KeychainHelper.save(username: username, host: host, password: password)
            } catch {
                sftpService.errorMessage = "Save credentials failed for \(username): \(error.localizedDescription). Suggested fix: unlock Keychain access for RiverDrop and retry."
            }
        }

        if authMode == .sshKey {
            UserDefaults.standard.set(sshKeyPath, forKey: "lastSSHKeyPath")
        }

        Task {
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
            }
            isConnecting = false
        }
    }

    private func restoreSavedState() {
        let savedHost = UserDefaults.standard.string(forKey: "lastHost") ?? ""
        let savedUser = UserDefaults.standard.string(forKey: "lastUsername") ?? ""

        if host.isEmpty { host = savedHost }
        if username.isEmpty { username = savedUser }

        if let savedMode = UserDefaults.standard.string(forKey: "lastAuthMode"),
           let mode = AuthMode(rawValue: savedMode)
        {
            authMode = mode
        }

        if authMode == .sshKey {
            let savedKeyPath = UserDefaults.standard.string(forKey: "lastSSHKeyPath") ?? ""
            if !savedKeyPath.isEmpty, FileManager.default.isReadableFile(atPath: savedKeyPath) {
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
            sshKeyPath = url.path
        }
    }
}
