import SwiftUI

// MARK: - FocusedValue Keys

struct IsConnectedKey: FocusedValueKey {
    typealias Value = Bool
}

struct DisconnectActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct RefreshActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ShowHiddenLocalFilesKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct ShowHiddenRemoteFilesKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct IsTransferLogExpandedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct NavigateToBookmarkKey: FocusedValueKey {
    typealias Value = (String) -> Void
}

// MARK: - FocusedValues Extensions

extension FocusedValues {
    var isConnected: Bool? {
        get { self[IsConnectedKey.self] }
        set { self[IsConnectedKey.self] = newValue }
    }

    var disconnect: (() -> Void)? {
        get { self[DisconnectActionKey.self] }
        set { self[DisconnectActionKey.self] = newValue }
    }

    var refresh: (() -> Void)? {
        get { self[RefreshActionKey.self] }
        set { self[RefreshActionKey.self] = newValue }
    }

    var showHiddenLocalFiles: Binding<Bool>? {
        get { self[ShowHiddenLocalFilesKey.self] }
        set { self[ShowHiddenLocalFilesKey.self] = newValue }
    }

    var showHiddenRemoteFiles: Binding<Bool>? {
        get { self[ShowHiddenRemoteFilesKey.self] }
        set { self[ShowHiddenRemoteFilesKey.self] = newValue }
    }

    var isTransferLogExpanded: Binding<Bool>? {
        get { self[IsTransferLogExpandedKey.self] }
        set { self[IsTransferLogExpandedKey.self] = newValue }
    }

    var navigateToBookmark: ((String) -> Void)? {
        get { self[NavigateToBookmarkKey.self] }
        set { self[NavigateToBookmarkKey.self] = newValue }
    }
}
