import SwiftUI
import AppKit

@main
struct QuotaMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let store = SiteStore.shared
    private let viewModel = QuotaViewModel()
    private let panelManager = PanelManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.needle.fill", accessibilityDescription: "QuotaMenu")
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }
        panelManager.setStatusItem(statusItem)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        panelManager.toggle {
            QuotaMenuView()
                .environmentObject(self.store)
                .environmentObject(self.viewModel)
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        menu.addItem(withTitle: "Refresh All", action: #selector(refreshAll), keyEquivalent: "r").target = self

        if store.sites.count > 1 {
            menu.addItem(.separator())
            for site in store.sites {
                let item = NSMenuItem(title: site.name, action: #selector(switchSite(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = site.id
                if site.id == store.currentSite?.id {
                    item.state = .on
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        menu.addItem(withTitle: "Settings...", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "q").target = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshAll() {
        Task { await viewModel.fullRefresh() }
    }

    @objc private func switchSite(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        store.currentSiteID = id
        viewModel.onSiteChanged()
    }

    @objc private func openSettings() {
        WindowManager.shared.open(id: "settings", title: "QuotaMenu Settings", width: 450, height: 350) {
            SettingsView()
                .environmentObject(self.store)
                .environmentObject(self.viewModel)
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
