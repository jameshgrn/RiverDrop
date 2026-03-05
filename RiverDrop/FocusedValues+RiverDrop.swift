import Foundation
import SwiftUI

enum AppCommandPayload {
    static let openPanel = "__open_panel__"
}

extension Notification.Name {
    static let riverDropNavigateLocalPath = Notification.Name("riverDropNavigateLocalPath")
}

struct SelectedRemotePathsKey: FocusedValueKey {
    typealias Value = [String]
}

extension FocusedValues {
    var selectedRemotePaths: [String]? {
        get { self[SelectedRemotePathsKey.self] }
        set { self[SelectedRemotePathsKey.self] = newValue }
    }
}
