import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.riverdrop.sftp"

    static func save(account: String, host: String, password: String) throws {
        try delete(account: account)
        let payload = "\(host)\n\(password)"
        guard let data = payload.data(using: .utf8) else {
            throw KeychainError.payloadEncodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(operation: "save credentials", status: status)
        }
    }

    static func load(account: String) throws -> (host: String, password: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(operation: "load credentials", status: status)
        }

        guard let data = result as? Data,
              let payload = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.invalidPayload(account: account)
        }

        let parts = payload.split(separator: "\n", maxSplits: 1)
        guard parts.count == 2 else {
            throw KeychainError.invalidPayload(account: account)
        }

        return (host: String(parts[0]), password: String(parts[1]))
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(operation: "delete credentials", status: status)
        }
    }
}

enum KeychainError: LocalizedError {
    case payloadEncodingFailed
    case invalidPayload(account: String)
    case unexpectedStatus(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .payloadEncodingFailed:
            return "Could not encode credentials for Keychain storage"
        case let .invalidPayload(account):
            return "Stored Keychain data is invalid for account \(account)"
        case let .unexpectedStatus(operation, status):
            let description = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain \(operation) failed: \(description)"
        }
    }
}
