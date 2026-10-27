import SwiftUI

/// The prompts of one group as a list: title and one sentence each. Tapping one opens it on its own page.
struct PromptsView: View {
    let group: Prompt.Group

    var body: some View {
        List {
            Section {
                ForEach(Prompts.in(group)) { prompt in
                    NavigationLink(value: HomeRoute.prompt(prompt)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(prompt.title)
                            Text(prompt.about).font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } footer: {
                Text(group == .export
                     ? "Each one makes your AI ask first, then read what your Watch recorded, then explain it. Suggestions only. What you share with an AI, and what it tells you, is between you and that AI."
                     : "Each one makes your AI ask first, including when you will train, then write sessions that show up in the Import tab. Any sport the Watch can run. Suggestions only.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(group == .export ? "Export prompts" : "Import prompts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One prompt, verbatim from docs/prompts.md, with Copy.
struct PromptDetailView: View {
    let prompt: Prompt
    @State private var copiedAt: Date?

    var body: some View {
        List {
            Section {
                Text(prompt.about).font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                Text(prompt.body)
                    .font(.footnote)
                    .textSelection(.enabled)
            } footer: {
                Text(prompt.args == "none" ? "MCP prompt \(prompt.id)" : "MCP prompt \(prompt.id) · args: \(prompt.args)")
                    .font(.caption.monospaced())
            }
            Section {
                Button {
                    UIPasteboard.general.string = prompt.body
                    copiedAt = Date()
                } label: {
                    Label(copiedAt.map { "Copied \(Format.clock($0)). Paste it to your AI." } ?? "Copy",
                          systemImage: copiedAt == nil ? "doc.on.doc" : "checkmark")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(prompt.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
