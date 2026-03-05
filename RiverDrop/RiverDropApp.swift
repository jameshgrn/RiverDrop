import SwiftUI

@main
struct RiverDropApp: App {
    @StateObject private var sftpService: SFTPService
    @StateObject private var transferManager: TransferManager
    @StateObject private var storeManager: StoreManager
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(DefaultsKey.showHiddenLocalFiles) private var showHiddenLocalFiles = false
    @AppStorage(DefaultsKey.showHiddenRemoteFiles) private var showHiddenRemoteFiles = false
    @AppStorage(DefaultsKey.isTransferLogExpanded) private var isTransferLogExpanded = false

    init() {
        let service = SFTPService()
        let store = StoreManager()
        _sftpService = StateObject(wrappedValue: service)
        _storeManager = StateObject(wrappedValue: store)
        _transferManager = StateObject(wrappedValue: TransferManager(sftpService: service, storeManager: store))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if sftpService.isConnected {
                    MainView()
                } else {
                    ConnectionView()
                }
            }
            .environmentObject(sftpService)
            .environmentObject(transferManager)
            .environmentObject(storeManager)
            .frame(minWidth: 800, minHeight: 550)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await storeManager.checkEntitlements() }
                }
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
                    postNavigateLocalPathCommand("/Users/\(NSUserName())")
                }
                .keyboardShortcut("1", modifiers: .command)

                Divider()

                Button("Navigate to Folder\u{2026}") {
                    postNavigateLocalPathCommand(AppCommandPayload.openPanel)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }

    private func postNavigateLocalPathCommand(_ path: String) {
        NotificationCenter.default.post(name: .riverDropNavigateLocalPath, object: path)
    }
}
