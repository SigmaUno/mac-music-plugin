import AppKit
import SwiftUI

/// Collapsible "Add source" panel: a kind picker (local / https / ssh / network)
/// and the fields that kind needs, plus a "scan directory" mode that stages every
/// audio file under a folder for review. Mirrors the add-source form in
/// `BarWidget.qml`.
@MainActor
struct AddSourceForm: View {
    let engine: PlayerEngine
    @State private var expanded = false
    @State private var kind: SourceKind = .local
    @State private var url = ""
    @State private var user = ""
    @State private var host = ""
    @State private var path = ""
    @State private var scan = false
    @State private var busy = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $kind) {
                    ForEach(SourceKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch kind {
                case .local:
                    Button("Choose files…", action: chooseLocal)
                    Button("Scan a folder…", action: chooseScanFolder)
                        .disabled(engine.isScanning)
                case .https:
                    TextField("https://host/track.flac", text: $url).textFieldStyle(.roundedBorder)
                    addButton { await engine.addRemoteSource(kind: .https, url: url); url = "" }
                case .ssh, .network:
                    TextField("user", text: $user).textFieldStyle(.roundedBorder)
                    TextField("host or IP", text: $host).textFieldStyle(.roundedBorder)
                    TextField(scan ? "remote directory" : "remote path to a file", text: $path)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Scan this directory for all music files", isOn: $scan)
                        .toggleStyle(.checkbox).font(.caption)
                    addButton {
                        if scan {
                            await engine.startScan(kind: kind, username: user, host: host, directory: path)
                            expanded = false
                        } else {
                            await engine.addRemoteSource(kind: kind, username: user, host: host, remotePath: path)
                        }
                        path = ""
                    }
                    .disabled(scan && engine.isScanning)
                }

                if engine.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Scanning…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Add source").font(.callout)
        }
    }

    private func addButton(_ action: @escaping () async -> Void) -> some View {
        HStack {
            Spacer()
            Button(scan ? "Scan" : "Add") {
                busy = true
                Task { await action(); busy = false }
            }
            .disabled(busy)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
    }

    private func chooseLocal() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.title = "Add music files"
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        Task { for p in paths { try? await engine.addLocalFile(path: p) } }
    }

    private func chooseScanFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.title = "Scan a folder for music"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task { await engine.startScan(kind: .local, directory: dir.path); expanded = false }
    }
}
