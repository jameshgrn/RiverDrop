import SwiftUI

@main
struct RiverDropApp: App {
    @StateObject private var sftpService: SFTPService
    @StateObject private var transferManager: TransferManager
    @StateObject private var storeManager: StoreManager

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
    }
}
