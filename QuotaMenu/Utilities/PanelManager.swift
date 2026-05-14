import SwiftUI
import AppKit

final class PanelManager: ObservableObject {
    static let shared = PanelManager()
    @Published var isVisible = false
    private var panel: NSPanel?
    private var statusItem: NSStatusItem?

    func setStatusItem(_ item: NSStatusItem) { statusItem = item }

    func toggle<Content: View>(@ViewBuilder content: () -> Content) {
        if let panel, panel.isVisible {
            hide()
        } else {
            show(content: content)
        }
    }

    func show<Content: View>(@ViewBuilder content: () -> Content) {
        if let existing = panel, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let savedHeight = CGFloat(UserDefaults.standard.double(forKey: "panelHeight"))
        let height = savedHeight > 200 ? savedHeight : 520
        let width: CGFloat = 400

        let hostingView = NSHostingView(rootView: content())

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.title = "QuotaMenu"
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.isMovableByWindowBackground = true
        p.contentView = hostingView
        p.contentMinSize = NSSize(width: width, height: 300)
        p.contentMaxSize = NSSize(width: width, height: 1200)
        p.isReleasedWhenClosed = false
        p.delegate = PanelDelegate.shared

        positionPanel(p)
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = p
        isVisible = true
    }

    func hide() {
        if let panel {
            UserDefaults.standard.set(Double(panel.frame.height), forKey: "panelHeight")
            panel.orderOut(nil)
        }
        isVisible = false
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let button = statusItem?.button, let buttonWindow = button.window else {
            panel.center()
            return
        }

        let buttonFrame = buttonWindow.frame
        let panelFrame = panel.frame

        var x = buttonFrame.origin.x + buttonFrame.size.width / 2 - panelFrame.size.width / 2
        let y = buttonFrame.origin.y - panelFrame.size.height

        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            if x + panelFrame.size.width > screenFrame.maxX { x = screenFrame.maxX - panelFrame.size.width - 10 }
            if x < screenFrame.minX { x = screenFrame.minX + 10 }
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private class PanelDelegate: NSObject, NSWindowDelegate {
    static let shared = PanelDelegate()
    func windowWillClose(_ notification: Notification) {
        if let panel = notification.object as? NSPanel {
            UserDefaults.standard.set(Double(panel.frame.height), forKey: "panelHeight")
        }
        PanelManager.shared.isVisible = false
    }
}
