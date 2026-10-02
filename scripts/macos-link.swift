import AppKit

// A small Launch Services receiver. Keep the main Rust launcher unchanged;
// it owns the app lock and delivers choices to an already running host.
final class LinkReceiver: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--register") { NSApp.terminate(nil) }
        // No URL (for example a direct Finder launch) must not leave a helper open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { NSApp.terminate(nil) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.last, url.scheme == "gamenight", url.host == "play" else {
            NSApp.terminate(nil); return
        }
        let contents = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = contents.appendingPathComponent("MacOS/GameNight")
        process.arguments = ["--open-url", url.absoluteString]
        do { try process.run() } catch { NSLog("GameNight could not open: %@", error.localizedDescription) }
        NSApp.terminate(nil)
    }
}
let app = NSApplication.shared
let receiver = LinkReceiver()
app.delegate = receiver
app.setActivationPolicy(.prohibited)
app.run()
