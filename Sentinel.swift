import Cocoa
import WebKit

class SentinelWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: SentinelWindow!
    var webView: WKWebView!
    var statusItem: NSStatusItem!
    var serverProcess: Process?
    var watchTimer: Timer?

    // Native drag tracking — avoids relying on isMovableByWindowBackground which
    // WKWebView blocks by consuming all mouse events before they reach the window.
    var dragStartScreenPos: NSPoint?
    var windowOriginAtDragStart: NSPoint?
    var localEventMonitors: [Any] = []

    // Project directory: computed relative to the executable so it works on any machine.
    // Executable lives at: <project>/GeminiSentinel.app/Contents/MacOS/GeminiSentinel
    // Walking up three levels gives the project root.
    var sentinelDir: String {
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0])
        return execURL
            .deletingLastPathComponent()  // MacOS/
            .deletingLastPathComponent()  // Contents/
            .deletingLastPathComponent()  // GeminiSentinel.app/
            .deletingLastPathComponent()  // project root
            .path
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupStatusItem()
        setupWindow()
        setupDragMonitor()

        // Start server and watch — restart if it goes down, poll for approvals
        startServerIfNeeded()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.startServerIfNeeded()
            self?.checkForApproval()
        }
    }

    // MARK: – Status bar item with Show/Hide/Quit menu

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "♊️"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Mascot",  action: #selector(showMascot),  keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hide Mascot",  action: #selector(hideMascot),  keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Restart Server", action: #selector(restartServer), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Sentinel", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func showMascot() { window.orderFront(nil) }
    @objc func hideMascot() { window.orderOut(nil) }
    @objc func restartServer() {
        serverProcess?.terminate()
        serverProcess = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.startServerIfNeeded() }
    }
    @objc func quitApp() { NSApp.terminate(nil) }

    // MARK: – Floating window setup

    func setupWindow() {
        let width: CGFloat = 400
        let height: CGFloat = 200
        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let rect = NSRect(x: screenRect.minX + 20,
                          y: screenRect.minY + 20,
                          width: width, height: height)

        window = SentinelWindow(contentRect: rect,
                                styleMask: [.borderless],
                                backing: .buffered, defer: false)
        window.delegate = self
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Drag is handled via event monitors below; isMovableByWindowBackground
        // does not work reliably because WKWebView consumes all mouse events.
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.alphaValue = 1.0
        window.hidesOnDeactivate = false

        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(webView)

        let dir = sentinelDir
        let url = URL(fileURLWithPath: "\(dir)/index.html")
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        window.orderFront(nil)
        // Do NOT activate — we never steal focus from the user's active app
    }

    // MARK: – NSWindowDelegate: closing the window hides it (app stays in menubar)

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        return false
    }

    // MARK: – Native drag via NSEvent local monitors
    // Intercepts mouse events at the app level, before WKWebView sees them,
    // so dragging anywhere on the mascot reliably moves the floating window.

    func setupDragMonitor() {
        // Record the initial mouse position and window origin on mouse down.
        // Guard on event.window so we only drag our own floating window.
        let downMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            self.dragStartScreenPos = NSEvent.mouseLocation
            self.windowOriginAtDragStart = self.window.frame.origin
            return event
        }

        // Move the window by the delta between current and start positions.
        let dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self = self,
                  let start = self.dragStartScreenPos,
                  let origin = self.windowOriginAtDragStart else { return event }
            let cur = NSEvent.mouseLocation
            let newOrigin = NSPoint(x: origin.x + (cur.x - start.x),
                                    y: origin.y + (cur.y - start.y))
            self.window.setFrameOrigin(newOrigin)
            return event
        }

        // Clear drag state on mouse up.
        let upMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.dragStartScreenPos = nil
            self?.windowOriginAtDragStart = nil
            return event
        }

        localEventMonitors = [downMonitor, dragMonitor, upMonitor].compactMap { $0 }
    }

    // MARK: – Server lifecycle

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
        let dir = sentinelDir
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["node", "\(dir)/server.js"]
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        let logURL = URL(fileURLWithPath: "\(dir)/server.log")
        // Create log file if it doesn't exist so FileHandle can open it
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            logHandle.seekToEndOfFile()
            process.standardOutput = logHandle
            process.standardError  = logHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError  = FileHandle.nullDevice
        }
        try? process.run()
        serverProcess = process
    }

    // MARK: – Approval polling

    func checkForApproval() {
        guard let url = URL(string: "http://localhost:49152/state") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessions = json["sessions"] as? [String: Any] else { return }
            let needsApproval = sessions.values.compactMap { $0 as? [String: Any] }
                .contains { ($0["status"] as? String) == "needs_approval" }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if needsApproval {
                    // Float above VS Code and steal focus only when approval is needed
                    self.window.level = .screenSaver
                    self.window.orderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    self.window.level = .floating
                }
            }
        }.resume()
    }

    // MARK: – App lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Stay alive in the menubar after the floating window is hidden
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        watchTimer?.invalidate()
        localEventMonitors.forEach { NSEvent.removeMonitor($0) }
        serverProcess?.terminate()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No Dock icon, menubar-only presence
// Must be a global — NSApplication.delegate is weak, a local var gets deallocated
let delegate = AppDelegate()
app.delegate = delegate
app.run()
