import SwiftUI

struct SidebarView: View {
    @Environment(ServerStore.self) var serverStore
    @Environment(SFTPService.self) var sftpService
    @Binding var selectedServerID: ServerEntry.ID?
    @State private var showAddServer = false

    private var sshConfigServers: [ServerEntry] {
        serverStore.servers.filter { $0.source == .sshConfig }
    }

    private var manualServers: [ServerEntry] {
        serverStore.servers.filter { $0.source == .manual }
    }

    var body: some View {
        List(selection: $selectedServerID) {
            Section("SSH Config") {
                if sshConfigServers.isEmpty {
                    Text("No hosts in ~/.ssh/config")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(sshConfigServers) { server in
                        serverRow(server)
                    }
                }
            }

            Section("Manual") {
                ForEach(manualServers) { server in
                    serverRow(server)
                        .contextMenu {
                            Button("Remove") {
                                serverStore.remove(id: server.id)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        .toolbar {
            ToolbarItem {
                Button {
                    showAddServer = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add server manually")
                .accessibilityLabel("Add server manually")
            }

            ToolbarItem {
                Button {
                    serverStore.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh SSH config")
                .accessibilityLabel("Refresh SSH config")
            }
        }
        .sheet(isPresented: $showAddServer) {
            AddServerSheet { entry in
                serverStore.addManual(
                    label: entry.label,
                    host: entry.host,
                    user: entry.user,
                    port: entry.port,
                    identityFile: entry.identityFile,
                    proxyJump: entry.proxyJump
                )
            }
        }
    }

    private func serverRow(_ server: ServerEntry) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnectedTo(server) ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.label)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Text("\(server.user)@\(server.host)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if server.proxyJump != nil {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Uses ProxyJump")
            }
        }
        .tag(server.id)
        .padding(.vertical, 2)
    }

    private func isConnectedTo(_ server: ServerEntry) -> Bool {
        sftpService.isConnected
            && sftpService.connectedHost == server.host
            && sftpService.connectedUsername == server.user
    }
}
