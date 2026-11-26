import SwiftUI

/// Settings → Cloud upload: one row per drive this build can sign in to.
struct CloudSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.cloud.kinds.isEmpty {
            Section {
                ForEach(model.cloud.kinds) { kind in
                    NavigationLink { CloudView(kind: kind) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                CloudName(kind: kind)
                                if let covers = kind.covers { Text(covers).font(.footnote).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text(CloudCopy.short(model.cloud.state(kind))).foregroundStyle(.secondary)
                        }
                    }
                }
                // Named, but not usable in this build: the sign-in for it does not exist yet.
                ForEach(CloudKind.announced.filter { !model.cloud.config.offers($0) }) { kind in
                    let key = "interest:\(kind.rawValue)"
                    let asked = model.results[key]?.kind == .done || DriveInterest.wasSent(kind)
                    let canAsk = model.usageStatisticsAvailable && !asked
                    Button { model.requestDriveInterest(kind) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                CloudName(kind: kind)
                                Text(asked ? "Not ready yet. You asked for it."
                                     : canAsk ? "Not ready yet. Tap to tell the developer you want it."
                                     : "Not ready in this version.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(asked ? "Asked" : "Soon").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAsk)
                    if let result = model.results[key] { ResultLine(result: result, undoKey: key) }
                }
            } header: {
                SectionTitle("Cloud upload")
            } footer: {
                Text("For storage apps that you can't pick as a folder. Health Access uploads your folder to them itself, from this phone straight to your own account.")
            }
        }
    }
}

/// A drive's name, with "Beta" behind it while the upload to it is new.
struct CloudName: View {
    let kind: CloudKind

    var body: some View {
        HStack(spacing: 6) {
            Text(kind.name).foregroundStyle(.primary)
            if kind.isBeta {
                Text("BETA").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.5)))
                    .accessibilityLabel("Beta")
            }
        }
    }
}

/// Settings → Uploads: how the cloud upload may use the network. Shown once a drive is connected.
struct CloudOptionsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.cloud.kinds.contains(where: { model.cloud.state($0).connected }) {
            Section {
                Toggle(isOn: Binding(get: { model.cloud.wifiOnly }, set: { model.cloud.wifiOnly = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Upload on Wi-Fi only")
                        Text("Off: uploads also use mobile data.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: {
                SectionTitle("Uploads")
            } footer: {
                Text("In Low Data Mode, the app uploads nothing, whatever this switch says.")
            }
        }
    }
}

enum CloudCopy {
    static func short(_ status: CloudCenter.Status) -> String {
        if !status.connected { return "Off" }
        if status.needsSignIn { return "Sign in again" }
        if status.busy { return "Uploading" }
        return "On"
    }

    /// One line under the drive's name: what the mirror is doing or did last.
    static func line(_ status: CloudCenter.Status, kind: CloudKind) -> String {
        if !status.connected { return kind.access == .form ? "Fill in the form below to switch on the upload." : "Sign in to switch on the upload." }
        if status.needsSignIn { return "\(kind.name) no longer accepts the sign-in. Connect again." }
        if status.busy {
            if let progress = status.progress, progress.total > 0 {
                let first = progress.total > 200 ? " Keep the app open. The app uploads the rest when you come back, or while the phone rests." : ""
                return "Uploading \(progress.done) of \(progress.total) files.\(first)"
            }
            return "Getting \(kind.name) ready. The upload starts in a few seconds."
        }
        var text = "\(status.files) file\(status.files == 1 ? "" : "s") in \(kind.name)."
        if let last = status.lastRun { text += " Last upload \(Format.dayTime(last))." }
        if status.waiting > 0 { text += " The app uploads \(status.waiting) more with the next sync." }
        if status.inICloud > 0 { text += " \(status.inICloud) file\(status.inICloud == 1 ? " is" : "s are") in iCloud only right now. The app uploads \(status.inICloud == 1 ? "it" : "them") once the phone has \(status.inICloud == 1 ? "it" : "them")." }
        return text
    }

    static func plans(_ kind: CloudKind) -> String {
        if kind.access == .form {
            return "An AI or a script that can write there puts a plan into the plans folder. Health Access brings it to this phone with the next sync, and you find it in the Import tab. README.md in the folder tells the AI how."
        }
        if kind.seesForeignFiles {
            return "An AI that can write to your \(kind.name) puts a plan into the plans folder there. Health Access brings it to this phone with the next sync, and you find it in the Import tab. README.md in the folder tells the AI how."
        }
        return "Google Drive shows an app only the files it made itself. So an AI sends a plan by editing plans/inbox.json, a file Health Access made for that. It arrives with the next sync, and you find it in the Import tab. README.md in the folder tells the AI how."
    }
}

/// One drive: connect, see what the upload is doing, upload now, disconnect.
struct CloudView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.closeDriveSheet) private var closeDriveSheet
    let kind: CloudKind

    var body: some View {
        let status = model.cloud.state(kind)
        let key = "cloud:\(kind.rawValue)"
        List {
            Section {
                InfoRow(symbol: symbol(status), tint: tint(status), title: status.connected ? "Connected" : "Not connected",
                        line: CloudCopy.line(status, kind: kind))
                if status.busy {
                    if let progress = status.progress, progress.total > 0 {
                        ProgressView(value: Double(progress.done), total: Double(progress.total))
                    } else {
                        ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if status.connected {
                    InfoRow(symbol: "folder", tint: .accentColor, title: "Folder in \(kind.name)", line: model.cloud.place(kind))
                    if let url = model.cloud.folderURL(kind) {
                        Link("Open the folder in \(kind.name)", destination: url)
                    }
                }
                if let error = status.lastError, !status.busy {
                    Text(error).font(.footnote).foregroundStyle(Color.signal).fixedSize(horizontal: false, vertical: true)
                }
                if let result = model.results[key] { ResultLine(result: result, undoKey: key) }
                if !status.connected || status.needsSignIn {
                    if kind.access == .signIn {
                        Button(status.needsSignIn ? "Connect again" : "Connect \(kind.name)") { model.requestCloudConnect(kind) }
                    }
                } else {
                    Button("Upload now") { model.kickCloud() }.disabled(status.busy || model.folder == nil)
                }
            } footer: {
                Text(status.connected
                     ? "The app made this folder itself. You can move it inside \(kind.name). The folder on this phone stays the original, and the upload runs after every sync."
                     : (kind == .s3 ? "The app puts the files under the folder you set in your bucket, after every sync."
                        : "The app makes a new folder, Health Access, \(kind.newFolderWhere). It uploads your Health data folder into it after every sync.") + (kind.access == .signIn && kind.folderOnly ? " Health Access can reach only that one folder in your \(kind.name)." : ""))
            }

            if kind.access == .form, !status.connected {
                CloudForm(kind: kind)
            }

            Section {
                Text(CloudCopy.plans(kind)).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: {
                SectionTitle("Plans from your AI")
            }

            if status.connected {
                Section {
                    Button("Disconnect", role: .destructive) { model.requestCloudDisconnect(kind) }
                } footer: {
                    Text("If you disconnect, the files stay in your \(kind.name). The app never deletes them there, except a plan's status file that you undo here.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(kind.name)
        .toolbar {
            if let close = closeDriveSheet {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func symbol(_ status: CloudCenter.Status) -> String {
        if !status.connected { return "icloud.slash" }
        if status.needsSignIn || status.lastError != nil { return "exclamationmark.icloud" }
        return status.busy ? "arrow.up.circle" : "checkmark.icloud"
    }

    private func tint(_ status: CloudCenter.Status) -> Color {
        if !status.connected { return .secondary }
        if status.needsSignIn || status.lastError != nil { return .signal }
        return status.busy ? .accentColor : .green
    }
}

/// The address, name and password of a WebDAV server, or the bucket and keys of an S3 storage.
struct CloudForm: View {
    @Environment(AppModel.self) private var model
    let kind: CloudKind
    @State private var values: [String: String] = [:]

    private struct Field: Identifiable {
        let id: String
        let label: String
        let hint: String
        var secret = false
        var optional = false
    }

    private var fields: [Field] {
        switch kind {
        case .webdav:
            return [Field(id: "address", label: "Address", hint: "https://cloud.example.com/remote.php/dav/files/you"),
                    Field(id: "user", label: "User name", hint: "the name you sign in with, not the address"),
                    Field(id: "password", label: "Password", hint: "an app password, if your server has them", secret: true)]
        default:
            return [Field(id: "bucket", label: "Bucket", hint: "my-bucket"),
                    Field(id: "accessKey", label: "Access key", hint: "access key id"),
                    Field(id: "secretKey", label: "Secret key", hint: "secret access key", secret: true),
                    Field(id: "prefix", label: "Folder", hint: "health-access", optional: true),
                    Field(id: "region", label: "Region", hint: "us-east-1, or leave empty", optional: true),
                    Field(id: "endpoint", label: "Endpoint", hint: "empty for Amazon S3", optional: true)]
        }
    }

    private var missing: [String] {
        fields.filter { !$0.optional && (values[$0.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.label.lowercased() }
    }

    private var complete: Bool { missing.isEmpty }

    private func connect() {
        var filled = values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty }
        if kind == .s3, filled["prefix"] == nil { filled["prefix"] = "health-access" }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        model.requestCloudConnect(kind, fields: filled)
    }

    var body: some View {
        Section {
            ForEach(fields) { field in
                let binding = Binding(get: { values[field.id] ?? "" }, set: { values[field.id] = $0 })
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.optional ? "\(field.label) (optional)" : field.label).font(.footnote).foregroundStyle(.secondary)
                    Group {
                        if field.secret { SecureField(field.hint, text: binding) } else { TextField(field.hint, text: binding) }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(field.id == "address" || field.id == "endpoint" ? .URL : .default)
                    .submitLabel(.go)
                    .onSubmit { if complete { connect() } }
                }
            }
            Button("Connect", action: connect).disabled(!complete)
            if !complete {
                Text("Fill in \(Format.list(missing, last: "and")) first. Then Connect works.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            SectionTitle(kind == .webdav ? "Your server" : "Your storage")
        } footer: {
            Text(kind == .webdav
                 ? "The address of a folder on the server. Nextcloud shows it under Files → Settings → WebDAV. The app makes a Health Access folder inside it. Use https. Plain http works only for a server in your own network."
                 : "For Cloudflare R2, Backblaze B2, MinIO or Wasabi, put the service's S3 address into Endpoint. The key needs to read, write and list in this bucket only.")
        }
    }
}

/// Export tab, under the folder: where copies go, and at once when one of them stopped.
struct CloudStatusRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let shown = model.cloud.kinds.filter { model.cloud.state($0).connected }
        if shown.isEmpty {
            NavigationLink { CloudList() } label: {
                InfoRow(symbol: "icloud.and.arrow.up", tint: .secondary, title: "Cloud upload",
                        line: "Off. For \(Format.list(model.cloud.kinds.map(\.name), last: "and")).")
            }
        } else {
            ForEach(shown) { kind in
                let status = model.cloud.state(kind)
                let trouble = status.needsSignIn || status.lastError != nil
                NavigationLink { CloudView(kind: kind) } label: {
                    InfoRow(symbol: trouble ? "exclamationmark.icloud" : status.busy ? "arrow.up.circle" : "checkmark.icloud",
                            tint: trouble ? .signal : status.busy ? .accentColor : .green,
                            title: "Upload to \(kind.name)", line: status.lastError.map { status.busy ? CloudCopy.line(status, kind: kind) : $0 } ?? CloudCopy.line(status, kind: kind))
                }
            }
        }
    }
}

/// The list of drives on its own screen, reached from the Export tab.
struct CloudList: View {
    var body: some View {
        List { CloudSection() }
            .listStyle(.insetGrouped)
            .navigationTitle("Cloud upload")
            .navigationBarTitleDisplayMode(.inline)
    }
}
