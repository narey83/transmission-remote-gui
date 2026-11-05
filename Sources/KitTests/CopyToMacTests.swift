import Darwin
import Foundation
import TransmissionKit

private func copyTorrent(_ files: [(String, Int, Int)], wanted: [Bool]? = nil) throws -> Torrent {
    var json: [String: Any] = [
        "id": 1, "name": "Selected download", "hashString": String(repeating: "a", count: 40),
        "percentDone": 1, "downloadDir": "/remote", "status": 6,
        "files": files.map { ["name": $0.0, "length": $0.1, "bytesCompleted": $0.2] },
    ]
    if let wanted {
        json["fileStats"] = wanted.map { ["wanted": $0, "bytesCompleted": 0, "priority": 0] as [String: Any] }
    }
    return try JSONDecoder().decode(Torrent.self, from: JSONSerialization.data(withJSONObject: json))
}

private func copyFixture() throws -> (root: URL, source: URL, destination: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("trgui-copy-tests-" + UUID().uuidString)
    let source = root.appendingPathComponent("source")
    let destination = root.appendingPathComponent("destination")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    return (root, source, destination)
}

private func plan(_ torrent: Torrent, source: URL) throws -> LocalCopyPlan {
    try LocalCopyPlan(torrent: torrent, mappings: [PathMapping(remotePath: "/remote", localPath: source.path)])
}

func testCopyToMac(_ t: TestHarness) async {
    print("\nCopy completed files to this Mac")

    await t.test("Server cleanup verification compares all bytes and rejects altered or missing local files") {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bytes = Data(repeating: 42, count: 2 * 1024 * 1024 + 17)
        try bytes.write(to: fixture.source.appendingPathComponent("download.iso"))
        let manifest = try plan(copyTorrent([("download.iso", bytes.count, bytes.count)]), source: fixture.source)
        let result = try await CopyToMac.copy([manifest], to: fixture.destination)
        try await CopyToMac.verify(manifest, at: result[0])
        try Data(repeating: 43, count: bytes.count).write(to: result[0])
        var rejected = false
        do { try await CopyToMac.verify(manifest, at: result[0]) } catch {
            rejected = error as? CopyToMacError == .verificationFailed
        }
        try t.expect(rejected, "equal file sizes must not hide corrupt contents")
        try FileManager.default.removeItem(at: result[0])
        rejected = false
        do { try await CopyToMac.verify(manifest, at: result[0]) } catch { rejected = true }
        try t.expect(rejected, "missing local file must prevent cleanup")
    }

    await t.test("Verification rejects local symlinks and fresh source changes") {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.source.appendingPathComponent("a.txt")
        try Data("same".utf8).write(to: file)
        let manifest = try plan(copyTorrent([("a.txt", 4, 4)]), source: fixture.source)
        let result = try await CopyToMac.copy([manifest], to: fixture.destination)
        try FileManager.default.removeItem(at: result[0])
        try FileManager.default.createSymbolicLink(at: result[0], withDestinationURL: file)
        var rejected = false
        do { try await CopyToMac.verify(manifest, at: result[0]) } catch { rejected = true }
        try t.expect(rejected, "symlinks cannot stand in for a local copy")
        try FileManager.default.removeItem(at: result[0])
        try Data("same".utf8).write(to: result[0])
        try Data("edit".utf8).write(to: file)
        rejected = false
        do { try await CopyToMac.verify(manifest, at: result[0]) } catch { rejected = true }
        try t.expect(rejected, "current source bytes must match the local copy")
    }

    await t.test("Verification respects nested directories and numbered collision names") {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let folder = fixture.source.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("song".utf8).write(to: folder.appendingPathComponent("one"))
        try Data("song".utf8).write(to: folder.appendingPathComponent("two"))
        let manifest = try plan(copyTorrent([("Album/one", 4, 4), ("Album/two", 4, 4)]), source: fixture.source)
        _ = try await CopyToMac.copy([manifest], to: fixture.destination)
        let second = try await CopyToMac.copy([manifest], to: fixture.destination)
        try t.expectEqual(second[0].lastPathComponent, "Album (2)")
        try await CopyToMac.verify(manifest, at: second[0])
        let cancelled = Task {
            try await CopyToMac.verify(manifest, at: second[0])
        }
        cancelled.cancel()
        var stopped = false
        do { try await cancelled.value } catch is CancellationError { stopped = true }
        try t.expect(stopped, "cancellation prevents cleanup verification")
    }

    await t.test("Copy is offered only for completed, non-verifying torrents with a mapped location") {
        var ready = try copyTorrent([("video.mp4", 4, 4)])
        try t.expect(TorrentRowMenu.isEnabled(.copyToMac, for: [ready]), "ready torrent")
        ready.percentDone = 0.99
        try t.expect(!TorrentRowMenu.isEnabled(.copyToMac, for: [ready]), "incomplete torrent")
        ready.percentDone = 1
        ready.status = 2
        try t.expect(!TorrentRowMenu.isEnabled(.copyToMac, for: [ready]), "verification is not completion")
        try t.expect(!TorrentRowMenu.isVisible(.copyToMac, hasPathMappings: false), "no path mapping")
        try t.expect(TorrentRowMenu.isVisible(.copyToMac, hasPathMappings: true), "mapped share")
    }

    await t.test("Copy manifest preserves folders and excludes unwanted incomplete files") {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let torrent = try copyTorrent(
            [("Album/track.flac", 4, 4), ("Album/skipped.flac", 8, 0)], wanted: [true, false])
        let manifest = try plan(torrent, source: fixture.source)
        try t.expectEqual(manifest.name, "Album")
        try t.expect(manifest.isDirectory, "keep torrent folder")
        try t.expectEqual(manifest.files.count, 1)
        try t.expectEqual(manifest.files[0].components, ["track.flac"])
        try t.expectEqual(manifest.totalBytes, 4)
    }

    await t.test("Invalid metadata and traversal never produce a copy manifest") {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for files in [
            [("../secret", 4, 4)], [("/absolute", 4, 4)], [("a//b", 4, 4)],
            [("nul\0name", 4, 4)], [("negative", -1, 0)], [("a", 4, 3)],
            [("A.flac", 4, 4), ("a.flac", 4, 4)],
            [("A/one", 4, 4), ("a/two", 4, 4)],
            [("parent", 4, 4), ("parent/child", 4, 4)],
        ] {
            var rejected = false
            do { _ = try plan(copyTorrent(files), source: fixture.source) } catch { rejected = true }
            try t.expect(rejected, "invalid file list must be rejected")
        }
        var mismatch = try copyTorrent([("a", 4, 4)], wanted: [true, false])
        var rejected = false
        do { _ = try plan(mismatch, source: fixture.source) } catch { rejected = true }
        try t.expect(rejected, "fileStats must align with files")
        mismatch.percentDone = 0.5
        rejected = false
        do { _ = try plan(mismatch, source: fixture.source) } catch { rejected = true }
        try t.expect(rejected, "fresh completion is required")
    }

    await t.test("Copies exact bytes, preserves the source, and never includes unrelated share files") {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bytes = Data("complete download".utf8)
        try bytes.write(to: fixture.source.appendingPathComponent("video.mp4"))
        try Data("not selected".utf8).write(to: fixture.source.appendingPathComponent("other.txt"))
        let torrent = try copyTorrent([("video.mp4", bytes.count, bytes.count)])
        let result = try await CopyToMac.copy([plan(torrent, source: fixture.source)], to: fixture.destination)
        try t.expectEqual(result.count, 1)
        try t.expectEqual(try Data(contentsOf: result[0]), bytes)
        try t.expectEqual(try Data(contentsOf: fixture.source.appendingPathComponent("video.mp4")), bytes)
        try t.expectEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), ["video.mp4"])
    }

    await t.test("Rootless multi-file torrents get their own folder, without copying the entire mapped directory") {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for name in ["a.txt", "b.txt", "unrelated.txt"] {
            try Data("data".utf8).write(to: fixture.source.appendingPathComponent(name))
        }
        let torrent = try copyTorrent([("a.txt", 4, 4), ("b.txt", 4, 4)])
        let result = try await CopyToMac.copy([plan(torrent, source: fixture.source)], to: fixture.destination)
        try t.expectEqual(result[0].lastPathComponent, "Selected download")
        try t.expectEqual(Set(try FileManager.default.contentsOfDirectory(atPath: result[0].path)), ["a.txt", "b.txt"])
    }

    await t.test("Existing files and dangling symlinks are never overwritten") {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("new!".utf8).write(to: fixture.source.appendingPathComponent("video.mp4"))
        let existing = fixture.destination.appendingPathComponent("video.mp4")
        try Data("old!".utf8).write(to: existing)
        let dangling = fixture.destination.appendingPathComponent("video (2).mp4")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "/missing-copy-fixture")
        let torrent = try copyTorrent([("video.mp4", 4, 4)])
        let result = try await CopyToMac.copy([plan(torrent, source: fixture.source)], to: fixture.destination)
        try t.expectEqual(result[0].lastPathComponent, "video (3).mp4")
        try t.expectEqual(try Data(contentsOf: existing), Data("old!".utf8))
        try t.expectEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path), "/missing-copy-fixture")
    }

    await t.test("Source symlinks and symlinked parent directories cannot escape the mapped root") {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("outside.txt")
        try Data("data".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appendingPathComponent("link.txt"),
            withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appendingPathComponent("parent"),
            withDestinationURL: fixture.root)
        for name in ["link.txt", "parent/outside.txt"] {
            var rejected = false
            do {
                _ = try await CopyToMac.copy(
                    [plan(copyTorrent([(name, 4, 4)]), source: fixture.source)], to: fixture.destination)
            } catch { rejected = true }
            try t.expect(rejected, "symlink source must not be followed")
        }
        try t.expectEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
    }

    await t.test("Special files are rejected without blocking; staging is removed") {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try t.expectEqual(mkfifo(fixture.source.appendingPathComponent("pipe").path, 0o600), 0)
        var rejected = false
        do {
            _ = try await CopyToMac.copy(
                [plan(copyTorrent([("pipe", 0, 0)]), source: fixture.source)], to: fixture.destination)
        } catch let failure as LocalCopyFailure {
            rejected = failure.underlying as? CopyToMacError == .notRegularFile
        }
        try t.expect(rejected, "FIFO is not downloadable file data")
        try t.expectEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
    }

    await t.test("Changed source sizes are rejected without publishing partial files") {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("short".utf8).write(to: fixture.source.appendingPathComponent("video"))
        var rejected = false
        do {
            _ = try await CopyToMac.copy(
                [plan(copyTorrent([("video", 10, 10)]), source: fixture.source)], to: fixture.destination)
        } catch let failure as LocalCopyFailure {
            rejected = failure.underlying as? CopyToMacError == .sourceChanged
        }
        try t.expect(rejected, "metadata must still match the source")
        try t.expectEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
    }

    await t.test("Cancellation removes partial staging and does not publish the torrent") {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.source.appendingPathComponent("large.bin")
        _ = FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        let size = 64 * 1024 * 1024
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        let manifest = try plan(copyTorrent([("large.bin", size, size)]), source: fixture.source)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CopyToMac.copy([manifest], to: fixture.destination)
        }
        var cancelled = false
        do { _ = try await task.value } catch let failure as LocalCopyFailure {
            cancelled = failure.underlying is CancellationError
        }
        try t.expect(cancelled, "cancelled request must not publish")
        try t.expectEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
    }

    await t.test("A later failure preserves earlier complete copies and reports their locations") {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("data".utf8).write(to: fixture.source.appendingPathComponent("first.txt"))
        let first = try plan(copyTorrent([("first.txt", 4, 4)]), source: fixture.source)
        let second = try plan(copyTorrent([("missing.txt", 4, 4)]), source: fixture.source)
        var completed: [URL] = []
        do { _ = try await CopyToMac.copy([first, second], to: fixture.destination) } catch let failure
            as LocalCopyFailure
        { completed = failure.completed }
        try t.expectEqual(completed.map(\.lastPathComponent), ["first.txt"])
        try t.expectEqual(try Data(contentsOf: completed[0]), Data("data".utf8))
        try t.expectEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), ["first.txt"])
    }

    await t.test("Zero-length files copy successfully") {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data().write(to: fixture.source.appendingPathComponent("empty.txt"))
        let manifest = try plan(copyTorrent([("empty.txt", 0, 0)]), source: fixture.source)
        let result = try await CopyToMac.copy([manifest], to: fixture.destination)
        try t.expectEqual(try Data(contentsOf: result[0]).count, 0)
    }

    await t.test("Local copies remain private and retain the executable bit") {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.source.appendingPathComponent("executable")
        try Data("data".utf8).write(to: source)
        try t.expectEqual(chmod(source.path, 0o777), 0)
        let result = try await CopyToMac.copy(
            [plan(copyTorrent([("executable", 4, 4)]), source: fixture.source)], to: fixture.destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: result[0].path)
        try t.expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    await t.test("Concurrent copies choose distinct output names atomically") {
        let fixture = try copyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("data".utf8).write(to: fixture.source.appendingPathComponent("same.txt"))
        let manifest = try plan(copyTorrent([("same.txt", 4, 4)]), source: fixture.source)
        async let first = CopyToMac.copy([manifest], to: fixture.destination)
        async let second = CopyToMac.copy([manifest], to: fixture.destination)
        let results = try await (first, second)
        try t.expectEqual(Set((results.0 + results.1).map(\.lastPathComponent)), ["same.txt", "same (2).txt"])
    }
}
