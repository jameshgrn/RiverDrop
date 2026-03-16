import Foundation
import Security

// MARK: - License Keychain

private enum LicenseKeychainHelper {
    private static let service = "com.riverdrop.license"
    private static let account = "gumroad-license"

    struct LicensePayload: Codable {
        let key: String
        let email: String
        let validatedAt: Date
    }

    static func save(_ payload: LicensePayload) throws {
        try delete()
        let data = try JSONEncoder().encode(payload)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(operation: "save license", status: status)
        }
    }

    static func load() throws -> LicensePayload? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(operation: "load license", status: status)
        }
        guard let data = result as? Data else {
            throw KeychainError.invalidPayload(account: account)
        }
        return try JSONDecoder().decode(LicensePayload.self, from: data)
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(operation: "delete license", status: status)
        }
    }
}

// MARK: - Gumroad API Response

private struct GumroadVerifyResponse: Decodable {
    let success: Bool
    let purchase: Purchase?
    let message: String?

    struct Purchase: Decodable {
        let email: String
        let refunded: Bool
        let chargebacked: Bool

        enum CodingKeys: String, CodingKey {
            case email
            case refunded
            case chargebacked
        }
    }
}

// MARK: - License Validation Error

enum LicenseValidationError: LocalizedError {
    case invalidKey
    case refunded
    case chargebacked
    case networkError(String)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "Invalid license key. Please check your key and try again."
        case .refunded:
            return "This license has been refunded and is no longer valid."
        case .chargebacked:
            return "This license has been chargebacked and is no longer valid."
        case let .networkError(detail):
            return "Network error: \(detail)"
        case let .serverError(detail):
            return "Server error: \(detail)"
        }
    }
}

// MARK: - LicenseManager

@MainActor
@Observable
final class LicenseManager {
    private static let productID = "riverdrop"
    private static let verifyURL = URL(string: "https://api.gumroad.com/v2/licenses/verify")!
    private static let offlineGraceDays: TimeInterval = 7 * 24 * 60 * 60

    var isLicensed = false
    var licenseKey = ""
    var licenseeEmail = ""
    var validationError: String?
    var isValidating = false

    // MARK: - Lifecycle

    func loadStoredLicense() async {
        do {
            guard let payload = try LicenseKeychainHelper.load() else { return }
            licenseKey = payload.key
            licenseeEmail = payload.email

            let lastValidated = payload.validatedAt
            UserDefaults.standard.set(
                lastValidated.timeIntervalSince1970,
                forKey: DefaultsKey.licenseLastValidated
            )

            // Try online re-validation
            do {
                try await performValidation(key: payload.key)
            } catch {
                // Offline grace: accept if validated within the last 7 days
                let elapsed = Date().timeIntervalSince(lastValidated)
                if elapsed < Self.offlineGraceDays {
                    isLicensed = true
                } else {
                    isLicensed = false
                    validationError = "License re-validation failed and offline grace period expired."
                }
            }
        } catch {
            isLicensed = false
        }
    }

    // MARK: - Validate

    func validate(key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationError = "Please enter a license key."
            return
        }

        isValidating = true
        validationError = nil

        do {
            try await performValidation(key: trimmed)
        } catch let error as LicenseValidationError {
            validationError = error.errorDescription
            isLicensed = false
        } catch {
            validationError = error.localizedDescription
            isLicensed = false
        }

        isValidating = false
    }

    // MARK: - Deactivate

    func deactivate() {
        do {
            try LicenseKeychainHelper.delete()
        } catch {
            // Best-effort removal; Keychain may already be empty
        }
        UserDefaults.standard.removeObject(forKey: DefaultsKey.licenseLastValidated)
        isLicensed = false
        licenseKey = ""
        licenseeEmail = ""
        validationError = nil
    }

    // MARK: - Private

    private func performValidation(key: String) async throws {
        var request = URLRequest(url: Self.verifyURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "product_id=\(Self.productID)&license_key=\(key)"
        request.httpBody = body.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LicenseValidationError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseValidationError.serverError("Unexpected response type")
        }

        guard (200 ... 499).contains(httpResponse.statusCode) else {
            throw LicenseValidationError.serverError("HTTP \(httpResponse.statusCode)")
        }

        let decoded: GumroadVerifyResponse
        do {
            decoded = try JSONDecoder().decode(GumroadVerifyResponse.self, from: data)
        } catch {
            throw LicenseValidationError.serverError("Could not parse response")
        }

        guard decoded.success, let purchase = decoded.purchase else {
            throw LicenseValidationError.invalidKey
        }

        if purchase.refunded {
            throw LicenseValidationError.refunded
        }

        if purchase.chargebacked {
            throw LicenseValidationError.chargebacked
        }

        // Validation succeeded — persist to Keychain
        let now = Date()
        let payload = LicenseKeychainHelper.LicensePayload(
            key: key,
            email: purchase.email,
            validatedAt: now
        )
        try LicenseKeychainHelper.save(payload)

        UserDefaults.standard.set(
            now.timeIntervalSince1970,
            forKey: DefaultsKey.licenseLastValidated
        )

        licenseKey = key
        licenseeEmail = purchase.email
        isLicensed = true
        validationError = nil
    }
}
