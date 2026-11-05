import AppKit
import SwiftUI
import TransmissionKit

struct CopyToMacView: View {
    let torrents: [Torrent]
    let serverID: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    @State private var task: Task<Void, Never>?
    @State private var progress: LocalCopyProgress?
    @State private var completed: [URL] = []
    @State private var error: String?
    @State private var cancelling = false
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc("Másolás erre a Macre…")).font(.title2.bold())
            Text(torrents.count == 1 ? torrents[0].displayName : "\(torrents.count) " + loc("kijelölt torrent"))
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Text(loc("A kész fájlok a csatolt megosztásról másolódnak. A szerveren lévő fájlok megmaradnak."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(destination?.path ?? loc("Válassz mappát"))
                    .lineLimit(2).truncationMode(.middle)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(destination?.path ?? loc("Válassz mappát"))
                    .accessibilityIdentifier("copyToMac.destination")
                Spacer()
                Button(loc("Tallózás…"), action: chooseFolder)
                    .disabled(task != nil || finished)
                    .accessibilityIdentifier("copyToMac.choose")
            }
            if task != nil {
                if let progress {
                    ProgressView(value: Double(progress.copiedBytes), total: Double(max(1, progress.totalBytes)))
                    Text(progress.filename).font(.caption).lineLimit(1)
                    Text(Format.size(Int(progress.copiedBytes)) + " / " + Format.size(Int(progress.totalBytes)))
                        .font(.caption.monospacedDigit())
                } else {
                    ProgressView(loc("Fájlok ellenőrzése…"))
                }
                if cancelling { Text(loc("Másolás megszakítása…")).font(.caption).foregroundStyle(.secondary) }
            }
            if finished {
                Label(loc("Másolás kész"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityIdentifier("copyToMac.complete")
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore).accessibilityLabel(error)
                    .accessibilityIdentifier("copyToMac.error")
            }
            if !completed.isEmpty {
                Text(
                    completed.count == 1
                        ? loc("Egy torrent átmásolva") : "\(completed.count) " + loc("torrent átmásolva")
                )
                .font(.caption).foregroundStyle(.secondary)
                Button(loc("Megjelenítés a Finderben")) {
                    NSWorkspace.shared.activateFileViewerSelecting(completed)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(task == nil && (finished || !completed.isEmpty) ? loc("Kész") : loc("Mégse")) {
                    if let task {
                        cancelling = true
                        task.cancel()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(cancelling)
                .accessibilityIdentifier("copyToMac.cancel")
                if !finished && completed.isEmpty {
                    Button(loc("Másolás"), action: start)
                        .keyboardShortcut(.defaultAction)
                        .disabled(task != nil || destination == nil || model.selectedServerID != serverID)
                        .accessibilityIdentifier("copyToMac.submit")
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 390)
        .interactiveDismissDisabled(task != nil)
        .onDisappear { task?.cancel() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        if panel.runModal() == .OK { destination = panel.url }
    }

    private func start() {
        guard task == nil, let destination else { return }
        error = nil
        progress = nil
        completed = []
        task = Task { @MainActor in
            let scoped = destination.startAccessingSecurityScopedResource()
            defer {
                if scoped { destination.stopAccessingSecurityScopedResource() }
                task = nil
                cancelling = false
            }
            do {
                completed = try await model.copyToMac(torrents, serverID: serverID, destination: destination) {
                    update in
                    Task { @MainActor in progress = update }
                }
                finished = true
            } catch let failure as LocalCopyFailure {
                completed = failure.completed
                if failure.underlying is CancellationError {
                    if completed.isEmpty { dismiss() } else { error = loc("Másolás megszakítva") }
                } else {
                    self.error = locCopyToMacError(failure.underlying)
                }
            } catch is CancellationError {
                dismiss()
            } catch {
                self.error = locCopyToMacError(error)
            }
        }
    }
}
