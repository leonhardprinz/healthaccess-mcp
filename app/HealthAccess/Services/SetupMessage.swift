import Foundation

/// The one message the user gives to any AI. It carries both ways in, and the AI picks the one it can do: an AI that
/// can run a program on the computer registers the server and reads the folder; one that cannot (ChatGPT, any phone
/// app) works from the summary at the end. The folder's name (and, for iCloud Drive, its usual Mac path) is only a hint
/// in case the server's own search comes up empty.
enum SetupMessage {
    static let docsURL = "https://healthaccessmcp.com/llms.txt"
    static let siteURL = "https://healthaccessmcp.com"
    static let privacyURL = "https://healthaccessmcp.com/privacy-policy"
    static let supportURL = "https://healthaccessmcp.com/support"
    static let command = "npx -y healthaccess-mcp"

    /// `summary` is the briefing, or nil while there is nothing to summarise yet (before the first sync).
    static func text(for folder: FolderStore?, summary: String?) -> String {
        var lines = [
            "Connect me to my Health Access data.",
            "Docs for you: \(docsURL)",
            "",
            "If you can run a program on my computer (Claude Desktop, Claude Code, Cursor and similar):",
            "Register the Health Access MCP in this app. The server runs with: \(command)",
            "It finds my Health Access folder on its own.",
        ]
        if let folder {
            var hint = "If it cannot, the folder is called \"\(folder.displayName)\""
            if let path = folder.macPathHint { hint += " and is probably at \(path)" }
            lines.append(hint + "; pass it with --dir.")
        }
        lines.append("Then list my last 5 workouts." + (summary == nil ? "" : " Ignore the summary below; the folder has everything."))
        lines.append("")
        lines.append("If you cannot (ChatGPT, an AI app on a phone, a chat in a browser):")
        if let summary {
            lines.append("Do not explain the setup. Tell me in one sentence that you work from the summary below, not a live connection, then ask me what I want to know. It is a snapshot; I can copy a new one in the Health Access app at any time.")
            lines.append("")
            lines.append("My summary:")
            lines.append(summary)
        } else {
            lines.append("Do not explain the setup. Tell me in one sentence that you cannot run it, and that this message carries my summary for you once the app has synced: Health Access, Export, Your AI, Copy.")
        }
        return lines.joined(separator: "\n")
    }
}
