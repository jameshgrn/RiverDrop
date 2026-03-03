import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var sftpService: SFTPService

    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false

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
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
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
                isConnecting = true
                sftpService.errorMessage = nil

                do {
                    try KeychainHelper.save(account: username, host: host, password: password)
                } catch {
                    sftpService.errorMessage = "Save credentials failed for \(username): \(error.localizedDescription). Suggested fix: unlock Keychain access for RiverDrop and retry."
                }

                UserDefaults.standard.set(username, forKey: "lastUsername")
                UserDefaults.standard.set(host, forKey: "lastHost")

                Task {
                    await sftpService.connect(host: host, username: username, password: password)
                    isConnecting = false
                }
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
            .disabled(host.isEmpty || username.isEmpty || password.isEmpty || isConnecting)
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 350)
        .onAppear {
            if let savedHost = UserDefaults.standard.string(forKey: "lastHost") {
                host = savedHost
            }

            if !username.isEmpty {
                do {
                    if let creds = try KeychainHelper.load(account: username) {
                        host = creds.host
                        password = creds.password
                    }
                } catch {
                    sftpService.errorMessage = "Load credentials failed for \(username): \(error.localizedDescription). Suggested fix: remove the saved keychain entry and reconnect."
                }
            } else if let lastUser = UserDefaults.standard.string(forKey: "lastUsername") {
                do {
                    if let creds = try KeychainHelper.load(account: lastUser) {
                        username = lastUser
                        host = creds.host
                        password = creds.password
                    }
                } catch {
                    sftpService.errorMessage = "Load credentials failed for \(lastUser): \(error.localizedDescription). Suggested fix: remove the saved keychain entry and reconnect."
                }
            }
        }
    }
}
