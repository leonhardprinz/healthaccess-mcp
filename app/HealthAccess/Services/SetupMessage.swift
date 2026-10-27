import Foundation

/// The one paragraph the user pastes to their AI. The command is the same for everyone; the folder's name (and, for
/// iCloud Drive, its usual Mac path) is only a hint in case the server's own search comes up empty.
enum SetupMessage {
    static let docsURL = "https://healthaccessmcp.com/llms.txt"
    static let siteURL = "https://healthaccessmcp.com"
    static let privacyURL = "https://healthaccessmcp.com/privacy-policy"
    static let supportURL = "https://healthaccessmcp.com/support"
    static let command = "npx -y healthaccess-mcp"

    static func text(for folder: FolderStore?) -> String {
        var lines = [
            "Set up the Health Access MCP for me.",
            "Docs for you: \(docsURL)",
            "The server runs with: \(command)",
            "It finds my Health Access folder on its own.",
        ]
        if let folder {
            var hint = "If it cannot, the folder is called \"\(folder.displayName)\""
            if let path = folder.macPathHint { hint += " and is probably at \(path)" }
            lines.append(hint + "; pass it with --dir.")
        }
        lines.append("Register it in this app, then list my last 5 workouts.")
        return lines.joined(separator: "\n")
    }
}
