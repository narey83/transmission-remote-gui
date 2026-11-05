import SwiftUI
import TransmissionKit

/// Sheet for `torrent-set-location`: asks for the target directory and whether the
/// daemon should physically move the files.
///
/// Uses the Add dialog's per-server folder choices. A failed move keeps the sheet
/// open so the destination can be corrected; successful moves enter the shared history.
struct MoveTorrentView: View {
    let torrents: [Torrent]
    let serverID: UUID
    let onSubmit: (_ location: String, _ move: Bool) async throws -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var location: String
    @State private var moveData = true
    @State private var isMoving = false
    @State private var moveError: String?

    init(torrents: [Torrent], serverID: UUID,
         onSubmit: @escaping (_ location: String, _ move: Bool) async throws -> Void) {
        self.torrents = torrents
        self.serverID = serverID
        self.onSubmit = onSubmit
        // Prefill only when EVERY target reports a directory and they all agree; a single
        // known directory among several torrents must not stand in for the others.
        let dirs = Set(torrents.compactMap(\.downloadDir))
        let allKnown = torrents.allSatisfy { $0.downloadDir != nil }
        _location = State(initialValue: allKnown && dirs.count == 1 ? (dirs.first ?? "") : "")
    }

    private var sanitized: String? { TorrentRowMenu.sanitizedLocation(location) }

    private var subtitle: String {
        torrents.count == 1
            ? torrents[0].displayName
            : "\(torrents.count) " + loc("kijelölt torrent")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc("Torrent áthelyezése")).font(.title2.bold())
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            DownloadDirectoryPicker(directory: $location, allowsDefault: false,
                                    focusOnAppear: true, accessibilityPrefix: "move.location")

            Toggle(loc("Fájlok átmozgatása"), isOn: $moveData)
                .accessibilityIdentifier("move.moveData")
            Text(moveData
                 ? loc("A daemon átmozgatja a fájlokat az új helyre.")
                 : loc("Csak a nyilvántartott hely változik — a fájloknak már ott kell lenniük."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let moveError {
                Text(moveError)
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(moveError)
                    .accessibilityIdentifier("move.error")
            }

            Spacer()

            HStack {
                Spacer()
                Button(loc("Mégse")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("move.cancel")
                Button(loc("Áthelyezés")) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sanitized == nil || !model.isConnected || model.selectedServerID != serverID)
                .accessibilityIdentifier("move.submit")
            }
        }
        .disabled(isMoving)
        .interactiveDismissDisabled(isMoving)
        .padding(20)
        .frame(width: 520, height: 350)
        .onChange(of: model.selectedServerID) {
            if model.selectedServerID != serverID { dismiss() }
        }
    }

    private func submit() {
        guard !isMoving, model.isConnected, model.selectedServerID == serverID,
              let sanitized else { return }
        let move = moveData
        moveError = nil
        isMoving = true
        Task {
            defer { isMoving = false }
            do {
                try await onSubmit(sanitized, move)
                dismiss()
            } catch is CancellationError {
                // A cancelled task does not mean the daemon rejected the path.
            } catch {
                moveError = locError(error)
            }
        }
    }
}
