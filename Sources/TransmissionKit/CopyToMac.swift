import Darwin
import Foundation

public enum CopyToMacError: Error, Equatable, Sendable {
    case incomplete
    case invalidFiles
    case noFiles
    case sourceChanged
    case notRegularFile
    case localDestinationRequired
    case alreadyCopying
    case verificationFailed
    case allFilesRequired
}

public struct LocalCopyFile: Sendable {
    public let source: MappedPath
    public let components: [String]
    public let size: Int64
}

/// An exact file manifest: copying a torrent must never enumerate the share or include
/// unrelated files beside a torrent with no enclosing directory.
public struct LocalCopyPlan: Sendable {
    public let name: String
    public let isDirectory: Bool
    public let files: [LocalCopyFile]
    public let totalBytes: Int64

    public init(torrent: Torrent, mappings: [PathMapping]) throws {
        guard torrent.percentDone == 1, torrent.statusValue != .verifying,
            torrent.statusValue != .queuedToVerify
        else { throw CopyToMacError.incomplete }
        guard let allFiles = torrent.files, !allFiles.isEmpty,
            let directory = torrent.downloadDir.flatMap(PathMapping.absolutePath)
        else {
            throw CopyToMacError.invalidFiles
        }
        let stats = torrent.fileStats
        if let stats, stats.count != allFiles.count { throw CopyToMacError.invalidFiles }
        let selected = allFiles.enumerated().filter { stats?[$0.offset].wanted ?? true }.map(\.element)
        guard !selected.isEmpty else { throw CopyToMacError.noFiles }
        var seen = Set<String>()
        let paths = try selected.map { file -> [String] in
            let parts = file.name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !parts.isEmpty, parts.allSatisfy(Self.validComponent), file.length >= 0,
                seen.insert(Self.folded(file.name)).inserted
            else { throw CopyToMacError.invalidFiles }
            guard file.bytesCompleted >= file.length else { throw CopyToMacError.incomplete }
            return parts
        }
        // Mac volumes may compare paths without case. Reject aliases and file/directory
        // conflicts instead of silently merging two different paths from the daemon.
        var nodes: [String: (spelling: String, directory: Bool)] = [:]
        for parts in paths {
            for count in 1...parts.count {
                let spelling = parts.prefix(count).joined(separator: "/")
                let key = Self.folded(spelling)
                let directory = count < parts.count
                if let previous = nodes[key], previous.spelling != spelling || previous.directory != directory {
                    throw CopyToMacError.invalidFiles
                }
                nodes[key] = (spelling, directory)
            }
        }
        let commonRoot = paths.allSatisfy { $0.count > 1 && $0.first == paths[0].first }
        let folder = commonRoot || paths.count > 1 || paths[0].count > 1
        isDirectory = folder
        if commonRoot {
            name = paths[0][0]
        } else if !isDirectory {
            name = paths[0][0]
        } else {
            name = Self.validComponent(torrent.displayName) ? torrent.displayName : "Torrent \(torrent.id)"
        }
        var bytes: Int64 = 0
        files = try zip(selected, paths).map { file, parts in
            let sum = bytes.addingReportingOverflow(Int64(file.length))
            guard !sum.overflow else { throw CopyToMacError.invalidFiles }
            bytes = sum.partialValue
            let remote = (directory == "/" ? "" : directory) + "/" + parts.joined(separator: "/")
            let source = try PathMapping.resolve(remote, using: mappings)
            return LocalCopyFile(
                source: source,
                components: commonRoot ? Array(parts.dropFirst()) : (folder ? parts : []),
                size: Int64(file.length))
        }
        totalBytes = bytes
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
            && !PathMapping.hasControlCharacters(value)
    }

    private static func folded(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }
}

public struct LocalCopyProgress: Sendable {
    public let copiedBytes: Int64
    public let totalBytes: Int64
    public let filename: String
}

/// Successful copies remain available if a later torrent fails or is cancelled.
public struct LocalCopyFailure: Error, Sendable {
    public let completed: [URL]
    public let underlying: any Error
}

public enum CopyToMac {
    /// Compare every byte again through safe file descriptors before server cleanup.
    /// This also detects local files removed/edited after the copy, or a changed manifest.
    public static func verify(_ plan: LocalCopyPlan, at output: URL) async throws {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            let values = try output.resourceValues(forKeys: [.volumeIsLocalKey])
            guard values.volumeIsLocal == true else { throw CopyToMacError.localDestinationRequired }
            for file in plan.files {
                try Task.checkCancellation()
                let local = file.components.reduce(output) { $0.appendingPathComponent($1) }
                let localLocation = MappedPath(url: local, localRoot: output.deletingLastPathComponent())
                let sourceFD = try openSource(file.source)
                let source = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
                defer { try? source.close() }
                let localFD = try openSource(localLocation)
                let target = FileHandle(fileDescriptor: localFD, closeOnDealloc: true)
                defer { try? target.close() }
                var sourceBefore = stat()
                var localBefore = stat()
                guard fstat(sourceFD, &sourceBefore) == 0, fstat(localFD, &localBefore) == 0,
                    sourceBefore.st_mode & S_IFMT == S_IFREG, localBefore.st_mode & S_IFMT == S_IFREG,
                    sourceBefore.st_size == file.size, localBefore.st_size == file.size
                else { throw CopyToMacError.verificationFailed }
                var remaining = file.size
                while remaining > 0 {
                    try Task.checkCancellation()
                    let count = Int(min(remaining, 1024 * 1024))
                    let bytes = try source.read(upToCount: count) ?? Data()
                    let copied = try target.read(upToCount: bytes.count) ?? Data()
                    guard !bytes.isEmpty, bytes == copied else { throw CopyToMacError.verificationFailed }
                    remaining -= Int64(bytes.count)
                }
                for (fd, before) in [(sourceFD, sourceBefore), (localFD, localBefore)] {
                    var after = stat()
                    guard fstat(fd, &after) == 0, before.st_size == after.st_size,
                        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
                    else { throw CopyToMacError.verificationFailed }
                }
            }
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public static func copy(
        _ plans: [LocalCopyPlan], to destination: URL,
        progress: @escaping @Sendable (LocalCopyProgress) -> Void = { _ in }
    ) async throws -> [URL] {
        let worker = Task.detached(priority: .userInitiated) {
            try perform(plans, to: destination, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func perform(
        _ plans: [LocalCopyPlan], to destination: URL,
        progress: @Sendable (LocalCopyProgress) -> Void
    ) throws -> [URL] {
        let manager = FileManager()
        let root = destination.resolvingSymlinksInPath().standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey])
        guard values.isDirectory == true, values.volumeIsLocal == true else {
            throw CopyToMacError.localDestinationRequired
        }
        var total: Int64 = 0
        for plan in plans {
            let sum = total.addingReportingOverflow(plan.totalBytes)
            guard !sum.overflow else { throw CopyToMacError.invalidFiles }
            total = sum.partialValue
        }
        guard !plans.isEmpty else { throw CopyToMacError.noFiles }
        var completed: [URL] = []
        var copied: Int64 = 0
        var lastUpdate = Date.distantPast
        do {
            for plan in plans {
                try Task.checkCancellation()
                let staging = root.appendingPathComponent(".transmission-copy-" + UUID().uuidString, isDirectory: true)
                try manager.createDirectory(
                    at: staging, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                // Only our private, unpublished staging directory is removed on failure.
                defer { try? manager.removeItem(at: staging) }
                let output = staging.appendingPathComponent(plan.name, isDirectory: plan.isDirectory)
                if plan.isDirectory {
                    try manager.createDirectory(at: output, withIntermediateDirectories: false)
                }
                for file in plan.files {
                    try Task.checkCancellation()
                    let target = file.components.reduce(output) { $0.appendingPathComponent($1) }
                    if plan.isDirectory {
                        try manager.createDirectory(
                            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    }
                    try copyFile(file, to: target) { bytes in
                        copied += bytes
                        let now = Date()
                        if now.timeIntervalSince(lastUpdate) >= 0.1 {
                            progress(
                                LocalCopyProgress(
                                    copiedBytes: copied, totalBytes: total,
                                    filename: file.source.url.lastPathComponent))
                            lastUpdate = now
                        }
                    }
                    progress(
                        LocalCopyProgress(
                            copiedBytes: copied, totalBytes: total,
                            filename: file.source.url.lastPathComponent))
                }
                try Task.checkCancellation()
                completed.append(try publish(output, named: plan.name, directory: plan.isDirectory, into: root))
            }
            return completed
        } catch {
            throw LocalCopyFailure(completed: completed, underlying: error)
        }
    }

    /// Walk from an open mapping root without following symlinks in any child component.
    /// This keeps untrusted daemon filenames inside the mapped share even during a rename.
    private static func openSource(_ location: MappedPath) throws -> Int32 {
        let rawRoot = location.localRoot.standardizedFileURL.path
        let rawPath = location.url.standardizedFileURL.path
        guard PathMapping.contains(rawPath, in: rawRoot), rawPath != rawRoot else {
            throw CopyToMacError.invalidFiles
        }
        let parts = rawPath.dropFirst(rawRoot == "/" ? 1 : rawRoot.count + 1).split(separator: "/").map(String.init)
        let root = location.localRoot.resolvingSymlinksInPath().path
        var directory = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw posixError() }
        defer { Darwin.close(directory) }
        for component in parts.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw posixError() }
            Darwin.close(directory)
            directory = next
        }
        let file = openat(directory, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw posixError() }
        return file
    }

    private static func copyFile(_ file: LocalCopyFile, to destination: URL, progress: (Int64) -> Void) throws {
        let sourceFD = try openSource(file.source)
        let source = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        defer { try? source.close() }
        var before = stat()
        guard fstat(sourceFD, &before) == 0 else { throw posixError() }
        guard before.st_mode & S_IFMT == S_IFREG else { throw CopyToMacError.notRegularFile }
        guard before.st_size == file.size else { throw CopyToMacError.sourceChanged }
        let outputFD = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outputFD >= 0 else { throw posixError() }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        var remaining = file.size
        while remaining > 0 {
            try Task.checkCancellation()
            let data = try source.read(upToCount: Int(min(remaining, 1024 * 1024))) ?? Data()
            guard !data.isEmpty else { throw CopyToMacError.sourceChanged }
            try output.write(contentsOf: data)
            remaining -= Int64(data.count)
            progress(Int64(data.count))
        }
        var after = stat()
        guard fstat(sourceFD, &after) == 0 else { throw posixError() }
        guard before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
        else { throw CopyToMacError.sourceChanged }
        // Keep the local copy private, while retaining the owner's executable bit.
        guard fchmod(outputFD, 0o600 | (before.st_mode & 0o100)) == 0 else { throw posixError() }
        try output.synchronize()
    }

    /// RENAME_EXCL is atomic: an existing file, folder or dangling symlink is never replaced.
    private static func publish(_ source: URL, named name: String, directory: Bool, into root: URL) throws -> URL {
        let original = URL(fileURLWithPath: name)
        let ext = directory ? "" : original.pathExtension
        let stem = ext.isEmpty ? name : original.deletingPathExtension().lastPathComponent
        for index in 1...10000 {
            try Task.checkCancellation()
            let candidate = index == 1 ? name : stem + " (\(index))" + (ext.isEmpty ? "" : "." + ext)
            let url = root.appendingPathComponent(candidate, isDirectory: directory)
            if renamex_np(source.path, url.path, UInt32(RENAME_EXCL)) == 0 { return url }
            guard errno == EEXIST else { throw posixError() }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
