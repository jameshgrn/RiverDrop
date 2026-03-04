import Citadel
import Crypto
import Foundation
import NIOSSH

enum SSHAuthConfig: Sendable {
    case password(String)
    case sshKey(keyPath: String, passphrase: String?)
}

struct SSHKeyInfo: Sendable, Identifiable, Hashable {
    let path: String
    let filename: String

    var id: String { path }
}

enum SSHKeyManager {
    private static let knownKeyFilenames = [
        "id_ed25519",
        "id_rsa",
    ]

    static func discoverKeys() -> [SSHKeyInfo] {
        let sshDir = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
        return knownKeyFilenames.compactMap { filename in
            let path = (sshDir as NSString).appendingPathComponent(filename)
            guard FileManager.default.isReadableFile(atPath: path) else { return nil }
            return SSHKeyInfo(path: path, filename: filename)
        }
    }

    static func buildAuthMethod(
        keyPath: String,
        username: String,
        passphrase: String?
    ) throws -> SSHAuthenticationMethod {
        let keyString: String
        do {
            keyString = try String(contentsOfFile: keyPath, encoding: .utf8)
        } catch {
            throw SSHKeyError.keyReadFailed(path: keyPath, underlying: error)
        }

        let passphraseData = passphrase.flatMap { $0.isEmpty ? nil : $0.data(using: .utf8) }
        var firstError: Error?

        do {
            let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: keyString, decryptionKey: passphraseData)
            return .ed25519(username: username, privateKey: privateKey)
        } catch {
            firstError = error
        }

        do {
            let privateKey = try Insecure.RSA.PrivateKey(sshRsa: keyString, decryptionKey: passphraseData)
            return .rsa(username: username, privateKey: privateKey)
        } catch {
            // Both parsers failed
        }

        throw SSHKeyError.parseFailure(path: keyPath, underlying: firstError!)
    }
}

enum SSHKeyError: LocalizedError {
    case keyReadFailed(path: String, underlying: Error)
    case parseFailure(path: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .keyReadFailed(path, underlying):
            return "Could not read SSH key at \(path): \(underlying.localizedDescription)"
        case let .parseFailure(path, underlying):
            return "Could not parse SSH key at \(path): \(underlying.localizedDescription). Supported types: Ed25519, RSA"
        }
    }
}
