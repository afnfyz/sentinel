import Cocoa
import WebKit

class SentinelWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, WKScriptMessageHandler {
    var window: SentinelWindow!
    var webView: WKWebView!
    var statusItem: NSStatusItem!
    var serverProcess: Process?
    var watchTimer: Timer?
    var bgTimer: Timer?
    var dragStart: NSPoint?
    var _checkingServer = false

    let sentinelDir: String = {
        let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        // If launched as .app bundle, go up one level to project root
        if url.pathExtension == "app" {
            return url.deletingLastPathComponent().path
        }
        // If launched as bare binary (e.g. swiftc output), bundlePath is the binary itself
        return url.deletingLastPathComponent().path
    }()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupStatusBar()
        setupWindow()
        setupDrag()
        startServerIfNeeded()
        // Only check server liveness periodically — approval state
        // is pushed from JS via WKScriptMessageHandler (instant, no polling)
        watchTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .background).async {
                self?.startServerIfNeeded()
            }
        }
        // Sample the screen behind the mascot to adapt text color
        bgTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateTextColorFromBackground()
        }
    }

    // MARK: – Status bar

    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // SF Symbol eye — represents "watching your agents"
            if let img = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "Sentinel") {
                img.size = NSSize(width: 16, height: 16)
                img.isTemplate = true   // adapts to light/dark menu bar
                button.image = img
            } else {
                button.title = "👁"
            }
            button.action = #selector(statusBarClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc func statusBarClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            // Left click — toggle window visibility
            if window.isVisible {
                window.orderOut(nil)
            } else {
                window.orderFront(nil)
            }
        }
    }

    func showMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let toggleItem = NSMenuItem(
            title: window.isVisible ? "Hide Sentinel" : "Show Sentinel",
            action: #selector(toggleWindow),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Sentinel", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // remove so next left-click is handled by action
    }

    @objc func toggleWindow() {
        if window.isVisible { window.orderOut(nil) } else { window.orderFront(nil) }
    }

    @objc func quitApp() {
        serverProcess?.terminate()
        serverProcess?.waitUntilExit()  // give server time to flush state.json
        NSApp.terminate(nil)
    }

    // MARK: – Window

    func setupWindow() {
        let width: CGFloat = 300
        let height: CGFloat = 400
        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let rect = NSRect(
            x: screenRect.maxX - width - 20,
            y: screenRect.minY + 20,
            width: width, height: height
        )

        window = SentinelWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = false  // we handle drag manually
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.alphaValue = 1.0
        window.hidesOnDeactivate = false

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()  // no caching — always load fresh HTML
        // Register JS→Swift bridge for instant approval state notifications
        config.userContentController.add(self, name: "sentinel")
        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(webView)

        // Load from the Express server — avoids file:// CORS issues with
        // EventSource and fetch to localhost. Falls back to file:// if server
        // isn't ready yet (the 3s watchTimer will reload once it's up).
        let serverURL = URL(string: "http://localhost:49152/index.html")!
        webView.load(URLRequest(url: serverURL, cachePolicy: .reloadIgnoringLocalCacheData))

        window.orderFront(nil)
    }

    // MARK: – Drag (pan gesture on the WKWebView)

    func setupDrag() {
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        // Low priority so WKWebView button clicks still fire first
        pan.delaysPrimaryMouseButtonEvents = false
        webView.addGestureRecognizer(pan)
    }

    @objc func handlePan(_ gr: NSPanGestureRecognizer) {
        let loc = gr.location(in: nil)   // location in window coords
        switch gr.state {
        case .began:
            let screenLoc = window.convertPoint(toScreen: loc)
            dragStart = NSPoint(
                x: screenLoc.x - window.frame.origin.x,
                y: screenLoc.y - window.frame.origin.y
            )
        case .changed:
            guard let offset = dragStart else { return }
            // Require 10px of movement before engaging drag, so taps don't move window
            let translation = gr.translation(in: nil)
            if abs(translation.x) < 10 && abs(translation.y) < 10 { return }
            let screenLoc = window.convertPoint(toScreen: loc)
            let newOrigin = NSPoint(
                x: screenLoc.x - offset.x,
                y: screenLoc.y - offset.y
            )
            window.setFrameOrigin(newOrigin)
        case .ended, .cancelled, .failed:
            dragStart = nil
        default:
            break
        }
    }

    // MARK: – Server

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
        guard !_checkingServer else { return }
        _checkingServer = true
        defer { _checkingServer = false }

        guard !isServerRunning() else { return }
        print("[Sentinel] Server not running — starting...")
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["node", "\(sentinelDir)/server.js"]
        process.currentDirectoryURL = URL(fileURLWithPath: sentinelDir)
        let logURL = URL(fileURLWithPath: "\(sentinelDir)/server.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice
        do {
            try process.run()
            serverProcess = process
        } catch {
            print("[Sentinel] Failed to start server: \(error)")
        }
    }

    // MARK: – Adaptive text color

    func updateTextColorFromBackground() {
        guard window.isVisible else { return }
        // Use the system appearance (light/dark mode) — no screen capture permissions needed
        let appearance = NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = isDark ? "rgba(255,255,255,0.4)" : "rgba(0,0,0,0.55)"
        webView.evaluateJavaScript("document.documentElement.style.setProperty('--name-color', '\(color)')")
    }

    // MARK: – WKScriptMessageHandler (JS→Swift bridge)

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let needsApproval = body["needsApproval"] as? Bool else { return }
        DispatchQueue.main.async {
            if needsApproval {
                self.window.level = .screenSaver
                self.window.orderFrontRegardless()
            } else {
                self.window.level = .floating
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        watchTimer?.invalidate()
        bgTimer?.invalidate()
        serverProcess?.terminate()
        serverProcess?.waitUntilExit()  // flush state.json before exit
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
