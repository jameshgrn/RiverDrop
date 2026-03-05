import Foundation

struct ServerEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var label: String
    var host: String
    var user: String
    var port: Int
    var identityFile: String?
    var proxyJump: String?
    var source: Source

    enum Source: String, Codable {
        case sshConfig
        case manual
    }

    init(
        id: UUID = UUID(),
        label: String,
        host: String,
        user: String,
        port: Int = 22,
        identityFile: String? = nil,
        proxyJump: String? = nil,
        source: Source
    ) {
        self.id = id
        self.label = label
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.source = source
    }
}
