import Testing
@testable import RiverDrop

@Suite("SSHConfigParser.extractHostAliases")
struct ExtractHostAliasesTests {

    @Test("parses simple host aliases")
    func simpleAliases() {
        let config = """
        Host myserver
            HostName 10.0.0.1
            User admin

        Host devbox
            HostName dev.example.com
        """
        let aliases = SSHConfigParser.extractHostAliases(from: config)
        #expect(aliases == ["myserver", "devbox"])
    }

    @Test("skips wildcard patterns with *")
    func skipsAsterisk() {
        let config = """
        Host *
            ServerAliveInterval 60

        Host myserver
            HostName 10.0.0.1
        """
        let aliases = SSHConfigParser.extractHostAliases(from: config)
        #expect(aliases == ["myserver"])
    }

    @Test("skips wildcard patterns with ?")
    func skipsQuestionMark() {
        let config = """
        Host web?
            HostName web.example.com

        Host realhost
            HostName real.example.com
        """
        let aliases = SSHConfigParser.extractHostAliases(from: config)
        #expect(aliases == ["realhost"])
    }

    @Test("skips wildcard patterns with !")
    func skipsExclamation() {
        let config = """
        Host !badhost
            HostName bad.example.com

        Host goodhost
            HostName good.example.com
        """
        let aliases = SSHConfigParser.extractHostAliases(from: config)
        #expect(aliases == ["goodhost"])
    }

    @Test("skips comment lines")
    func skipsComments() {
        let config = """
        # Host commented_out
        Host actual
            HostName 10.0.0.1
        """
        let aliases = SSHConfigParser.extractHostAliases(from: config)
        #expect(aliases == ["actual"])
    }

    @Test("handles multiple aliases per Host line")
    func multipleAliasesPerLine() {
        let config = """
        Host alpha beta gamma
            HostName multi.example.com
        """
        let aliases = SSHConfigParser.extractHostAliases(from: config)
        #expect(aliases == ["alpha", "beta", "gamma"])
    }

    @Test("Host directive is case insensitive")
    func caseInsensitiveDirective() {
        let config = """
        host lowercase
            HostName lc.example.com
        HOST uppercase
            HostName uc.example.com
        Host Mixed
            HostName mx.example.com
        """
        let aliases = SSHConfigParser.extractHostAliases(from: config)
        #expect(aliases == ["lowercase", "uppercase", "Mixed"])
    }

    @Test("empty config returns empty array")
    func emptyConfig() {
        let aliases = SSHConfigParser.extractHostAliases(from: "")
        #expect(aliases.isEmpty)
    }

    @Test("extra whitespace around alias is trimmed")
    func whitespaceHandling() {
        let config = """
        Host   spacey
            HostName sp.example.com
        """
        let aliases = SSHConfigParser.extractHostAliases(from: config)
        #expect(aliases == ["spacey"])
    }
}

@Suite("SSHConfigParser.buildEntry")
struct BuildEntryTests {

    @Test("parses hostname, user, port from ssh -G output")
    func basicFields() {
        let output = """
        hostname example.com
        user deploy
        port 2222
        """
        let entry = SSHConfigParser.buildEntry(alias: "myalias", from: output)
        #expect(entry.label == "myalias")
        #expect(entry.host == "example.com")
        #expect(entry.user == "deploy")
        #expect(entry.port == 2222)
        #expect(entry.source == .sshConfig)
    }

    @Test("defaults to alias as hostname when not specified")
    func defaultHostname() {
        let output = """
        user someone
        port 22
        """
        let entry = SSHConfigParser.buildEntry(alias: "myhost", from: output)
        #expect(entry.host == "myhost")
    }

    @Test("defaults to current user when user not specified")
    func defaultUser() {
        let output = """
        hostname remote.example.com
        """
        let entry = SSHConfigParser.buildEntry(alias: "test", from: output)
        #expect(entry.user == NSUserName())
    }

    @Test("defaults to port 22 when not specified")
    func defaultPort() {
        let output = """
        hostname remote.example.com
        """
        let entry = SSHConfigParser.buildEntry(alias: "test", from: output)
        #expect(entry.port == 22)
    }

    @Test("invalid port value keeps default")
    func invalidPort() {
        let output = """
        port notanumber
        """
        let entry = SSHConfigParser.buildEntry(alias: "test", from: output)
        #expect(entry.port == 22)
    }

    @Test("identityFile is nil when file does not exist on disk")
    func identityFileNonexistent() {
        let output = """
        identityfile /nonexistent/path/id_rsa
        """
        let entry = SSHConfigParser.buildEntry(alias: "test", from: output)
        #expect(entry.identityFile == nil)
    }

    @Test("proxyjump is parsed")
    func proxyJump() {
        let output = """
        hostname target.example.com
        proxyjump bastion.example.com
        """
        let entry = SSHConfigParser.buildEntry(alias: "test", from: output)
        #expect(entry.proxyJump == "bastion.example.com")
    }

    @Test("proxyjump 'none' is treated as nil")
    func proxyJumpNone() {
        let output = """
        proxyjump none
        """
        let entry = SSHConfigParser.buildEntry(alias: "test", from: output)
        #expect(entry.proxyJump == nil)
    }

    @Test("proxyjump 'None' (case insensitive) is treated as nil")
    func proxyJumpNoneCaseInsensitive() {
        let output = """
        proxyjump None
        """
        let entry = SSHConfigParser.buildEntry(alias: "test", from: output)
        #expect(entry.proxyJump == nil)
    }

    @Test("keys are case insensitive")
    func caseInsensitiveKeys() {
        let output = """
        HostName UPPER.example.com
        User ADMIN
        Port 3333
        """
        let entry = SSHConfigParser.buildEntry(alias: "test", from: output)
        #expect(entry.host == "UPPER.example.com")
        #expect(entry.user == "ADMIN")
        #expect(entry.port == 3333)
    }

    @Test("empty output uses all defaults")
    func emptyOutput() {
        let entry = SSHConfigParser.buildEntry(alias: "fallback", from: "")
        #expect(entry.label == "fallback")
        #expect(entry.host == "fallback")
        #expect(entry.user == NSUserName())
        #expect(entry.port == 22)
        #expect(entry.identityFile == nil)
        #expect(entry.proxyJump == nil)
        #expect(entry.source == .sshConfig)
    }

    @Test("lines without value are skipped")
    func linesWithoutValue() {
        let output = """
        hostname
        user deploy
        """
        let entry = SSHConfigParser.buildEntry(alias: "test", from: output)
        // "hostname" alone has no space-separated value, so it's skipped
        #expect(entry.host == "test")
        #expect(entry.user == "deploy")
    }
}
