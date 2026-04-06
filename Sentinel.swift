import Cocoa
import WebKit

class SentinelWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: SentinelWindow!
    var webView: WKWebView!
    var statusItem: NSStatusItem!
    var serverProcess: Process?
    var watchTimer: Timer?
    var dragStart: NSPoint?
    var _checkingServer = false
    var _wasNeedsApproval = false   // tracks previous approval state to fire activate only once

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
        watchTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .background).async {
                self?.startServerIfNeeded()
            }
            self?.checkForApproval()
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
        let height: CGFloat = 280
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
        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(webView)

        let htmlPath = "\(sentinelDir)/index.html"
        webView.loadFileURL(
            URL(fileURLWithPath: htmlPath),
            allowingReadAccessTo: URL(fileURLWithPath: sentinelDir)
        )

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

    func checkForApproval() {
        guard let url = URL(string: "http://localhost:49152/state") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessions = json["sessions"] as? [String: Any] else { return }
            let needsApproval = sessions.values.compactMap { $0 as? [String: Any] }
                .contains { ($0["status"] as? String) == "needs_approval" }
            DispatchQueue.main.async {
                if needsApproval {
                    // Raise to screenSaver level so the mascot floats above everything
                    self.window.level = .screenSaver
                    // orderFrontRegardless ensures the window appears even when
                    // Sentinel is not the active app — without stealing keyboard
                    // focus from whatever the user is working in (e.g. Safari, Figma).
                    // This avoids the "double approval" problem where NSApp.activate
                    // would yank focus to VSCode, making the user think they need
                    // to approve again in the Claude Code UI.
                    self.window.orderFrontRegardless()
                    self._wasNeedsApproval = true
                } else {
                    self.window.level = .floating
                    self._wasNeedsApproval = false
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
        serverProcess?.waitUntilExit()  // flush state.json before exit
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
