import Foundation
import TransmissionKit

/// OS folder permissions are an external boundary; model tests supply an in-process
/// implementation, while the shipped app always uses persistent security-scoped bookmarks.
@MainActor
struct CopyDestinationAccess {
    let bookmark: (URL) throws -> Data
    let resolve: (Data) throws -> URL

    static let system = CopyDestinationAccess(
        bookmark: { try $0.bookmarkData(options: .withSecurityScope) },
        resolve: {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: $0, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
            guard !stale else { throw CocoaError(.fileReadNoPermission) }
            return url
        })
}

struct AutoCopyJob: Codable, Identifiable {
    enum State: String, Codable { case waiting, copying, deleting, complete, failed }
    var id = UUID()
    let serverID: UUID
    let endpoint: String
    let mappings: [PathMapping]
    let hash: String
    let name: String
    let destinationPath: String
    let bookmark: Data
    let deleteFromServer: Bool
    var state: State = .waiting
    var copiedPath: String?
    var error: String?
}

/// Separate from server settings; writing must succeed before a job can run.
@MainActor
enum AutoCopyStore {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transwift/auto-copies.json")
    }

    static func load() throws -> [AutoCopyJob] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        var jobs = try JSONDecoder().decode([AutoCopyJob].self, from: Data(contentsOf: fileURL))
        for index in jobs.indices where jobs[index].state == .copying || jobs[index].state == .deleting {
            // Never replay an uncertain server deletion or copy after a crash.
            jobs[index].state = .failed
            jobs[index].error = loc("A művelet megszakadt. Újrapróbálás előtt ellenőrizd a helyi és szerverfájlokat.")
        }
        return jobs
    }

    static func save(_ jobs: [AutoCopyJob]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(jobs)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
