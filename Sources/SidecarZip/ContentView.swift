import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.root != nil {
                header
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.root != nil {
                Divider()
                footer
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.hasDirectoryPath || url.isDirectory, !model.isBusy else { return false }
            model.open(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.root?.lastPathComponent ?? "")
                    .font(.headline)
                Text(model.root?.path ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Rescan", systemImage: "arrow.clockwise", action: model.rescan)
                .labelStyle(.iconOnly)
                .help("Scan the folder again")
            Button("Choose…", action: chooseFolder)
        }
        .disabled(model.isBusy)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if model.root == nil {
            emptyState
        } else if model.phase == .scanning {
            VStack(spacing: 14) {
                ProgressView("Looking for CaptureOne folders…")
                Button("Cancel", action: model.cancel)
                    .keyboardShortcut(.cancelAction)
            }
        } else if model.folders.isEmpty {
            ContentUnavailableView(
                "No CaptureOne Folders",
                systemImage: "checkmark.circle",
                description: Text("Nothing to zip in this folder.")
            )
        } else {
            List(model.folders) { folder in
                FolderRow(
                    name: model.displayName(for: folder),
                    folder: folder,
                    status: model.status[folder.url] ?? .pending,
                    canRetry: !model.isBusy,
                    onRetry: { model.retry(folder) }
                )
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "archivebox")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop a folder here")
                .font(.title3.weight(.semibold))
            Text("Every CaptureOne sidecar folder inside it gets zipped in place.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Folder…", action: chooseFolder)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(40)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.phase == .running || (model.phase == .finished && model.runCount > 0) {
                ProgressView(value: model.runProgress)
                    .animation(.default, value: model.runProgress)
            }
            HStack(spacing: 12) {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(model.phase == .finished && model.failedCount > 0 ? .red : .secondary)
                Spacer()
                Picker("After zipping", selection: $model.afterZip) {
                    ForEach(AfterZip.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(model.isBusy)
                .help("What to do with each CaptureOne folder once its zip is verified")

                if model.phase == .running {
                    Button(model.wasCancelled ? "Cancelling…" : "Cancel", action: model.cancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.wasCancelled)
                        .help("Stop zipping now (Esc). The folder being zipped is left untouched.")
                } else {
                    if model.phase == .finished {
                        Button("Copy Report", systemImage: "doc.on.clipboard", action: copyReport)
                            .labelStyle(.iconOnly)
                            .help("Copy a summary of this run")
                    }
                    if model.phase == .finished && model.failedCount > 0 {
                        Button("Retry \(model.failedCount) Failed", action: model.retryFailed)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(zipButtonTitle, action: model.zipAll)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.isBusy || model.remaining.isEmpty)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Text

    private var zipButtonTitle: String {
        let n = model.remaining.count
        if n == 0 && !model.folders.isEmpty { return "All Zipped" }
        if model.phase == .finished && n > 0 { return "Zip \(n) Remaining" }
        return n == 1 ? "Zip 1 Folder" : "Zip \(n) Folders"
    }

    private var summary: String {
        switch model.phase {
        case .idle, .scanning:
            return ""
        case .ready:
            let n = model.folders.count
            return n == 0 ? "" : "\(n) folder\(n == 1 ? "" : "s") · \(model.totalBytes.formatted(.byteCount(style: .file)))"
        case .running:
            return "Zipping \(min(model.runFinishedCount + 1, model.runCount)) of \(model.runCount)…"
        case .finished:
            var parts = model.wasCancelled ? ["Cancelled"] : []
            parts.append("\(model.zippedCount) zipped")
            if model.failedCount > 0 { parts.append("\(model.failedCount) failed") }
            let left = model.remaining.count - model.failedCount
            if left > 0 { parts.append("\(left) not started") }
            if let elapsed = model.elapsed, elapsed >= .seconds(1) {
                parts.append(elapsed.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))
            }
            return parts.joined(separator: " · ")
        }
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.report, forType: .string)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to search for CaptureOne folders"
        if panel.runModal() == .OK, let url = panel.url {
            model.open(url)
        }
    }
}

private struct FolderRow: View {
    let name: String
    let folder: SidecarFolder
    let status: ZipStatus
    let canRetry: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.head)
                detail
                    .font(.caption)
            }
            Spacer()
            switch status {
            case .zipping(let done):
                ProgressView(value: Double(min(done, folder.itemCount)), total: Double(folder.itemCount))
                    .frame(width: 90)
            case .failed:
                Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                    .controlSize(.small)
                    .disabled(!canRetry)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Show in Finder") {
                let parent = folder.url.deletingLastPathComponent()
                NSWorkspace.shared.activateFileViewerSelecting([parent])
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .zipping:
            ProgressView().controlSize(.small)
        case .zipped:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var detail: some View {
        let size = folder.byteSize.formatted(.byteCount(style: .file))
        switch status {
        case .pending:
            HStack(spacing: 6) {
                Text("\(folder.fileCount) files · \(size)").foregroundStyle(.secondary)
                if folder.hasExistingArchive {
                    Text("Will update existing \(folder.url.lastPathComponent).zip")
                        .foregroundStyle(.orange)
                }
            }
        case .zipping(let done):
            Text("Zipping \(min(done, folder.itemCount)) of \(folder.itemCount) items…").foregroundStyle(.secondary)
        case .zipped(let archiveSize):
            Text("\(folder.fileCount) files → \(folder.url.lastPathComponent).zip (\(archiveSize.formatted(.byteCount(style: .file))))")
                .foregroundStyle(.secondary)
        case .failed(let message, _):
            Text(message)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }
}

private extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
