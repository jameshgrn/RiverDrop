import AppKit
import Foundation

enum LocalFileOperations {
    /// Open a file or directory. Directories navigate via the provided closure; files open in default app.
    static func openFile(_ file: LocalFileItem, navigate: (URL) -> Void) {
        if file.isDirectory {
            navigate(file.url)
        } else {
            NSWorkspace.shared.open(file.url)
        }
    }

    /// Reveal a file in Finder with it selected.
    static func showInFinder(_ file: LocalFileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    /// Copy a file's path to the system pasteboard.
    static func copyItemPath(_ file: LocalFileItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(file.url.path, forType: .string)
    }

    /// Copy a directory path to the system pasteboard.
    static func copyDirectoryPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    /// Move a single file to the Trash. Returns an error message on failure, nil on success.
    @discardableResult
    static func moveToTrash(_ file: LocalFileItem) -> String? {
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            return nil
        } catch {
            return "Move to Trash failed for \(file.filename): \(error.localizedDescription). Suggested fix: check file permissions."
        }
    }

    /// Move multiple files to the Trash. Returns error messages for any failures.
    static func trashFiles(_ files: [LocalFileItem]) -> [String] {
        files.compactMap { moveToTrash($0) }
    }

    /// Permanently delete a file. Returns an error message on failure, nil on success.
    @discardableResult
    static func permanentlyDelete(_ file: LocalFileItem) -> String? {
        do {
            try FileManager.default.removeItem(at: file.url)
            return nil
        } catch {
            return "Delete failed for \(file.filename): \(error.localizedDescription). Suggested fix: check file permissions."
        }
    }

    /// Rename a file. Returns an error message on failure, nil on success.
    @discardableResult
    static func rename(_ file: LocalFileItem, to newName: String) -> String? {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != file.filename else { return nil }
        let newURL = file.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: file.url, to: newURL)
            return nil
        } catch {
            return "Rename failed for \(file.filename): \(error.localizedDescription). Suggested fix: check permissions and ensure name is valid."
        }
    }
}
