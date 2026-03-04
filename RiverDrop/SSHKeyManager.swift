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
    // MARK: - Security-Scoped Bookmark Storage

    /// Returns all SSH keys that have stored security-scoped bookmarks.
    static func discoverKeys() -> [SSHKeyInfo] {
        storedBookmarks().compactMap { path, data in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                return nil
            }
            return SSHKeyInfo(path: url.path, filename: url.lastPathComponent)
        }
    }

    /// Saves a security-scoped bookmark for a user-selected SSH key URL.
    /// Call this after NSOpenPanel returns a URL.
    static func saveBookmark(for url: URL) throws {
        let bookmarkData = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var bookmarks = storedBookmarks()
        bookmarks[url.path] = bookmarkData
        UserDefaults.standard.set(bookmarks, forKey: DefaultsKey.sshKeyBookmarks)
    }

    /// Removes the stored bookmark for a given path.
    static func removeBookmark(for path: String) {
        var bookmarks = storedBookmarks()
        bookmarks.removeValue(forKey: path)
        UserDefaults.standard.set(bookmarks, forKey: DefaultsKey.sshKeyBookmarks)
    }

    /// Resolves a stored bookmark, starts security-scoped access, and returns the URL.
    /// Caller is responsible for calling `url.stopAccessingSecurityScopedResource()` when done.
    static func startAccessing(path: String) -> URL? {
        guard let bookmarkData = storedBookmarks()[path] else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        if isStale {
            try? saveBookmark(for: url)
        }

        guard url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }

    private static func storedBookmarks() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: DefaultsKey.sshKeyBookmarks) as? [String: Data] ?? [:]
    }

    // MARK: - Auth

    static func buildAuthMethod(
        keyPath: String,
        username: String,
        passphrase: String?
    ) throws -> SSHAuthenticationMethod {
        let keyString: String
        // Try reading via security-scoped bookmark first, fall back to direct read
        if let scopedURL = startAccessing(path: keyPath) {
            defer { scopedURL.stopAccessingSecurityScopedResource() }
            do {
                keyString = try String(contentsOf: scopedURL, encoding: .utf8)
            } catch {
                throw SSHKeyError.keyReadFailed(path: keyPath, underlying: error)
            }
        } else {
            do {
                keyString = try String(contentsOfFile: keyPath, encoding: .utf8)
            } catch {
                throw SSHKeyError.keyReadFailed(path: keyPath, underlying: error)
            }
        }

        let passphraseData = passphrase.flatMap { $0.isEmpty ? nil : $0.data(using: .utf8) }

        let keyType: SSHKeyType
        do {
            keyType = try SSHKeyDetection.detectPrivateKeyType(from: keyString)
        } catch {
            throw SSHKeyError.parseFailure(path: keyPath, underlying: error)
        }

        do {
            if keyType == .ed25519 {
                let pk = try Curve25519.Signing.PrivateKey(sshEd25519: keyString, decryptionKey: passphraseData)
                return .ed25519(username: username, privateKey: pk)
            } else if keyType == .rsa {
                let pk = try Insecure.RSA.PrivateKey(sshRsa: keyString, decryptionKey: passphraseData)
                return .rsa(username: username, privateKey: pk)
            } else if keyType == .ecdsaP256 {
                let scalar = try Self.parseECDSAPrivateScalar(from: keyString)
                return .p256(username: username, privateKey: try P256.Signing.PrivateKey(rawRepresentation: scalar))
            } else if keyType == .ecdsaP384 {
                let scalar = try Self.parseECDSAPrivateScalar(from: keyString)
                return .p384(username: username, privateKey: try P384.Signing.PrivateKey(rawRepresentation: scalar))
            } else if keyType == .ecdsaP521 {
                let scalar = try Self.parseECDSAPrivateScalar(from: keyString)
                return .p521(username: username, privateKey: try P521.Signing.PrivateKey(rawRepresentation: scalar))
            } else {
                throw SSHKeyError.parseFailure(
                    path: keyPath,
                    underlying: ECDSAParseError.invalidFormat("unsupported key type: \(keyType.description)")
                )
            }
        } catch let error as SSHKeyError {
            throw error
        } catch {
            throw SSHKeyError.parseFailure(path: keyPath, underlying: error)
        }
    }

    // MARK: - ECDSA OpenSSH Parser

    /// Extracts the raw private scalar from an unencrypted OpenSSH ECDSA key.
    /// Citadel 0.12 lacks SSH-format ECDSA parsers, so we parse the binary envelope directly.
    private static func parseECDSAPrivateScalar(from keyString: String) throws -> Data {
        var stripped = keyString.replacingOccurrences(of: "\n", with: "")

        guard
            stripped.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"),
            stripped.hasSuffix("-----END OPENSSH PRIVATE KEY-----")
        else {
            throw ECDSAParseError.invalidFormat("missing OpenSSH boundaries")
        }

        stripped.removeFirst("-----BEGIN OPENSSH PRIVATE KEY-----".utf8.count)
        stripped.removeLast("-----END OPENSSH PRIVATE KEY-----".utf8.count)

        guard let data = Data(base64Encoded: stripped) else {
            throw ECDSAParseError.invalidFormat("invalid base64")
        }

        var offset = 0
        let magic: [UInt8] = Array("openssh-key-v1".utf8) + [0]
        guard data.count >= magic.count,
              Array(data[0 ..< magic.count]) == magic
        else {
            throw ECDSAParseError.invalidFormat("invalid magic")
        }
        offset = magic.count

        guard let cipher = readString(from: data, at: &offset) else {
            throw ECDSAParseError.invalidFormat("missing cipher")
        }
        guard cipher == "none" else {
            throw ECDSAParseError.encryptedNotSupported
        }

        // Skip KDF name + KDF options
        guard skipBlob(in: data, at: &offset),
              skipBlob(in: data, at: &offset)
        else {
            throw ECDSAParseError.invalidFormat("missing KDF fields")
        }

        guard let numKeys = readUInt32(from: data, at: &offset), numKeys == 1 else {
            throw ECDSAParseError.invalidFormat("expected 1 key")
        }

        // Skip public key blob
        guard skipBlob(in: data, at: &offset) else {
            throw ECDSAParseError.invalidFormat("missing public key blob")
        }

        // Private section
        guard let privSection = readBlob(from: data, at: &offset) else {
            throw ECDSAParseError.invalidFormat("missing private section")
        }

        var p = 0

        guard let c0 = readUInt32(from: privSection, at: &p),
              let c1 = readUInt32(from: privSection, at: &p),
              c0 == c1
        else {
            throw ECDSAParseError.invalidFormat("checksum mismatch")
        }

        // key type (e.g. "ecdsa-sha2-nistp256"), curve id (e.g. "nistp256"), public point
        guard skipBlob(in: privSection, at: &p),
              skipBlob(in: privSection, at: &p),
              skipBlob(in: privSection, at: &p)
        else {
            throw ECDSAParseError.invalidFormat("incomplete private key fields")
        }

        guard let scalar = readBlob(from: privSection, at: &p) else {
            throw ECDSAParseError.invalidFormat("missing private scalar")
        }

        // SSH encodes the scalar as a bignum — strip leading zero-padding byte
        if scalar.first == 0, scalar.count > 1 {
            return Data(scalar.dropFirst())
        }
        return scalar
    }

    // MARK: - Binary Helpers

    private static func readUInt32(from data: Data, at offset: inout Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let value = UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
        offset += 4
        return value
    }

    private static func readBlob(from data: Data, at offset: inout Int) -> Data? {
        guard let length = readUInt32(from: data, at: &offset) else { return nil }
        let len = Int(length)
        guard offset + len <= data.count else { return nil }
        let result = Data(data[offset ..< offset + len])
        offset += len
        return result
    }

    private static func readString(from data: Data, at offset: inout Int) -> String? {
        guard let blob = readBlob(from: data, at: &offset) else { return nil }
        return String(data: blob, encoding: .utf8)
    }

    @discardableResult
    private static func skipBlob(in data: Data, at offset: inout Int) -> Bool {
        guard let length = readUInt32(from: data, at: &offset) else { return false }
        let len = Int(length)
        guard offset + len <= data.count else { return false }
        offset += len
        return true
    }
}

private enum ECDSAParseError: LocalizedError {
    case invalidFormat(String)
    case encryptedNotSupported

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let detail):
            return "ECDSA key parse error: \(detail)"
        case .encryptedNotSupported:
            return "Passphrase-protected ECDSA keys are not yet supported. Remove the passphrase with: ssh-keygen -p -f <keyfile>"
        }
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
            return "Could not parse SSH key at \(path): \(underlying.localizedDescription). Supported types: Ed25519, ECDSA, RSA"
        }
    }
}
