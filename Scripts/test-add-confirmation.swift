import Foundation
import TransmissionKit

// Add/Move model integration tests: every RPC is intercepted in-process; no daemon is contacted.
final class ConfirmationRPC: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var adds: [[String: Any]] = []
    nonisolated(unsafe) private static var locations: [[String: Any]] = []
    nonisolated(unsafe) private static var rejectLocation = false
    nonisolated(unsafe) private static var locationDelay: TimeInterval = 0
    nonisolated(unsafe) private static var copyRow: [String: Any]?
    nonisolated(unsafe) private static var methods: [String] = []
    nonisolated(unsafe) private static var removals: [[String: Any]] = []
    nonisolated(unsafe) private static var duplicateAdd = false
    nonisolated(unsafe) private static var addRejected = false
    nonisolated(unsafe) private static var removeRejected = false
    nonisolated(unsafe) private static var cleanupHook: (@Sendable () -> Void)?
    static var removed: [[String: Any]] { lock.withLock { removals } }
    static func setAddDuplicate(_ value: Bool) { lock.withLock { duplicateAdd = value } }
    static func rejectAdds(_ value: Bool) { lock.withLock { addRejected = value } }
    static func rejectRemoves(_ value: Bool) { lock.withLock { removeRejected = value } }
    static func onCleanup(_ hook: (@Sendable () -> Void)?) { lock.withLock { cleanupHook = hook } }

    static func setCopyRow(_ row: [String: Any]?) { lock.withLock { copyRow = row } }
    static var writtenMethods: [String] { lock.withLock { methods.filter { $0 != "torrent-get" && $0 != "session-get" && $0 != "session-stats" && $0 != "free-space" } } }

    static var moves: [[String: Any]] { lock.withLock { locations } }
    static func rejectNextMove() { lock.withLock { rejectLocation = true } }
    static func delayMoves(by delay: TimeInterval) { lock.withLock { locationDelay = delay } }

    static var submissions: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return adds
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let method = envelope["method"] as? String ?? ""
        Self.lock.withLock { Self.methods.append(method) }
        var arguments: [String: Any] = [:]
        var result = "success"
        var delay: TimeInterval = 0
        switch method {
        case "session-get": arguments = ["download-dir": "/downloads"]
        case "torrent-get":
            arguments = Self.lock.withLock { ["torrents": Self.copyRow.map { [$0] } ?? []] }
            if let args = envelope["arguments"] as? [String: Any], args["ids"] is [String] {
                Self.lock.withLock { Self.cleanupHook }?()
            }
        case "torrent-add":
            Self.lock.lock()
            Self.adds.append(envelope["arguments"] as? [String: Any] ?? [:])
            if Self.addRejected { result = "permission denied" }
            if let row = Self.copyRow {
                arguments = [Self.duplicateAdd ? "torrent-duplicate" : "torrent-added":
                    ["id": row["id"]!, "name": row["name"]!, "hashString": row["hashString"]!]]
            }
            Self.lock.unlock()
        case "torrent-remove":
            Self.lock.withLock {
                Self.removals.append(envelope["arguments"] as? [String: Any] ?? [:])
                if Self.removeRejected { result = "permission denied" }
            }
        case "torrent-set-location":
            Self.lock.withLock {
                Self.locations.append(envelope["arguments"] as? [String: Any] ?? [:])
                if Self.rejectLocation { result = "permission denied"; Self.rejectLocation = false }
                delay = Self.locationDelay
            }
        default: break
        }
        let data = try! JSONSerialization.data(withJSONObject: ["result": result, "arguments": arguments])
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { self.respond(data) }
        } else {
            respond(data)
        }
    }

    private func respond(_ data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
struct ConfirmationTests {
    @MainActor
    static func main() async throws {
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]?.contains("confirmation-test-home") == true
        else {
            fatalError("Run with an isolated confirmation-test-home")
        }
        fflush(nil)
        precondition(URLProtocol.registerClass(ConfirmationRPC.self))
        defer { URLProtocol.unregisterClass(ConfirmationRPC.self) }
        let model = AppModel()
        precondition(model.servers.isEmpty, "Test home must start empty")
        let server = ServerConfig(name: "Confirmation test", host: "confirmation.invalid", refreshInterval: 3600)
        model.servers = [server]
        model.connect(to: server)
        for _ in 0..<500 where !model.isConnected {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(model.isConnected, "Mock connection failed")

        let file = URL(fileURLWithPath: "/tmp/confirmation.torrent")
        let magnet = URL(string: "magnet:?xt=urn:btih:0123456789012345678901234567890123456789")!
        model.openIncoming([file, magnet, file])
        precondition(model.addRequest?.incoming == .file(file))
        let requestID = model.addRequest?.id
        model.openIncoming([file])
        precondition(model.addRequest?.id == requestID, "Duplicate open replaced the active dialog")
        await model.refresh()
        precondition(ConfirmationRPC.submissions.isEmpty, "Open or refresh submitted without confirmation")
        model.addRequest = nil  // Cancel
        model.presentNextIncoming()
        precondition(model.addRequest?.incoming == .link(magnet.absoluteString))
        model.addRequest = nil  // Cancel the second item too
        model.presentNextIncoming()
        precondition(model.addRequest == nil)
        precondition(ConfirmationRPC.submissions.isEmpty, "Cancel submitted a torrent")
        print("PASS: opens wait for confirmation, deduplicate, preserve order, and cancel without RPC")

        model.showAddTorrent()
        model.enqueueIncoming([.file(file)])
        precondition(model.addRequest?.incoming == nil, "External open replaced a manual Add dialog")
        model.addRequest = nil
        model.presentNextIncoming()
        precondition(model.addRequest?.incoming == .file(file))
        print("PASS: external opens wait behind manual Add")

        let other = ServerConfig(name: "Other", host: "other.invalid", refreshInterval: 3600)
        model.connect(to: other)
        precondition(model.addRequest == nil, "Server switch retained an old confirmation")
        model.disconnect()
        model.presentNextIncoming()
        precondition(model.addRequest == nil)
        print("PASS: switching servers discards pending confirmations")

        model.connect(to: server)
        await model.refresh()
        let added = await model.add(filename: magnet.absoluteString, paused: true, downloadDir: "/movies")
        precondition(added)
        precondition(ConfirmationRPC.submissions.count == 1)
        precondition(ConfirmationRPC.submissions[0]["download-dir"] as? String == "/movies")
        precondition(ConfirmationRPC.submissions[0]["paused"] as? Bool == true)
        precondition(model.defaultDownloadDir == nil || model.defaultDownloadDir == "/downloads")
        let readResult = await model.addTorrentFile(URL(fileURLWithPath: "/no-such-confirmation-test-file.torrent"))
        precondition(!readResult && model.actionError != nil)
        precondition(ConfirmationRPC.submissions.count == 1)
        model.disconnect()
        print("PASS: confirmed destination is sent per torrent; unreadable files report an error")

        let remaining = ServerConfig(name: "Remaining", host: "remaining.invalid", refreshInterval: 3600)
        model.servers = [server, remaining]
        model.connect(to: server)
        for _ in 0..<500 where !model.isConnected {
            try await Task.sleep(for: .milliseconds(10))
        }
        model.openIncoming([file])
        precondition(model.addRequest?.incoming == .file(file))
        model.deleteServer(server)
        precondition(model.addRequest == nil, "Deleting the current server kept its confirmation open")
        model.connect(to: remaining)
        for _ in 0..<500 where !model.isConnected {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(model.addRequest == nil, "A confirmation for the deleted server reappeared")
        precondition(ConfirmationRPC.submissions.count == 1)
        model.disconnect()
        print("PASS: PASS4 deleting the current server drops its open confirmation")

        model.connect(to: remaining)
        await model.refresh()
        let ids = RPCIds.ids([.id(7), .id(9)])
        model.actionError = nil
        try await model.setLocation("/movies", move: true, ids: ids, serverID: remaining.id)
        precondition(ConfirmationRPC.moves.count == 1)
        precondition(ConfirmationRPC.moves[0]["location"] as? String == "/movies")
        precondition(ConfirmationRPC.moves[0]["ids"] as? [Int] == [7, 9])
        precondition(ConfirmationRPC.moves[0]["move"] as? Bool == true)
        precondition(model.downloadDirs.recent == ["/movies"])
        precondition(model.defaultDownloadDir == "/downloads")
        precondition(DownloadDirStore.load()[remaining.id]?.recent == ["/movies"])
        print("PASS: moving selected torrents remembers the destination without changing the daemon default")

        try await model.setLocation("/shows", move: false, ids: ids, serverID: remaining.id)
        precondition(ConfirmationRPC.moves[1]["move"] as? Bool == false)
        precondition(model.downloadDirs.recent == ["/shows", "/movies"])
        model.addFavoriteDownloadDir("/movies")
        precondition(model.downloadDirs.isFavorite("/movies"))
        print("PASS: locating existing files records history and shares favorites with Add")

        ConfirmationRPC.rejectNextMove()
        do {
            try await model.setLocation("/refused", move: true, ids: ids, serverID: remaining.id)
            preconditionFailure("Rejected move must throw to the sheet")
        } catch {
            precondition(model.actionError == nil, "Move must not queue an alert behind the sheet")
        }
        precondition(model.downloadDirs.recent == ["/shows", "/movies"])
        let beforeEmpty = ConfirmationRPC.moves.count
        do {
            try await model.setLocation("/empty", move: true, ids: .ids([]), serverID: remaining.id)
            preconditionFailure("Empty selection must be refused")
        } catch {
            precondition(ConfirmationRPC.moves.count == beforeEmpty)
        }
        precondition(!model.downloadDirs.recent.contains("/empty"))
        print("PASS: failed moves and empty selections do not enter history")

        ConfirmationRPC.delayMoves(by: 0.2)
        let beforePending = ConfirmationRPC.moves.count
        let pendingMove = Task { try await model.setLocation("/completed-on-original", move: true,
                                                       ids: ids, serverID: remaining.id) }
        for _ in 0..<500 where ConfirmationRPC.moves.count == beforePending {
            try await Task.sleep(for: .milliseconds(1))
        }
        precondition(ConfirmationRPC.moves.count == beforePending + 1)
        model.connect(to: server)
        try await pendingMove.value
        precondition(model.downloadDirsByServer[remaining.id]?.recent.first == "/completed-on-original")
        precondition(model.downloadDirs.recent.isEmpty)
        precondition(!model.downloadDirs.isFavorite("/movies"))
        let beforeStale = ConfirmationRPC.moves.count
        do {
            try await model.setLocation("/stale", move: true, ids: ids, serverID: remaining.id)
            preconditionFailure("A stale sheet must not submit to a different server")
        } catch {
            precondition(ConfirmationRPC.moves.count == beforeStale)
        }
        print("PASS: move history stays with the original server; stale sheets cannot submit to another server")
        model.disconnect()

        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!)
        let source = home.appendingPathComponent("copy-source")
        let destination = home.appendingPathComponent("copy-destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("copy fixture".utf8).write(to: source.appendingPathComponent("example.txt"))
        var copyServer = ServerConfig(name: "Copy test", host: "copy.invalid", refreshInterval: 3600,
            pathMappings: [PathMapping(remotePath: "/remote", localPath: source.path)])
        model.servers = [copyServer]
        var row: [String: Any] = ["id": 7, "name": "Example", "hashString": String(repeating: "d", count: 40),
                                 "percentDone": 1, "downloadDir": "/remote", "status": 6,
                                 "files": [["name": "example.txt", "length": 12, "bytesCompleted": 12]],
                                 "fileStats": [["wanted": true, "priority": 0, "bytesCompleted": 12]]]
        ConfirmationRPC.setCopyRow(row)
        model.connect(to: copyServer)
        await model.refresh()
        let original = try JSONDecoder().decode(Torrent.self, from: JSONSerialization.data(withJSONObject: row))
        let previousWrites = ConfirmationRPC.writtenMethods
        let copied = try await model.copyToMac([original], serverID: copyServer.id, destination: destination) { _ in }
        precondition(copied.count == 1)
        let copiedData = try Data(contentsOf: copied[0])
        precondition(copiedData == Data("copy fixture".utf8))
        precondition(ConfirmationRPC.writtenMethods == previousWrites, "Copy must never mutate the daemon")
        precondition(!model.isCopyingToMac)
        print("PASS: Copy to This Mac uses fresh RPC metadata, copies exact bytes, and sends no mutating RPC")

        row["percentDone"] = 0.5
        ConfirmationRPC.setCopyRow(row)
        do {
            _ = try await model.copyToMac([original], serverID: copyServer.id, destination: destination) { _ in }
            preconditionFailure("Cached completion must not override fresh incomplete metadata")
        } catch { precondition(error as? CopyToMacError == .incomplete) }
        row["percentDone"] = 1
        row["hashString"] = String(repeating: "e", count: 40)
        ConfirmationRPC.setCopyRow(row)
        do {
            _ = try await model.copyToMac([original], serverID: copyServer.id, destination: destination) { _ in }
            preconditionFailure("Reused torrent IDs must not copy different content")
        } catch { precondition(error as? PathMappingError == .contentChanged) }
        copyServer.pathMappings = nil
        model.servers = [copyServer]
        model.connect(to: copyServer)
        do {
            _ = try await model.copyToMac([original], serverID: copyServer.id, destination: destination) { _ in }
            preconditionFailure("Missing mappings must fail before file I/O")
        } catch { precondition(error as? PathMappingError == .noMapping) }
        precondition(ConfirmationRPC.writtenMethods == previousWrites)
        let copiedNames = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        precondition(copiedNames == ["example.txt"])
        model.disconnect()
        ConfirmationRPC.setCopyRow(nil)
        print("PASS: incomplete or replaced torrents and missing mappings cannot start a local copy")
        try await testAutomaticCopies(home: home)
    }

    @MainActor
    static func testAutomaticCopies(home: URL) async throws {
        func check(_ condition: Bool, _ message: String = "Automatic copy regression", line: UInt = #line) { precondition(condition, "Line \(line): \(message)") }
        let source = home.appendingPathComponent("auto-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = Data("safe auto copy".utf8)
        try bytes.write(to: source.appendingPathComponent("download.iso"))
        let server = ServerConfig(name: "Auto test", host: "auto.invalid", refreshInterval: 3600,
            pathMappings: [PathMapping(remotePath: "/downloads", localPath: source.path)])
        let hash = String(repeating: "a", count: 40)
        var row: [String: Any] = ["id": 77, "name": "Auto", "hashString": hash, "percentDone": 0.5,
            "downloadDir": "/downloads", "status": 4,
            "files": [["name": "download.iso", "length": bytes.count, "bytesCompleted": bytes.count]],
            "fileStats": [["wanted": true, "priority": 0, "bytesCompleted": bytes.count]]]
        let testAccess = CopyDestinationAccess(
            bookmark: { Data($0.path.utf8) },
            resolve: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) })
        let model = AppModel(copyDestinationAccess: testAccess)
        model.servers = [server]
        ConfirmationRPC.setCopyRow(row)
        model.connect(to: server)
        await model.refresh()

        func destination(_ name: String) throws -> URL {
            let dir = home.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        func settle() async throws {
            for _ in 0..<1000 {
                if model.autoCopyTask == nil { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("Automatic copy did not settle")
        }
        func add(_ dest: URL, delete: Bool = false, file: URL? = nil) async -> Bool {
            await model.addWithAutoCopy(filename: "https://example.invalid/test.torrent", file: file,
                paused: true, downloadDir: "/downloads", destination: dest, deleteFromServer: delete)
        }
        func clear() throws {
            try model.replaceAutoCopyJobs([])
            ConfirmationRPC.onCleanup(nil)
        }

        let kept = try destination("auto-kept")
        check(await add(kept), model.actionError ?? "Add failed")
        try await settle()
        check(model.autoCopyJobs.count == 1 && model.autoCopyJobs[0].state == .waiting)
        check(model.unfinishedAutoCopyCount == 1, "Waiting copy must keep status visible")
        let waiting = try AutoCopyStore.load()
        check(waiting.count == 1 && !waiting[0].deleteFromServer)
        check(AppModel().autoCopyJobs[0].hash == hash, "Waiting copy must survive restart")
        check(!FileManager.default.fileExists(atPath: kept.appendingPathComponent("download.iso").path))
        check(ConfirmationRPC.submissions.last?["paused"] as? Bool == true)
        print("PASS: Add persists paused/incomplete copies, remembers the chosen local folder and resumes after restart")

        ConfirmationRPC.setAddDuplicate(true)
        check(await add(kept, delete: true))
        check(model.autoCopyJobs.count == 1 && !model.autoCopyJobs[0].deleteFromServer)
        ConfirmationRPC.setAddDuplicate(false)
        row["percentDone"] = 1
        row["status"] = 6
        ConfirmationRPC.setCopyRow(row)
        let removeStart = ConfirmationRPC.removed.count
        await model.refresh()
        try await settle()
        check(model.autoCopyJobs[0].state == .complete)
        check(model.unfinishedAutoCopyCount == 0 && model.autoCopyJobs.count == 1,
            "Completed history must not keep the footer visible")
        check(try Data(contentsOf: kept.appendingPathComponent("download.iso")) == bytes)
        check(ConfirmationRPC.removed.count == removeStart)
        print("PASS: completion automatically copies exact bytes; Keep on server and duplicate Add never issue deletion")

        try clear()
        let removed = try destination("auto-removed")
        check(await add(removed, delete: true))
        try await settle()
        check(model.autoCopyJobs[0].state == .complete)
        check(ConfirmationRPC.removed.count == removeStart + 1)
        check(ConfirmationRPC.removed.last?["delete-local-data"] as? Bool == true)
        check(ConfirmationRPC.removed.last?["ids"] as? [String] == [hash])
        check(try Data(contentsOf: removed.appendingPathComponent("download.iso")) == bytes)
        print("PASS: opted-in server cleanup happens only after byte verification and addresses the exact torrent hash")

        try clear()
        let corrupt = try destination("auto-corrupt")
        ConfirmationRPC.onCleanup {
            try! Data(repeating: 0, count: bytes.count).write(to: corrupt.appendingPathComponent("download.iso"))
        }
        check(await add(corrupt, delete: true))
        try await settle()
        check(model.autoCopyJobs[0].state == .failed && model.autoCopyJobs[0].copiedPath != nil)
        check(model.unfinishedAutoCopyCount == 1, "Cleanup failure must remain visible for review")
        check(ConfirmationRPC.removed.count == removeStart + 1)
        model.retryAutoCopy(model.autoCopyJobs[0])
        check(model.autoCopyJobs[0].state == .failed, "Uncertain cleanup must never be replayed")
        print("PASS: edited local data prevents deletion; cleanup retries cannot silently recopy or delete")

        try clear()
        var interrupted = waiting[0]
        interrupted.state = .deleting
        interrupted.copiedPath = removed.path
        try model.replaceAutoCopyJobs([interrupted])
        let recovered = try AutoCopyStore.load()
        check(recovered[0].state == .failed && recovered[0].copiedPath != nil)
        check(recovered[0].error != nil)
        print("PASS: an interrupted deletion requires review after restart and is never repeated automatically")

        try clear()
        let subset = try destination("auto-subset")
        row["files"] = [["name": "download.iso", "length": bytes.count, "bytesCompleted": bytes.count],
                        ["name": "not-selected.txt", "length": 5, "bytesCompleted": 0]]
        row["fileStats"] = [["wanted": true, "priority": 0, "bytesCompleted": bytes.count],
                            ["wanted": false, "priority": 0, "bytesCompleted": 0]]
        ConfirmationRPC.setCopyRow(row)
        check(await add(subset, delete: true))
        try await settle()
        check(model.autoCopyJobs[0].state == .failed && model.autoCopyJobs[0].copiedPath != nil)
        check(ConfirmationRPC.removed.count == removeStart + 1)
        print("PASS: unwanted files cannot be deleted from the server by a partial local copy")

        try clear()
        row["files"] = [["name": "download.iso", "length": bytes.count, "bytesCompleted": bytes.count]]
        row["fileStats"] = [["wanted": true, "priority": 0, "bytesCompleted": bytes.count]]
        ConfirmationRPC.setCopyRow(row)
        ConfirmationRPC.rejectRemoves(true)
        check(await add(try destination("auto-cleanup-failure"), delete: true))
        try await settle()
        check(model.autoCopyJobs[0].state == .failed && model.autoCopyJobs[0].copiedPath != nil)
        let failedRemoveCount = ConfirmationRPC.removed.count
        model.retryAutoCopy(model.autoCopyJobs[0])
        await model.refresh()
        try await settle()
        check(ConfirmationRPC.removed.count == failedRemoveCount)
        ConfirmationRPC.rejectRemoves(false)
        print("PASS: rejected server cleanup retains the local copy and is not retried on refresh")

        try clear()
        ConfirmationRPC.rejectAdds(true)
        let refused = await add(try destination("auto-refused"))
        check(!refused && model.autoCopyJobs.isEmpty)
        ConfirmationRPC.rejectAdds(false)
        let beforeNoMapping = ConfirmationRPC.submissions.count
        var changed = server
        changed.pathMappings = nil
        model.servers = [changed]
        let unmapped = await add(kept)
        check(!unmapped && ConfirmationRPC.submissions.count == beforeNoMapping)
        model.servers = [server]
        print("PASS: rejected adds and missing mappings cannot leave phantom jobs or submit unintended torrents")

        let retryDestination = try destination("auto-retry")
        row["percentDone"] = 0.5
        ConfirmationRPC.setCopyRow(row)
        check(await add(retryDestination))
        try await settle()
        let sourceFile = source.appendingPathComponent("download.iso")
        let hiddenSource = source.appendingPathComponent("unavailable.iso")
        try FileManager.default.moveItem(at: sourceFile, to: hiddenSource)
        row["percentDone"] = 1
        ConfirmationRPC.setCopyRow(row)
        await model.refresh()
        try await settle()
        check(model.autoCopyJobs[0].state == .failed && model.autoCopyJobs[0].copiedPath == nil)
        check(ConfirmationRPC.removed.count == failedRemoveCount)
        try FileManager.default.moveItem(at: hiddenSource, to: sourceFile)
        model.retryAutoCopy(model.autoCopyJobs[0])
        try await settle()
        check(model.autoCopyJobs[0].state == .complete)
        check(try Data(contentsOf: retryDestination.appendingPathComponent("download.iso")) == bytes)
        print("PASS: unavailable source fails safely; Retry succeeds when the mapped file returns")
        try clear()

        let torrentFile = home.appendingPathComponent("auto.torrent")
        try Data("fixture torrent".utf8).write(to: torrentFile)
        row["percentDone"] = 0.5
        ConfirmationRPC.setCopyRow(row)
        check(await add(kept, file: torrentFile))
        try await settle()
        check(ConfirmationRPC.submissions.last?["metainfo"] as? String == Data("fixture torrent".utf8).base64EncodedString())
        changed = server
        changed.pathMappings = [PathMapping(remotePath: "/downloads", localPath: "/changed-mapping")]
        model.servers = [changed]
        await model.refresh()
        try await settle()
        check(model.autoCopyJobs[0].state == .failed)
        check(ConfirmationRPC.removed.count == failedRemoveCount)
        let job = model.autoCopyJobs[0]
        model.dismissAutoCopy(job)
        check(model.autoCopyJobs.isEmpty)
        check(FileManager.default.fileExists(atPath: source.appendingPathComponent("download.iso").path))
        print("PASS: .torrent files use the same queue; changed mappings fail closed; dismissing jobs preserves files")
        model.disconnect()
        ConfirmationRPC.setCopyRow(nil)
    }
}
