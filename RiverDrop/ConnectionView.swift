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
                    try KeychainHelper.save(username: username, host: host, password: password)
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
            let savedHost = UserDefaults.standard.string(forKey: "lastHost") ?? ""
            let savedUser = UserDefaults.standard.string(forKey: "lastUsername") ?? ""

            if host.isEmpty { host = savedHost }
            if username.isEmpty { username = savedUser }

            if !username.isEmpty && !host.isEmpty {
                do {
                    if let savedPassword = try KeychainHelper.load(username: username, host: host) {
                        password = savedPassword
                    }
                } catch {
                    sftpService.errorMessage = "Load credentials failed for \(username): \(error.localizedDescription). Suggested fix: remove the saved keychain entry and reconnect."
                }
            }
        }
    }
}
