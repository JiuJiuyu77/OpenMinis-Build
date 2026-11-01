import SwiftUI

/// Settings and diagnostics for the MT Memory Toolkit MCP companion.
struct MTBridgeSettingsView: View {
    @AppStorage(MTBridgeClient.enabledKey) private var enabled = true
    @State private var endpoint = MTBridgeClient.endpoint
    @State private var statusText = AppLocalized("Not tested")
    @State private var connected = false
    @State private var tools: [MTBridgeTool] = []
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Toggle(AppLocalized("Enable MT bridge"), isOn: $enabled)
                    .onChange(of: enabled) { _, value in
                        MTBridgeClient.setEnabled(value)
                    }
                TextField("http://127.0.0.1:27018/mcp", text: $endpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button(AppLocalized("Save endpoint")) {
                    MTBridgeClient.setEndpoint(endpoint)
                    statusText = AppLocalized("Endpoint saved")
                }
            } header: {
                Text(AppLocalized("MT Memory Toolkit"))
            } footer: {
                Text(AppLocalized("MT-Agent provides reasoning and project work; MT Memory Toolkit provides the live process, memory, register and breakpoint context. Use an address reachable from this device, normally port 27018."))
            }

            Section {
                Button {
                    testConnection()
                } label: {
                    HStack {
                        if busy { ProgressView().controlSize(.small) }
                        Label(AppLocalized("Test connection and list tools"), systemImage: "bolt.horizontal.circle")
                    }
                }
                .disabled(!enabled || busy)
                Label(statusText, systemImage: connected ? "checkmark.circle.fill" : "questionmark.circle")
                    .foregroundStyle(connected ? .green : .secondary)
            } header: {
                Text(AppLocalized("Connection"))
            }

            if !tools.isEmpty {
                Section(AppLocalized("Available MT tools")) {
                    ForEach(tools, id: \.name) { tool in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tool.name).font(.headline)
                            if let description = tool.description, !description.isEmpty {
                                Text(description).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(AppLocalized("MT Bridge"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { endpoint = MTBridgeClient.endpoint }
    }

    private func testConnection() {
        MTBridgeClient.setEndpoint(endpoint)
        busy = true
        Task { @MainActor in
            let result = await MTBridgeClient.shared.status()
            connected = result.connected
            tools = result.tools
            statusText = result.message
            busy = false
        }
    }
}
