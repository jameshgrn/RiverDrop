import SwiftUI

@main
struct RiverDropApp: App {
    @State private var licenseManager = LicenseManager()
    @State private var sftpService: SFTPService
    @State private var transferManager: TransferManager
    @State private var serverStore = ServerStore()
    @State private var selectedServerID: ServerEntry.ID?
    @FocusedValue(\.selectedRemotePaths) private var selectedRemotePaths
    @FocusedValue(\.navigateLocalPath) private var navigateLocalPath

    @AppStorage(DefaultsKey.showHiddenLocalFiles) private var showHiddenLocalFiles = false
    @AppStorage(DefaultsKey.showHiddenRemoteFiles) private var showHiddenRemoteFiles = false
    @AppStorage(DefaultsKey.isTransferLogExpanded) private var isTransferLogExpanded = false

    init() {
        let service = SFTPService()
        _sftpService = State(initialValue: service)
        _transferManager = State(initialValue: TransferManager(sftpService: service))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                NavigationSplitView {
                    SidebarView(selectedServerID: $selectedServerID)
                } detail: {
                    if sftpService.isConnected {
                        MainView()
                    } else if let serverID = selectedServerID,
                              let server = serverStore.servers.first(where: { $0.id == serverID }) {
                        ConnectionView(prefill: server)
                    } else {
                        ConnectionView()
                    }
                }
                #else
                if licenseManager.isLicensed {
                    NavigationSplitView {
                        SidebarView(selectedServerID: $selectedServerID)
                    } detail: {
                        if sftpService.isConnected {
                            MainView()
                        } else if let serverID = selectedServerID,
                                  let server = serverStore.servers.first(where: { $0.id == serverID }) {
                            ConnectionView(prefill: server)
                        } else {
                            ConnectionView()
                        }
                    }
                } else {
                    LicenseView()
                }
                #endif
            }
            .environment(licenseManager)
            .environment(sftpService)
            .environment(transferManager)
            .environment(serverStore)
            .frame(minWidth: 800, minHeight: 550)
            .task {
                await licenseManager.loadStoredLicense()
            }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("Refresh") {
                    Task { await sftpService.listDirectory() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!sftpService.isConnected)

                Divider()

                Button("Disconnect") {
                    Task { await sftpService.disconnect() }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!sftpService.isConnected)
            }

            // Edit menu — Copy Remote Path
            CommandGroup(after: .pasteboard) {
                Button("Copy Remote Path") {
                    if let paths = selectedRemotePaths {
                        let joined = paths.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(joined, forType: .string)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(selectedRemotePaths?.isEmpty ?? true)
            }

            // View menu
            CommandGroup(after: .toolbar) {
                Toggle(
                    "Show Hidden Files \u{2014} Local",
                    isOn: $showHiddenLocalFiles
                )
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Toggle(
                    "Show Hidden Files \u{2014} Remote",
                    isOn: $showHiddenRemoteFiles
                )
                .keyboardShortcut(",", modifiers: [.command, .shift])

                Divider()

                Toggle(
                    "Toggle Transfer Log",
                    isOn: $isTransferLogExpanded
                )
                .keyboardShortcut("l", modifiers: .command)
            }

            // Go menu
            CommandMenu("Go") {
                Button("Home") {
                    navigateLocalPath?("/Users/\(NSUserName())")
                }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(navigateLocalPath == nil)

                Divider()

                Button("Navigate to Folder\u{2026}") {
                    navigateLocalPath?(AppCommandPayload.openPanel)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(navigateLocalPath == nil)
            }
        }

        Settings {
            SettingsView()
        }
    }

}
