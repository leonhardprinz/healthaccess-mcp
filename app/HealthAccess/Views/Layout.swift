import SwiftUI

/// The pieces every tab is built from, so the three tabs look and read the same: the header, the blue status tile,
/// section titles, the folder row. Headings are IBM Plex Sans Condensed, everything you read is the system font.

/// Top of every tab, always in the same place: a small brand bar, the one big title, one line on what the tab does.
/// The title is the only large element; the brand stays small so the two never compete.
struct TabHeader: View {
    let title: String
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandBar()
                .padding(.bottom, 14)
            // One line at 32 pt; on a narrow phone one line at 27 pt; with very large text it wraps. Never cut off.
            ViewThatFits(in: .horizontal) {
                titleText(32).lineLimit(1)
                titleText(27).lineLimit(1)
                titleText(32).fixedSize(horizontal: false, vertical: true)
            }
            Text(line)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .textCase(nil)
        .padding(.top, 4)
        .padding(.bottom, 20)
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
    }
}

extension TabHeader {
    fileprivate func titleText(_ size: CGFloat) -> some View {
        Text(title)
            .font(.brand(size, relativeTo: .largeTitle))
            .foregroundStyle(Color.primary)
    }
}

/// The brand, small: the mark on its tile and "Health Access MCP" in Plex, one line, about body size.
struct BrandBar: View {
    var body: some View {
        HStack(spacing: 8) {
            MarkTile(size: 24)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Health Access")
                    .font(.brand(17, bold: false, relativeTo: .body))
                    .foregroundStyle(Color.primary)
                Text("MCP")
                    .font(.brand(11, bold: false, relativeTo: .caption))
                    .tracking(0.8)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Health Access MCP")
    }
}

/// A section heading in the brand face.
struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.brand(18, bold: false, relativeTo: .headline))
            .foregroundStyle(Color.primary)
            .textCase(nil)
    }
}

/// The state a status tile shows. Each has its own symbol, so you can read the tile without reading it.
enum TileState {
    case done, working, waiting, failed, needs

    /// Orange ground only when you are needed; blue otherwise.
    var isWarm: Bool { self == .needs }
}

/// The status tile at the top of Export and Plans: one symbol, one sentence, one detail line, and a button only when
/// there is something to do. Done shows a green check and no button.
struct StatusTile: View {
    let state: TileState
    let title: String
    let detail: String
    var buttonTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            symbol
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.brand(22, relativeTo: .title3))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                if let buttonTitle {
                    Button(buttonTitle, action: action)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(state.isWarm ? Color.signal : Color.markBlue)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(.white))
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .listRowBackground(state.isWarm ? Color.signal : Color.markBlue)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var symbol: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.green)
                .font(.system(size: 30))
        case .working:
            MarkView(animating: true, color: .white)
        case .waiting:
            Image(systemName: "lock.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.markBlue, .white)
                .font(.system(size: 30))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.markBlue, .white)
                .font(.system(size: 30))
        case .needs:
            Image(systemName: "exclamationmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.signal, .white)
                .font(.system(size: 30))
        }
    }
}

/// The folder both tabs use: its name, where it lives, whether it is connected. Tap opens it in Files.
struct FolderRow: View {
    @Environment(AppModel.self) private var model
    var subfolder: String? = nil
    let pickFolder: () -> Void

    var body: some View {
        if let folder = model.folder, !model.folderStale {
            Button { model.openInFiles(subfolder: subfolder) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subfolder.map { "\(folder.displayName) / \($0)" } ?? folder.displayName)
                            .foregroundStyle(Color.primary)
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Connected\(folder.provider.map { " · \($0.name)" } ?? "")")
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Button(action: pickFolder) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus").foregroundStyle(Color.signal).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.folderStale ? "Folder moved" : "No folder yet").foregroundStyle(Color.primary)
                        Text("Pick one that syncs to your computer.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Pick").foregroundStyle(Color.accentColor)
                }
            }
        }
        if let result = model.results["folder"] { ResultLine(result: result, undoKey: "folder") }
    }
}

/// A row with a title, one explanatory line and a leading symbol: the shape every info row uses.
struct InfoRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let line: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(line).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
