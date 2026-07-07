import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let state = AppState()
    private let room = RoomManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        let hosting = NSHostingController(
            rootView: ContentView().environmentObject(state).environmentObject(room))
        // Le popover se dimensionne exactement au contenu SwiftUI (plus de
        // hauteur figée qui rognait le haut quand plusieurs sorties sont ouvertes).
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform.badge.plus", accessibilityDescription: "OutputsSync Nightly")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Propose d'installer le driver s'il manque (1ᵉʳ lancement).
        if !DriverInstaller.isInstalled {
            DriverInstaller.promptIfNeeded { [weak self] installed in
                if installed { self?.state.refreshDevices() }
            }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            state.refreshDevices()
            room.refreshOutputs()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.stop()
        room.leaveRoom()
    }
}
