import Foundation

/// A sidecar folder (named "CaptureOne") found under the chosen root.
struct SidecarFolder: Identifiable, Sendable {
    let url: URL
    let fileCount: Int
    /// Files + directories, which is what `zip` reports one line for.
    let itemCount: Int
    let byteSize: Int64
    /// A zip from an earlier run is already next to it; zip will update it in place.
    let hasExistingArchive: Bool

    var id: URL { url }
}

enum Scanner {
    static let folderName = "CaptureOne"

    /// Synchronous so it can run on a detached task; returns early if that task is cancelled.
    static func scan(_ root: URL) -> [SidecarFolder] {
        if root.lastPathComponent == folderName {
            return [measure(root)]
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [SidecarFolder] = []
        for case let url as URL in enumerator {
            if Task.isCancelled { return [] }
            guard url.lastPathComponent == folderName,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { continue }
            found.append(measure(url))
            enumerator.skipDescendants()
        }
        return found.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    private static func measure(_ folder: URL) -> SidecarFolder {
        var files = 0, items = 1
        var bytes: Int64 = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) {
            for case let url as URL in enumerator {
                if Task.isCancelled { break }
                items += 1
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory != true {
                    files += 1
                    bytes += Int64(values?.fileSize ?? 0)
                }
            }
        }
        let archive = folder.deletingLastPathComponent().appendingPathComponent("\(folder.lastPathComponent).zip")
        return SidecarFolder(
            url: folder,
            fileCount: files,
            itemCount: items,
            byteSize: bytes,
            hasExistingArchive: FileManager.default.fileExists(atPath: archive.path)
        )
    }
}

enum Zipper {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Zips `folder` into `<folder>.zip` next to it, same as the original
    /// `cd parent && zip -r CaptureOne.zip CaptureOne`. Reports the number of
    /// entries added so far, and throws if zip fails or the archive doesn't test clean.
    static func zip(_ folder: URL, progress: @escaping @Sendable (Int) async -> Void) async throws -> URL {
        let parent = folder.deletingLastPathComponent()
        let name = folder.lastPathComponent
        let archive = parent.appendingPathComponent("\(name).zip")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = parent
        // -r: recurse, -T: verify the archive before reporting success
        process.arguments = ["-r", "-T", archive.lastPathComponent, name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        var count = 0
        var messages: [String] = []
        let box = ProcessBox(process)
        try await withTaskCancellationHandler {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("adding:") || trimmed.hasPrefix("updating:") {
                    count += 1
                    if count % 10 == 0 { await progress(count) }
                } else if !trimmed.isEmpty {
                    messages.append(trimmed)
                }
            }
        } onCancel: {
            box.stop()
        }
        process.waitUntilExit()
        await progress(count)

        // A zip that finished just before the cancel still counts as done.
        if process.terminationStatus != 0 && Task.isCancelled {
            throw CancellationError()
        }
        guard process.terminationStatus == 0 else {
            let detail = messages.last { $0.localizedCaseInsensitiveContains("error") } ?? messages.last
            throw Failure(message: detail ?? "zip exited with code \(process.terminationStatus)")
        }
        return archive
    }
}

/// Lets the cancellation handler (which may run on any thread) stop the zip process.
private final class ProcessBox: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) { self.process = process }

    /// SIGTERM lets zip clean up its temp file. The original folder and any earlier
    /// zip aren't touched until zip succeeds. If zip ignores SIGTERM, follow up with SIGKILL.
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
