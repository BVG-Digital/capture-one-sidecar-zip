import AppKit
import SwiftUI

@main
struct SidecarZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Sidecar Zip", id: "main") {
            ContentView(model: appDelegate.model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 600, height: 500)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` (outside an .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Folders dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { model.open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.phase == .running else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Zipping is still in progress"
        alert.informativeText = "If you quit now, the current zip is stopped and its folder is left untouched. The remaining folders won't be zipped."
        alert.addButton(withTitle: "Keep Zipping")
        alert.addButton(withTitle: "Quit Anyway")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        model.cancel()  // stops the running zip so it doesn't outlive the app
        return .terminateNow
    }
}
