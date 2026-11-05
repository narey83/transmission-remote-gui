import Foundation
import TransmissionKit

extension AppModel {
    /// Keeps ordinary adds unchanged. A duplicate can explicitly opt into a copy too.
    func addWithAutoCopy(
        filename: String, file: URL?, paused: Bool, downloadDir: String?,
        destination: URL, deleteFromServer: Bool
    ) async -> Bool {
        guard isConnected, let client, let server = selectedServer else { return false }
        var submitted = false
        do {
            guard autoCopyStoreError == nil else { throw CocoaError(.fileReadCorruptFile) }
            let mappings = try PathMapping.validated(server.pathMappings ?? [])
            guard !mappings.isEmpty else { throw PathMappingError.noMapping }
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey])
            guard values.isDirectory == true, values.volumeIsLocal == true else {
                throw CopyToMacError.localDestinationRequired
            }
            let bookmark = try copyDestinationAccess.bookmark(destination)
            try AutoCopyStore.save(autoCopyJobs)  // Fail before submitting if persistence is unavailable.
            let result: TorrentAddResult
            if let file {
                let fileScoped = file.startAccessingSecurityScopedResource()
                defer { if fileScoped { file.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: file)
                result = try await client.torrentAdd(
                    metainfoBase64: data.base64EncodedString(), paused: paused, downloadDir: downloadDir)
            } else {
                result = try await client.torrentAdd(filename: filename, paused: paused, downloadDir: downloadDir)
            }
            submitted = true
            guard let added = result.added ?? result.duplicate, let rawHash = added.hashString,
                Self.validAutoCopyHash(rawHash), let endpoint = server.url?.absoluteString
            else { throw PathMappingError.metadataUnavailable }
            let hash = rawHash.lowercased()
            // An accidental second Add must not change an existing copy's deletion policy.
            if !autoCopyJobs.contains(where: { $0.serverID == server.id && $0.hash == hash && $0.state != .complete }) {
                let job = AutoCopyJob(
                    serverID: server.id, endpoint: endpoint, mappings: mappings, hash: hash,
                    name: added.name ?? hash, destinationPath: destination.path,
                    bookmark: bookmark, deleteFromServer: deleteFromServer)
                try replaceAutoCopyJobs(autoCopyJobs + [job])
            }
            if self.client === client { await refresh() }
            return true
        } catch {
            let detail = locCopyToMacError(error)
            actionError =
                submitted
                ? loc("A torrent hozzáadva, de az automatikus másolás nem menthető. Állítsd be újra a másolást.") + "\n"
                    + detail
                : detail
            // Do not encourage resubmitting a torrent which was successfully added.
            return submitted
        }
    }

    static func validAutoCopyHash(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
    }

    func replaceAutoCopyJobs(_ jobs: [AutoCopyJob]) throws {
        try AutoCopyStore.save(jobs)
        autoCopyJobs = jobs
    }

    private func updateAutoCopy(_ id: UUID, _ change: (inout AutoCopyJob) -> Void) throws {
        var jobs = autoCopyJobs
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        try replaceAutoCopyJobs(jobs)
    }

    func scheduleAutoCopies() {
        guard autoCopyTask == nil, !isCopyingToMac, isConnected,
            autoCopyJobs.contains(where: { $0.serverID == selectedServerID && $0.state == .waiting })
        else { return }
        autoCopyTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.autoCopyTask = nil
                self.autoCopyProgress = nil
            }
            await self.processAutoCopies()
        }
    }

    /// One ready job per pass; polling continues while the file worker runs.
    func processAutoCopies() async {
        guard !isCopyingToMac, isConnected, let client, let server = selectedServer else { return }
        for job in autoCopyJobs where job.serverID == server.id && job.state == .waiting {
            var publishedPath: String?
            do {
                guard server.url?.absoluteString == job.endpoint, server.pathMappings == job.mappings,
                    Self.validAutoCopyHash(job.hash)
                else { throw PathMappingError.contentChanged }
                var candidate = torrents.first(where: { $0.hashString?.lowercased() == job.hash })
                if candidate == nil {
                    // A poll started before Add can arrive late. Confirm absence by hash
                    // instead of treating that older snapshot as a removed torrent.
                    candidate = try await client.torrentGet(ids: .ids([.hash(job.hash)]))
                        .first(where: { $0.hashString?.lowercased() == job.hash })
                }
                guard self.client === client, selectedServerID == server.id, let torrent = candidate else {
                    throw PathMappingError.contentChanged
                }
                guard torrent.percentDone == 1, torrent.statusValue != .verifying,
                    torrent.statusValue != .queuedToVerify
                else { continue }
                try Task.checkCancellation()
                try updateAutoCopy(job.id) {
                    $0.state = .copying
                    $0.error = nil
                }
                let destination = try copyDestinationAccess.resolve(job.bookmark)
                let scoped = destination.startAccessingSecurityScopedResource()
                defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
                let copied = try await copyToMac([torrent], serverID: server.id, destination: destination) {
                    [weak self] update in
                    Task { @MainActor [weak self] in self?.autoCopyProgress = update }
                }
                guard let output = copied.first else { throw CopyToMacError.noFiles }
                publishedPath = output.path
                // Persist the published path before doing anything destructive on the server.
                try updateAutoCopy(job.id) {
                    $0.copiedPath = output.path
                    $0.state = job.deleteFromServer ? .deleting : .complete
                }
                if job.deleteFromServer {
                    try Task.checkCancellation()
                    guard self.client === client, selectedServerID == server.id,
                        selectedServer?.url?.absoluteString == job.endpoint,
                        selectedServer?.pathMappings == job.mappings
                    else { throw PathMappingError.contentChanged }
                    let fields = TorrentContentLocator.fields + ["fileStats", "percentDone", "status"]
                    let current = try await client.torrentGet(fields: fields, ids: .ids([.hash(job.hash)]))
                    guard self.client === client, let fresh = current.first,
                        fresh.hashString?.lowercased() == job.hash,
                        fresh.downloadDir == torrent.downloadDir,
                        let files = fresh.files, !files.isEmpty
                    else { throw PathMappingError.contentChanged }
                    guard let stats = fresh.fileStats, stats.count == files.count, stats.allSatisfy(\.wanted)
                    else { throw CopyToMacError.allFilesRequired }
                    // Refuse deletion when any remote files were excluded, or metadata changed.
                    let plan = try LocalCopyPlan(torrent: fresh, mappings: job.mappings)
                    try await CopyToMac.verify(plan, at: output)
                    try Task.checkCancellation()
                    guard self.client === client, selectedServerID == server.id,
                        selectedServer?.url?.absoluteString == job.endpoint,
                        selectedServer?.pathMappings == job.mappings
                    else { throw PathMappingError.contentChanged }
                    // Hash addressing prevents an integer ID reused by a different torrent.
                    try await client.torrentRemove(ids: .ids([.hash(job.hash)]), deleteLocalData: true)
                    try updateAutoCopy(job.id) { $0.state = .complete }
                }
            } catch {
                do {
                    try updateAutoCopy(job.id) {
                        $0.state = .failed
                        $0.copiedPath = publishedPath ?? $0.copiedPath
                        let cause = (error as? LocalCopyFailure)?.underlying ?? error
                        $0.error = cause is CancellationError ? loc("Másolás megszakítva") : locCopyToMacError(cause)
                    }
                } catch { autoCopyStoreError = locError(error) }
            }
            return
        }
    }

    func retryAutoCopy(_ job: AutoCopyJob) {
        // An uncertain cleanup is deliberately never replayed by Retry.
        guard job.state == .failed, job.copiedPath == nil else { return }
        do {
            try updateAutoCopy(job.id) {
                $0.state = .waiting
                $0.error = nil
            }
            scheduleAutoCopies()
        } catch { autoCopyStoreError = locError(error) }
    }

    func dismissAutoCopy(_ job: AutoCopyJob) {
        guard job.state != .copying, job.state != .deleting else { return }
        do { try replaceAutoCopyJobs(autoCopyJobs.filter { $0.id != job.id }) } catch {
            autoCopyStoreError = locError(error)
        }
    }
}
