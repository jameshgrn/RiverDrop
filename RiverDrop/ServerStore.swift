import Foundation
import Observation

@MainActor
@Observable
final class ServerStore {

    var servers: [ServerEntry] = []

    private var manualServers: [ServerEntry] = []
    private var configServers: [ServerEntry] = []

    @ObservationIgnored private nonisolated(unsafe) var fileWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private nonisolated(unsafe) var debounceWork: DispatchWorkItem?

    init() {
        loadManualServers()
        refresh()
        startWatching()
    }

    deinit {
        debounceWork?.cancel()
        fileWatcher?.cancel()
    }

    // MARK: - Public

    func refresh() {
        Task {
            configServers = await SSHConfigParser.parse()
            mergeServers()
        }
    }

    func addManual(
        label: String,
        host: String,
        user: String,
        port: Int = 22,
        identityFile: String? = nil,
        proxyJump: String? = nil
    ) {
        let entry = ServerEntry(
            label: label,
            host: host,
            user: user,
            port: port,
            identityFile: identityFile,
            proxyJump: proxyJump,
            source: .manual
        )
        manualServers.append(entry)
        persistManualServers()
        mergeServers()
    }

    func remove(id: UUID) {
        manualServers.removeAll { $0.id == id }
        persistManualServers()
        mergeServers()
    }

    // MARK: - Private

    private func mergeServers() {
        servers = configServers + manualServers
    }

    private func loadManualServers() {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.manualServers),
              let decoded = try? JSONDecoder().decode([ServerEntry].self, from: data)
        else { return }
        manualServers = decoded
    }

    private func persistManualServers() {
        guard let data = try? JSONEncoder().encode(manualServers) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.manualServers)
    }

    // MARK: - File Watching

    private func startWatching() {
        let configPath = NSHomeDirectory() + "/.ssh/config"
        let fd = open(configPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.scheduleRefresh()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileWatcher = source
    }

    private func scheduleRefresh() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        debounceWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 1.0,
            execute: work
        )
    }
}
