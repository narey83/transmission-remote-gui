import AppKit
import SwiftUI

struct AutoCopiesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc("Másolások erre a Macre")).font(.title2.bold())
            Text(
                loc(
                    "A várakozó másolások az adott szerverhez csatlakozáskor folytatódnak. A lista törlése nem töröl fájlokat."
                )
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.autoCopyStoreError {
                Text(error).foregroundStyle(.red)
            }
            if model.autoCopyJobs.count <= 1 {
                jobs
            } else {
                ScrollView { jobs }
                    .frame(height: 300)
            }
            HStack {
                Spacer()
                Button(loc("Kész")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var jobs: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.autoCopyJobs) { job in
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.name).font(.headline).lineLimit(2)
                    Text(model.servers.first(where: { $0.id == job.serverID })?.name ?? loc("ismeretlen"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(job.copiedPath ?? job.destinationPath).font(.caption).textSelection(.enabled)
                    Text(status(job)).accessibilityIdentifier("autoCopy.status")
                    Text(
                        job.deleteFromServer
                            ? loc("Torrent és fájlok törlése a szerverről") : loc("Megtartás a szerveren")
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    if job.state == .copying, let progress = model.autoCopyProgress {
                        ProgressView(
                            value: Double(progress.copiedBytes), total: Double(max(1, progress.totalBytes)))
                        Text(progress.filename).font(.caption).lineLimit(1)
                    }
                    if let error = job.error {
                        Text(error).font(.caption).foregroundStyle(.red).fixedSize(
                            horizontal: false, vertical: true)
                    }
                    HStack {
                        if let path = job.copiedPath {
                            Button(loc("Megjelenítés a Finderben")) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                        }
                        if job.state == .failed, job.copiedPath == nil {
                            Button(loc("Újrapróbálás")) { model.retryAutoCopy(job) }
                        }
                        if job.state == .copying {
                            Button(loc("Mégse")) { model.autoCopyTask?.cancel() }
                        } else if job.state != .deleting {
                            Button(loc("Eltávolítás a másolási listából")) { model.dismissAutoCopy(job) }
                        }
                    }
                    Divider()
                }
                .accessibilityElement(children: .contain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func status(_ job: AutoCopyJob) -> String {
        switch job.state {
        case .waiting: loc("Várakozás a letöltésre és a csatolt megosztásra")
        case .copying: loc("Másolás erre a Macre…")
        case .deleting: loc("Helyi másolat ellenőrzése és szerver törlése…")
        case .complete: loc("Másolás kész")
        case .failed:
            job.copiedPath == nil
                ? loc("A másolás figyelmet igényel") : loc("Helyi másolat kész; ellenőrizd a szerver törlését")
        }
    }
}
