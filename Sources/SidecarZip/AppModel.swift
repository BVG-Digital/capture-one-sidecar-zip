import AppKit
import Foundation
import Observation

enum ZipStatus: Equatable {
    case pending
    case zipping(done: Int)
    case zipped(archiveSize: Int64)
    /// `archive` is set when zipping succeeded but removing the original failed,
    /// so a retry only needs to redo the removal.
    case failed(String, archive: URL? = nil)
}

enum AfterZip: String, CaseIterable, Identifiable {
    case delete, trash, keep
    var id: String { rawValue }

    var label: String {
        switch self {
        case .delete: "Delete originals"
        case .trash: "Move originals to Trash"
        case .keep: "Keep originals"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    enum Phase { case idle, scanning, ready, running, finished }

    private(set) var root: URL?
    private(set) var folders: [SidecarFolder] = []
    private(set) var status: [URL: ZipStatus] = [:]
    private(set) var phase: Phase = .idle
    private(set) var wasCancelled = false
    private var scanTask: Task<[SidecarFolder], Never>?
    private var runTask: Task<Void, Never>?
    private(set) var elapsed: Duration?
    private var runSet: [SidecarFolder] = []

    var afterZip: AfterZip = AfterZip(rawValue: UserDefaults.standard.string(forKey: "afterZip") ?? "") ?? .delete {
        didSet { UserDefaults.standard.set(afterZip.rawValue, forKey: "afterZip") }
    }

    // MARK: Derived state

    var isBusy: Bool { phase == .scanning || phase == .running }
    var remaining: [SidecarFolder] { folders.filter { !isZipped($0) } }
    var failed: [SidecarFolder] { folders.filter { isFailed($0) } }
    var zippedCount: Int { folders.count { isZipped($0) } }
    var failedCount: Int { failed.count }
    var totalBytes: Int64 { folders.reduce(0) { $0 + $1.byteSize } }

    /// Overall progress across the folders in the current (or last) run.
    var runProgress: Double {
        let total = runSet.reduce(0) { $0 + $1.itemCount }
        guard total > 0 else { return 0 }
        let done = runSet.reduce(0) { sum, folder in
            switch status[folder.url] {
            case .zipping(let n): sum + min(n, folder.itemCount)
            case .zipped, .failed: sum + folder.itemCount
            default: sum
            }
        }
        return Double(done) / Double(total)
    }

    var runFinishedCount: Int {
        runSet.count { folder in
            switch status[folder.url] {
            case .zipped, .failed: true
            default: false
            }
        }
    }

    var runCount: Int { runSet.count }

    func isZipped(_ folder: SidecarFolder) -> Bool {
        if case .zipped = status[folder.url] { true } else { false }
    }

    func isFailed(_ folder: SidecarFolder) -> Bool {
        if case .failed = status[folder.url] { true } else { false }
    }

    func displayName(for folder: SidecarFolder) -> String {
        guard let root else { return folder.url.path }
        let parent = folder.url.deletingLastPathComponent().path
        if folder.url == root { return parent }
        let relative = parent.dropFirst(root.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? root.lastPathComponent : "\(root.lastPathComponent)/\(relative)"
    }

    /// Plain-text summary of the last run, for pasting into a message or notes.
    var report: String {
        var lines = ["Sidecar Zip: \(root?.path ?? "")", ""]
        for folder in folders {
            let path = folder.url.path
            switch status[folder.url] ?? .pending {
            case .zipped(let size):
                lines.append("✓ \(path) (\(folder.fileCount) files → \(size.formatted(.byteCount(style: .file))))")
            case .failed(let message, _):
                lines.append("✗ \(path): \(message)")
            case .pending, .zipping:
                lines.append("· \(path) (not zipped)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Actions

    func open(_ url: URL) {
        guard !isBusy else { return }
        root = url
        rescan()
    }

    func rescan() {
        guard let root, !isBusy else { return }
        phase = .scanning
        folders = []
        status = [:]
        runSet = []
        elapsed = nil
        wasCancelled = false
        let task = Task.detached(priority: .userInitiated) { Scanner.scan(root) }
        scanTask = task
        Task {
            let found = await task.value
            guard scanTask == task else { return }
            scanTask = nil
            folders = found
            phase = .ready
        }
    }

    func zipAll() { run(remaining) }
    func retryFailed() { run(failed) }
    func retry(_ folder: SidecarFolder) { run([folder]) }

    /// Cancels a scan (back to the start screen) or a zip run (kills the current zip right away).
    func cancel() {
        switch phase {
        case .scanning:
            scanTask?.cancel()
            scanTask = nil
            root = nil
            phase = .idle
        case .running:
            wasCancelled = true
            runTask?.cancel()
        default:
            break
        }
    }

    private func run(_ batch: [SidecarFolder]) {
        guard !isBusy, !batch.isEmpty else { return }
        runSet = batch
        phase = .running
        wasCancelled = false
        let clock = ContinuousClock()
        let start = clock.now
        // Keep the Mac from idle-sleeping during long runs.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Zipping CaptureOne folders"
        )

        runTask = Task {
            for folder in batch {
                if Task.isCancelled { break }
                await process(folder)
            }
            runTask = nil
            ProcessInfo.processInfo.endActivity(activity)
            // Folders skipped by Cancel drop out of the run.
            runSet.removeAll { status[$0.url] == .pending || status[$0.url] == nil }
            elapsed = clock.now - start
            phase = .finished
            announceFinished()
        }
    }

    private func process(_ folder: SidecarFolder) async {
        var archive: URL?
        if case .failed(_, let zipped?) = status[folder.url] {
            archive = zipped
        }
        do {
            if archive == nil {
                status[folder.url] = .zipping(done: 0)
                archive = try await Zipper.zip(folder.url) { n in
                    await self.setProgress(n, for: folder.url)
                }
            }
            guard let archive else { return }
            do {
                try removeOriginal(folder.url)
            } catch {
                status[folder.url] = .failed(
                    "Zipped, but couldn't remove the folder: \(error.localizedDescription)",
                    archive: archive
                )
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 0
            status[folder.url] = .zipped(archiveSize: size)
        } catch is CancellationError {
            status[folder.url] = .pending
        } catch {
            status[folder.url] = .failed(error.localizedDescription)
        }
    }

    private func setProgress(_ n: Int, for url: URL) {
        if case .zipping = status[url] { status[url] = .zipping(done: n) }
    }

    private func removeOriginal(_ url: URL) throws {
        // Already gone (e.g. removed by hand before a retry) counts as done.
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        switch afterZip {
        case .delete: try FileManager.default.removeItem(at: url)
        case .trash: try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        case .keep: break
        }
    }

    private func announceFinished() {
        guard !wasCancelled else { return }
        NSSound(named: failedCount > 0 ? "Basso" : "Glass")?.play()
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }
}
