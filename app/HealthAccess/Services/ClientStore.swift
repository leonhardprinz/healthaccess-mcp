import Foundation

/// The MCP writes a handshake file per client into `mcp/clients/<id>.json` (schema `healthaccess.client.v1`). The app
/// only reads them: an AI counts as connected when its `last_seen` is within 7 days.
struct ClientInfo: Identifiable, Sendable, Hashable {
    let id: String          // file base name
    let name: String        // client.name, e.g. "Claude Code"
    let version: String?
    let machine: String?
    let mcpVersion: String?
    let firstSeen: Date?
    let lastSeen: Date?
    let lastTool: String?
    let calls: Int?

    static let connectedWindow: TimeInterval = 7 * 86_400

    func isConnected(now: Date = Date()) -> Bool {
        guard let lastSeen else { return false }
        return now.timeIntervalSince(lastSeen) <= Self.connectedWindow
    }

    /// "On Alex's Mac · last seen 2 min ago", for a row that already names the client.
    var whereAndWhen: String {
        var parts: [String] = []
        if let machine, !machine.isEmpty { parts.append("On \(machine)") }
        if let lastSeen { parts.append("last seen \(Format.ago(lastSeen))") }
        return parts.joined(separator: " · ")
    }

    /// "Claude Code on Alex's Mac · last seen 2 min ago"
    var line: String {
        var text = name
        if let machine, !machine.isEmpty { text += " on \(machine)" }
        if let lastSeen { text += " · last seen \(Format.ago(lastSeen))" }
        return text
    }
}

enum ClientStore {
    static let directory = "mcp/clients"

    /// Newest first. Unreadable files are skipped.
    static func scan(folder: FolderStore) -> [ClientInfo] {
        guard let names = try? folder.list(directory) else { return [] }
        var out: [ClientInfo] = []
        for name in names {
            guard let data = try? folder.read("\(directory)/\(name)"), let object = try? JSONBuilder.object(data) else { continue }
            let client = object["client"] as? JSONObject
            let clientName = (client?["name"] as? String) ?? (object["name"] as? String) ?? "an AI"
            out.append(ClientInfo(
                id: String(name.dropLast(".json".count)),
                name: clientName,
                version: client?["version"] as? String,
                machine: object["machine"] as? String,
                mcpVersion: object["mcp_version"] as? String,
                firstSeen: (object["first_seen"] as? String).flatMap(HealthAccessJSON.date),
                lastSeen: (object["last_seen"] as? String).flatMap(HealthAccessJSON.date),
                lastTool: object["last_tool"] as? String,
                calls: (object["calls"] as? NSNumber)?.intValue))
        }
        return out.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }
}
