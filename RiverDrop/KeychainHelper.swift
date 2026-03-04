import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.riverdrop.sftp"

    struct KeychainPayload: Codable {
        let host: String
        let password: String
    }

    static func save(username: String, host: String, password: String) throws {
        let account = "\(username.lowercased())@\(host.lowercased())"
        try delete(account: account)

        let payload = KeychainPayload(host: host, password: password)
        let data = try JSONEncoder().encode(payload)

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

    static func load(username: String, host: String) throws -> String? {
        let account = "\(username.lowercased())@\(host.lowercased())"
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

        guard let data = result as? Data else {
            throw KeychainError.invalidPayload(account: account)
        }

        do {
            let payload = try JSONDecoder().decode(KeychainPayload.self, from: data)
            return payload.password
        } catch {
            throw KeychainError.invalidPayload(account: account)
        }
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

enum HostKeyKeychainHelper {
    private static let service = "com.riverdrop.hostkeys"

    static func load(for host: String) -> String? {
        let account = host.lowercased()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ openSSHKey: String, for host: String) {
        let account = host.lowercased()
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard let data = openSSHKey.data(using: .utf8) else { return }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
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
