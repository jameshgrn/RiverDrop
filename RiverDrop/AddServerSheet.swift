import SwiftUI

struct AddServerSheet: View {
    let onSave: (ServerEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var host = ""
    @State private var user = ""
    @State private var port = 22
    @State private var identityFile = ""
    @State private var proxyJump = ""

    private var canSave: Bool {
        !label.isEmpty && !host.isEmpty && !user.isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Server")
                .font(.headline)

            Form {
                TextField("Label", text: $label)
                TextField("Host", text: $host)
                TextField("Username", text: $user)
                Stepper("Port: \(port)", value: $port, in: 1...65535)
                TextField("Identity File (optional)", text: $identityFile)
                TextField("ProxyJump (optional)", text: $proxyJump)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    let entry = ServerEntry(
                        label: label,
                        host: host,
                        user: user,
                        port: port,
                        identityFile: identityFile.isEmpty ? nil : identityFile,
                        proxyJump: proxyJump.isEmpty ? nil : proxyJump,
                        source: .manual
                    )
                    onSave(entry)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding()
        .frame(width: 350)
    }
}
