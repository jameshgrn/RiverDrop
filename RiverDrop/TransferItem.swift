import Foundation

struct TransferItem: Identifiable {
    let id = UUID()
    let filename: String
    let isUpload: Bool
    let destinationDirectory: String
    var progress: Double = 0
    var status: TransferStatus = .inProgress

    enum TransferStatus: String {
        case inProgress = "Transferring"
        case completed = "Completed"
        case failed = "Failed"
        case skipped = "Skipped"
        case cancelled = "Cancelled"
    }
}

enum ConflictResolution {
    case replace, rename, cancel
}
