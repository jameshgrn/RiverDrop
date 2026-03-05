import Foundation

// MARK: - Keyboard-Interactive Authentication
//
// SSH keyboard-interactive authentication (RFC 4256) is NOT supported by
// the underlying transport libraries used by RiverDrop:
//
//   - NIOSSH (swift-nio-ssh): NIOSSHAvailableUserAuthenticationMethods only
//     defines .publicKey, .password, and .hostBased. The protocol-level
//     "keyboard-interactive" method is not parsed from server auth-failure
//     messages and has no corresponding NIOSSHUserAuthenticationOffer variant.
//
//   - Citadel: SSHAuthenticationMethod wraps NIOSSHUserAuthenticationOffer
//     and does not add keyboard-interactive on top of what NIOSSH provides.
//
// Keyboard-interactive differs from password auth in that the server sends
// one or more challenge prompts (e.g. "Password:", "Verification code:")
// and the client responds to each. This is the mechanism used by most
// 2FA/MFA SSH configurations (TOTP, Duo, etc.).
//
// To add support, NIOSSH would need:
//   1. A new NIOSSHAvailableUserAuthenticationMethods member for keyboard-interactive
//   2. A new NIOSSHUserAuthenticationOffer.Offer case carrying prompt/response pairs
//   3. Wire-level handling of SSH_MSG_USERAUTH_INFO_REQUEST / RESPONSE
//
// Tracked upstream:
//   https://github.com/apple/swift-nio-ssh/issues (no open issue as of 2026-03)
//
// Until NIOSSH adds this, RiverDrop cannot implement keyboard-interactive auth.
// Servers that require it should be accessed via ProxyJump through a bastion
// that accepts password or public-key auth, or by configuring the server to
// fall back to password authentication.

enum KeyboardInteractiveAuth {
    /// Returns false. Keyboard-interactive is not supported by the current SSH transport.
    static var isSupported: Bool { false }

    /// Human-readable explanation of why keyboard-interactive is unavailable.
    static let unsupportedReason = """
        Keyboard-interactive authentication (2FA/MFA) requires protocol support \
        that the underlying SSH library (NIOSSH) does not yet provide. \
        Use password or SSH key authentication instead.
        """
}
