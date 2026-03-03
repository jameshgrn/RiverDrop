import SwiftUI

@main
struct RiverDropApp: App {
    @StateObject private var sftpService: SFTPService
    @StateObject private var transferManager: TransferManager

    init() {
        let service = SFTPService()
        _sftpService = StateObject(wrappedValue: service)
        _transferManager = StateObject(wrappedValue: TransferManager(sftpService: service))
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
            .frame(minWidth: 700, minHeight: 500)
        }
    }
}
