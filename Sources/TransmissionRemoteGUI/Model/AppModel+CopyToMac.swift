import Foundation
import TransmissionKit

extension AppModel {
    /// Read fresh completion and file metadata. The only RPC operation is torrent-get;
    /// file contents are read through the mounted share's existing path mappings.
    func copyToMac(
        _ targets: [Torrent], serverID: UUID, destination: URL,
        progress: @escaping @Sendable (LocalCopyProgress) -> Void
    ) async throws -> [URL] {
        guard !isCopyingToMac else { throw CopyToMacError.alreadyCopying }
        guard selectedServerID == serverID, let client, let server = selectedServer,
            !targets.isEmpty
        else { throw PathMappingError.contentChanged }
        let mappings = server.pathMappings ?? []
        guard !mappings.isEmpty else { throw PathMappingError.noMapping }
        isCopyingToMac = true
        defer { isCopyingToMac = false }
        let fields = TorrentContentLocator.fields + ["fileStats", "percentDone", "status"]
        let current = try await client.torrentGet(fields: fields, ids: .ids(targets.map { .id($0.id) }))
        try Task.checkCancellation()
        guard self.client === client, selectedServerID == serverID else { throw PathMappingError.contentChanged }
        let plans = try targets.map { original in
            guard let torrent = current.first(where: { TorrentContentLocator.matches($0, original: original) })
            else { throw PathMappingError.contentChanged }
            return try LocalCopyPlan(torrent: torrent, mappings: mappings)
        }
        _ = try await LocalPathAccess.validate(plans.flatMap { $0.files.map(\.source) })
        guard self.client === client, selectedServerID == serverID,
            (selectedServer?.pathMappings ?? []) == mappings
        else { throw PathMappingError.contentChanged }
        try Task.checkCancellation()
        return try await CopyToMac.copy(plans, to: destination, progress: progress)
    }
}
