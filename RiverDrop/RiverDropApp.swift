import SwiftUI

@main
struct RiverDropApp: App {
    @StateObject private var sftpService: SFTPService
    @StateObject private var transferManager: TransferManager
    @StateObject private var storeManager: StoreManager

    @FocusedValue(\.isConnected) private var isConnected
    @FocusedValue(\.disconnect) private var disconnect
    @FocusedValue(\.refresh) private var refresh
    @FocusedValue(\.showHiddenLocalFiles) private var showHiddenLocalFiles
    @FocusedValue(\.showHiddenRemoteFiles) private var showHiddenRemoteFiles
    @FocusedValue(\.isTransferLogExpanded) private var isTransferLogExpanded
    @FocusedValue(\.navigateToBookmark) private var navigateToBookmark

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
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("Refresh") {
                    refresh?()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(isConnected != true)

                Divider()

                Button("Disconnect") {
                    disconnect?()
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(isConnected != true)
            }

            // View menu
            CommandGroup(after: .toolbar) {
                Toggle(
                    "Show Hidden Files \u{2014} Local",
                    isOn: showHiddenLocalFiles ?? .constant(false)
                )
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Toggle(
                    "Show Hidden Files \u{2014} Remote",
                    isOn: showHiddenRemoteFiles ?? .constant(false)
                )
                .keyboardShortcut(",", modifiers: [.command, .shift])

                Divider()

                Toggle(
                    "Toggle Transfer Log",
                    isOn: isTransferLogExpanded ?? .constant(false)
                )
                .keyboardShortcut("l", modifiers: .command)
            }

            // Go menu
            CommandMenu("Go") {
                if FileManager.default.fileExists(atPath: "/Users/\(NSUserName())/projects") {
                    Button("Projects") {
                        navigateToBookmark?("/Users/\(NSUserName())/projects")
                    }
                    .keyboardShortcut("1", modifiers: .command)
                }

                if FileManager.default.fileExists(atPath: "/Users/\(NSUserName())") {
                    Button("Home") {
                        navigateToBookmark?("/Users/\(NSUserName())")
                    }
                    .keyboardShortcut("2", modifiers: .command)
                }

                if FileManager.default.fileExists(atPath: "/not_backed_up/\(NSUserName())") {
                    Button("Cluster Scratch") {
                        navigateToBookmark?("/not_backed_up/\(NSUserName())")
                    }
                    .keyboardShortcut("3", modifiers: .command)
                }

                Divider()

                Button("Navigate to Folder\u{2026}") {
                    navigateToBookmark?("__open_panel__")
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
