import Cocoa
import WebKit

class SentinelWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: SentinelWindow!
    var webView: WKWebView!
    var statusItem: NSStatusItem!
    var serverProcess: Process?
    var watchTimer: Timer?

    let sentinelDir = "/Users/afnan_dfx/projects/gemini-sentinel"

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "♊️"
        }

        let width: CGFloat = 400
        let height: CGFloat = 200
        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let rect = NSRect(x: screenRect.minX + 20,
                        y: screenRect.minY + 20,
                        width: width, height: height)

        window = SentinelWindow(contentRect: rect,
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.alphaValue = 1.0
        window.hidesOnDeactivate = false

        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(webView)

        let path = "\(sentinelDir)/index.html"
        let url = URL(fileURLWithPath: path)
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Start server and watch it — restart if it goes down, poll for approvals
        startServerIfNeeded()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.startServerIfNeeded()
            self?.checkForApproval()
        }
    }

    func isServerRunning() -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/curl"
        task.arguments = ["-s", "--max-time", "1", "http://localhost:49152/state"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    func startServerIfNeeded() {
        guard !isServerRunning() else { return }
        print("[Sentinel] Server not running — starting...")
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["node", "\(sentinelDir)/server.js"]
        process.currentDirectoryURL = URL(fileURLWithPath: sentinelDir)
        let logURL = URL(fileURLWithPath: "\(sentinelDir)/server.log")
        let logHandle = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice
        try? process.run()
        serverProcess = process
    }

    func checkForApproval() {
        guard let url = URL(string: "http://localhost:49152/state") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessions = json["sessions"] as? [String: Any] else { return }
            let needsApproval = sessions.values.compactMap { $0 as? [String: Any] }
                .contains { ($0["status"] as? String) == "needs_approval" }
            if needsApproval {
                DispatchQueue.main.async {
                    self?.window.level = .screenSaver  // float above everything including VS Code
                    self?.window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            } else {
                DispatchQueue.main.async {
                    self?.window.level = .floating
                }
            }
        }.resume()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        watchTimer?.invalidate()
        serverProcess?.terminate()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No Dock icon, but stays active
// Must be a global — NSApplication.delegate is weak, a local var gets deallocated
let delegate = AppDelegate()
app.delegate = delegate
app.run()
