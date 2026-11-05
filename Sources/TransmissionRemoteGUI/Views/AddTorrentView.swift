import AppKit
import SwiftUI
import TransmissionKit
import UniformTypeIdentifiers

struct AddTorrentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var magnet = ""
    @State private var paused = false
    @State private var fileImporter = false
    @State private var torrentFile: URL?
    @State private var isAdding = false
    @State private var copyWhenFinished = false
    @State private var deleteFromServer = false
    @State private var localDestination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    /// Daemon-side destination for this torrent only; prefilled with the daemon's default.
    @State private var downloadDir = ""

    init(incoming: IncomingTorrent? = nil) {
        switch incoming {
        case .file(let url): _torrentFile = State(initialValue: url)
        case .link(let value): _magnet = State(initialValue: value)
        case nil: break
        }
    }

    /// The field may be empty (= daemon default), otherwise it must be an absolute daemon path.
    private var downloadDirIsValid: Bool {
        let trimmed = downloadDir.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || TorrentRowMenu.sanitizedLocation(trimmed) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc("Torrent hozzáadása")).font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                if let torrentFile {
                    Text(torrentFile.lastPathComponent)
                        .lineLimit(2)
                        .accessibilityIdentifier("add.file")
                    Button(loc("Magnet link vagy URL")) { self.torrentFile = nil }
                } else {
                    Text(loc("Magnet link vagy URL")).font(.callout).foregroundStyle(.secondary)
                    TextField("magnet:?xt=… vagy https://…", text: $magnet, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("add.magnet")
                }
            }

            DownloadDirectoryPicker(directory: $downloadDir)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(loc("Másolás erre a Macre a letöltés után"), isOn: $copyWhenFinished)
                    .accessibilityIdentifier("add.copyWhenFinished")
                    .disabled((model.selectedServer?.pathMappings ?? []).isEmpty || model.autoCopyStoreError != nil)
                if copyWhenFinished {
                    HStack {
                        Text(localDestination?.path ?? loc("Válassz mappát"))
                            .lineLimit(1).truncationMode(.middle)
                            .accessibilityIdentifier("add.localDestination")
                        Spacer()
                        Button(loc("Tallózás…"), action: chooseLocalFolder)
                            .accessibilityIdentifier("add.chooseLocalDestination")
                    }
                    Picker(loc("A másolás után"), selection: $deleteFromServer) {
                        Text(loc("Megtartás a szerveren")).tag(false)
                        Text(loc("Torrent és fájlok törlése a szerverről")).tag(true)
                    }
                    .accessibilityIdentifier("add.afterCopy")
                    Text(
                        loc(
                            "A szerver tölti le, majd az app a csatolt megosztásról másolja. Tartsd nyitva az appot, vagy nyisd meg később a folytatáshoz."
                        )
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if deleteFromServer {
                        Text(
                            loc(
                                "A szerverről csak a teljes helyi másolat ellenőrzése után törlünk. Minden torrentfájlt ki kell jelölni."
                            )
                        )
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else if (model.selectedServer?.pathMappings ?? []).isEmpty {
                    Text(loc("Az automatikus másoláshoz állíts be útvonal-hozzárendelést egy csatolt megosztáshoz."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button {
                    fileImporter = true
                } label: {
                    Label(loc(".torrent fájl választása"), systemImage: "doc.badge.plus")
                }
                Spacer()
                Toggle(loc("Leállítva add hozzá"), isOn: $paused)
            }

            HStack {
                Spacer()
                Button(loc("Mégse")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(loc("Hozzáadás")) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    (torrentFile == nil && magnet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        || !downloadDirIsValid || !model.isConnected || (copyWhenFinished && localDestination == nil)
                )
                .accessibilityIdentifier("add.submit")
            }
        }
        .disabled(isAdding)
        .interactiveDismissDisabled(isAdding)
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(
            isPresented: $fileImporter,
            allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data]
        ) { result in
            if case .success(let url) = result {
                torrentFile = url
            }
        }
        .onAppear { prefillDownloadDir() }
        // Session info may arrive after the sheet opened: fill in the default if still empty.
        .onChange(of: model.defaultDownloadDir) { prefillDownloadDir() }
    }

    // MARK: - Download directory

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = localDestination
        if panel.runModal() == .OK { localDestination = panel.url }
    }

    private func prefillDownloadDir() {
        if downloadDir.isEmpty, let dir = model.defaultDownloadDir { downloadDir = dir }
    }

    /// What to send with `torrent-add` (nil = let the daemon use its default) and how to record
    /// it in this server's history once the add succeeded. The server is captured now, so a
    /// server switch while the request runs cannot file the path under the wrong server.
    private func resolvedDownloadDir() -> (dir: String?, record: @MainActor () -> Void) {
        let dir = DownloadDirectories.effectiveDownloadDir(downloadDir, daemonDefault: model.defaultDownloadDir)
        let serverID = model.selectedServerID
        return (
            dir,
            {
                if let dir, let serverID { model.recordUsedDownloadDir(dir, serverID: serverID) }
            }
        )
    }

    private func submit() {
        guard !isAdding, model.isConnected, downloadDirIsValid else { return }
        let value = magnet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard torrentFile != nil || !value.isEmpty else { return }
        let target = resolvedDownloadDir()
        isAdding = true
        Task {
            let added: Bool
            if copyWhenFinished, let localDestination {
                added = await model.addWithAutoCopy(
                    filename: value, file: torrentFile, paused: paused,
                    downloadDir: target.dir, destination: localDestination, deleteFromServer: deleteFromServer)
            } else if let torrentFile {
                added = await model.addTorrentFile(torrentFile, paused: paused, downloadDir: target.dir)
            } else {
                added = await model.add(filename: value, paused: paused, downloadDir: target.dir)
            }
            isAdding = false
            if added {
                target.record()
                dismiss()
            }
        }
    }
}
