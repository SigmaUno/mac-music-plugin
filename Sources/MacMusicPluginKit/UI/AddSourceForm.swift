import AppKit
import SwiftUI

/// Collapsible "Add source" panel: a kind picker (local / https / ssh / network)
/// and the fields that kind needs. Mirrors the add-source form in `BarWidget.qml`.
struct AddSourceForm: View {
    let engine: PlayerEngine
    @State private var expanded = false
    @State private var kind: SourceKind = .local
    @State private var url = ""
    @State private var user = ""
    @State private var host = ""
    @State private var path = ""
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
                case .https:
                    TextField("https://host/track.flac", text: $url).textFieldStyle(.roundedBorder)
                    addButton { await engine.addRemoteSource(kind: .https, url: url); url = "" }
                case .ssh, .network:
                    TextField("user", text: $user).textFieldStyle(.roundedBorder)
                    TextField("host or IP", text: $host).textFieldStyle(.roundedBorder)
                    TextField("remote path to a file", text: $path).textFieldStyle(.roundedBorder)
                    addButton {
                        await engine.addRemoteSource(kind: kind, username: user, host: host, remotePath: path)
                        path = ""
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Add source", systemImage: "plus.circle").font(.callout)
        }
    }

    private func addButton(_ action: @escaping () async -> Void) -> some View {
        HStack {
            Spacer()
            Button("Add") {
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
        Task {
            for p in paths { try? await engine.addLocalFile(path: p) }
        }
    }
}
