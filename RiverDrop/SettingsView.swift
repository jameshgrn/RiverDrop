import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }

            FilesSettingsTab()
                .tabItem { Label("Files", systemImage: "folder") }

            TransferSettingsTab()
                .tabItem { Label("Transfer", systemImage: "arrow.up.arrow.down") }
        }
        .frame(width: 420, height: 260)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @AppStorage(DefaultsKey.defaultLocalDirectory) private var defaultLocalDirectory = ""
    @AppStorage(DefaultsKey.defaultPort) private var defaultPort = 22
    @AppStorage(DefaultsKey.rememberCredentials) private var rememberCredentials = true
    @AppStorage(DefaultsKey.enableKerberosRenewal) private var enableKerberosRenewal = false

    var body: some View {
        Form {
            HStack {
                TextField("Default local directory", text: $defaultLocalDirectory)
                    .textFieldStyle(.roundedBorder)

                Button("Choose\u{2026}") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Select"
                    if panel.runModal() == .OK, let url = panel.url {
                        defaultLocalDirectory = url.path
                    }
                }
            }

            Stepper("Default SSH port: \(defaultPort)", value: $defaultPort, in: 1...65535)

            Toggle("Remember credentials", isOn: $rememberCredentials)

            Divider()

            Toggle("Renew Kerberos/AFS on connect", isOn: $enableKerberosRenewal)
                .help("Runs kinit -R and klog before each connection. Enable for HPC/university clusters that use Kerberos authentication.")
        }
        .padding()
    }
}

// MARK: - Files

private struct FilesSettingsTab: View {
    @AppStorage(DefaultsKey.showHiddenLocalFiles) private var showHiddenLocalFiles = false
    @AppStorage(DefaultsKey.showHiddenRemoteFiles) private var showHiddenRemoteFiles = false

    var body: some View {
        Form {
            Toggle("Show hidden local files", isOn: $showHiddenLocalFiles)
            Toggle("Show hidden remote files", isOn: $showHiddenRemoteFiles)
        }
        .padding()
    }
}

// MARK: - Transfer

private struct TransferSettingsTab: View {
    @AppStorage(DefaultsKey.alwaysPreviewBeforeSync) private var alwaysPreviewBeforeSync = false

    var body: some View {
        Form {
            Toggle("Always preview before sync", isOn: $alwaysPreviewBeforeSync)
        }
        .padding()
    }
}
