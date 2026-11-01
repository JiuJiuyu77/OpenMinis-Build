import Foundation

/// A small Streamable-HTTP MCP client for the MT Memory Toolkit.
///
/// MT is deliberately kept outside MCPStore: MCPStore owns user-configured
/// servers, while this bridge is a device-local companion connection. The
/// bridge never discovers or calls a tool automatically; the agent must make
/// an explicit `mt_tool` call.
struct MTBridgeTool: Hashable, Sendable {
    let name: String
    let description: String?
}

enum MTBridgeError: LocalizedError, Sendable {
    case disabled
    case invalidEndpoint
    case unavailable(String)
    case protocolError(String)
    case remoteError(String)
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .disabled: return "MT bridge is disabled. Enable it in Settings → MT Bridge."
        case .invalidEndpoint: return "MT bridge endpoint is invalid. Use http://127.0.0.1:27018/mcp or the MT device address."
        case .unavailable(let reason): return "MT bridge unavailable: \(reason)"
        case .protocolError(let reason): return "MT MCP protocol error: \(reason)"
        case .remoteError(let reason): return "MT tool error: \(reason)"
        case .invalidArguments(let reason): return "Invalid MT tool arguments: \(reason)"
        }
    }
}

struct MTBridgeStatus: Sendable {
    let endpoint: String
    let connected: Bool
    let tools: [MTBridgeTool]
    let message: String
}

actor MTBridgeClient {
    static let shared = MTBridgeClient()

    nonisolated static let endpointKey = "mt.bridge.endpoint"
    nonisolated static let enabledKey = "mt.bridge.enabled"
    nonisolated static let defaultEndpoint = "http://127.0.0.1:27018/mcp"

    private var requestID: Int = 0
    private var sessionID: String?
    private var initializedEndpoint: String?
    private var cachedTools: [MTBridgeTool] = []

    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    nonisolated static var endpoint: String {
        let value = UserDefaults.standard.string(forKey: endpointKey) ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultEndpoint : value
    }

    nonisolated static func setEndpoint(_ value: String) {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: endpointKey)
    }

    nonisolated static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: enabledKey)
    }

    func status() async -> MTBridgeStatus {
        guard Self.isEnabled else {
            return MTBridgeStatus(endpoint: Self.endpoint, connected: false, tools: [], message: MTBridgeError.disabled.localizedDescription)
        }
        do {
            let tools = try await listTools()
            return MTBridgeStatus(endpoint: Self.endpoint, connected: true, tools: tools, message: "Connected to MT MCP (\(tools.count) tools)")
        } catch {
            return MTBridgeStatus(endpoint: Self.endpoint, connected: false, tools: [], message: error.localizedDescription)
        }
    }

    func listTools() async throws -> [MTBridgeTool] {
        try await ensureInitialized()
        let result = try await request(method: "tools/list", params: [:])
        let tools = (result["tools"] as? [[String: Any]] ?? []).compactMap { raw -> MTBridgeTool? in
            guard let name = raw["name"] as? String else { return nil }
            return MTBridgeTool(name: name, description: raw["description"] as? String)
        }
        cachedTools = tools
        return tools
    }

    func call(tool: String, arguments: [String: Any]) async throws -> String {
        guard !tool.isEmpty else { throw MTBridgeError.invalidArguments("missing tool name") }
        try await ensureInitialized()
        let result = try await request(method: "tools/call", params: [
            "name": tool,
            "arguments": arguments
        ])
        if let isError = result["isError"] as? Bool, isError {
            throw MTBridgeError.remoteError(Self.render(result["content"] ?? result))
        }
        return Self.render(result["content"] ?? result)
    }

    func execute(action: String, tool: String?, argumentsJSON: String?) async -> (text: String, ok: Bool) {
        do {
            switch action {
            case "status":
                let s = await status()
                return (Self.render(["endpoint": s.endpoint, "connected": s.connected, "message": s.message,
                                     "tools": s.tools.map { ["name": $0.name, "description": $0.description ?? ""] }]), s.connected)
            case "list_tools":
                let tools = try await listTools()
                return (Self.render(tools.map { ["name": $0.name, "description": $0.description ?? ""] }), true)
            case "call":
                guard let tool, !tool.isEmpty else { throw MTBridgeError.invalidArguments("call requires server_tool") }
                let data = (argumentsJSON ?? "{}").data(using: .utf8) ?? Data("{}".utf8)
                guard let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw MTBridgeError.invalidArguments("arguments must be a JSON object")
                }
                return (try await call(tool: tool, arguments: arguments), true)
            default:
                throw MTBridgeError.invalidArguments("action must be status, list_tools, or call")
            }
        } catch {
            return (error.localizedDescription, false)
        }
    }

    private func ensureInitialized() async throws {
        guard Self.isEnabled else { throw MTBridgeError.disabled }
        let endpoint = Self.endpoint
        guard let url = URL(string: endpoint), let scheme = url.scheme,
              ["http", "https"].contains(scheme), url.host != nil else {
            throw MTBridgeError.invalidEndpoint
        }
        guard initializedEndpoint != endpoint else { return }
        requestID += 1
        let result = try await rawRequest(id: requestID, method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "Minis-MT", "version": "1.0"]
        ])
        if result["protocolVersion"] == nil && result["serverInfo"] == nil {
            throw MTBridgeError.protocolError("initialize returned no server information")
        }
        initializedEndpoint = endpoint
        _ = try? await rawNotification(method: "notifications/initialized", params: [:])
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        requestID += 1
        return try await rawRequest(id: requestID, method: method, params: params)
    }

    private func rawNotification(method: String, params: [String: Any]) async throws {
        _ = try await send(method: method, params: params, id: nil)
    }

    private func rawRequest(id: Int, method: String, params: [String: Any]) async throws -> [String: Any] {
        try await send(method: method, params: params, id: id)
    }

    private func send(method: String, params: [String: Any], id: Int?) async throws -> [String: Any] {
        guard let url = URL(string: Self.endpoint) else { throw MTBridgeError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { body["id"] = id }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MTBridgeError.unavailable("invalid HTTP response") }
            guard (200..<300).contains(http.statusCode) else { throw MTBridgeError.unavailable("HTTP \(http.statusCode)") }
            if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }
            let payload = try Self.decodeResponse(data)
            if let error = payload["error"] { throw MTBridgeError.remoteError(Self.render(error)) }
            return (payload["result"] as? [String: Any]) ?? payload
        } catch let error as MTBridgeError { throw error }
          catch { throw MTBridgeError.unavailable(error.localizedDescription) }
    }

    private static func decodeResponse(_ data: Data) throws -> [String: Any] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("data:") else { continue }
            let json = String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] { return object }
        }
        throw MTBridgeError.protocolError("response was not JSON or SSE")
    }

    private static func render(_ value: Any) -> String {
        if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { return text }
        return String(describing: value)
    }
}
