import Foundation

enum SSHConfigParser {

    /// Parse ~/.ssh/config and resolve each host alias via `ssh -G`.
    /// Returns empty array if ~/.ssh/config doesn't exist.
    static func parse() -> [ServerEntry] {
        let configPath = NSHomeDirectory() + "/.ssh/config"
        guard FileManager.default.fileExists(atPath: configPath),
              let contents = try? String(contentsOfFile: configPath, encoding: .utf8)
        else {
            return []
        }

        let aliases = extractHostAliases(from: contents)
        return aliases.compactMap { resolve(alias: $0) }
    }

    // MARK: - Private

    /// Extract Host directive names, skipping wildcards and `Host *`.
    static func extractHostAliases(from contents: String) -> [String] {
        var aliases: [String] = []
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("host "),
                  !trimmed.hasPrefix("#")
            else { continue }

            let value = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            // Skip wildcard patterns
            if value.contains("*") || value.contains("?") || value.contains("!") {
                continue
            }
            // A single Host line can list multiple aliases separated by spaces
            for alias in value.components(separatedBy: .whitespaces) where !alias.isEmpty {
                aliases.append(alias)
            }
        }
        return aliases
    }

    /// Resolve a host alias via `ssh -G <alias>` and build a ServerEntry.
    private static func resolve(alias: String) -> ServerEntry? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", alias]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        return buildEntry(alias: alias, from: output)
    }

    static func buildEntry(alias: String, from output: String) -> ServerEntry {
        var hostname = alias
        var user = NSUserName()
        var port = 22
        var identityFile: String?
        var proxyJump: String?

        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = String(parts[1])

            switch key {
            case "hostname":
                hostname = value
            case "user":
                user = value
            case "port":
                if let p = Int(value) { port = p }
            case "identityfile":
                let expanded = (value as NSString).expandingTildeInPath
                // Only keep if the file actually exists (skip ssh defaults that aren't present)
                if FileManager.default.fileExists(atPath: expanded) {
                    identityFile = expanded
                }
            case "proxyjump":
                if value.lowercased() != "none" {
                    proxyJump = value
                }
            default:
                break
            }
        }

        return ServerEntry(
            label: alias,
            host: hostname,
            user: user,
            port: port,
            identityFile: identityFile,
            proxyJump: proxyJump,
            source: .sshConfig
        )
    }
}
