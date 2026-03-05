import Foundation
import SwiftUI

enum AppCommandPayload {
    static let openPanel = "__open_panel__"
}

struct SelectedRemotePathsKey: FocusedValueKey {
    typealias Value = [String]
}

struct NavigateLocalPathKey: FocusedValueKey {
    typealias Value = (String) -> Void
}

extension FocusedValues {
    var selectedRemotePaths: [String]? {
        get { self[SelectedRemotePathsKey.self] }
        set { self[SelectedRemotePathsKey.self] = newValue }
    }

    var navigateLocalPath: ((String) -> Void)? {
        get { self[NavigateLocalPathKey.self] }
        set { self[NavigateLocalPathKey.self] = newValue }
    }
}
