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

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // 1. Create Menu Bar Icon (Prevents app from being killed easily)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "♊️"
        }

        // 2. Setup Window (Top-Right, Transparent, Always on Top)
        let width: CGFloat = 850
        let height: CGFloat = 400
        
        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let rect = NSRect(x: screenRect.width - width - 20, 
                        y: screenRect.height - height - 20, 
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

        // 3. Setup WebView
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.setValue(false, forKey: "drawsBackground") // Transparent background
        webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(webView)
        
        // 4. Load HTML
        let path = "/Users/afnan_dfx/projects/gemini-sentinel/index.html"
        let url = URL(fileURLWithPath: path)
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No Dock icon, but stays active
// Must be a global — NSApplication.delegate is weak, a local var gets deallocated
let delegate = AppDelegate()
app.delegate = delegate
app.run()
