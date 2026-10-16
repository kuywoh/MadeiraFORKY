import SwiftUI

@main
struct MadeiraApp: App {
    init() {
        // ml1172: read the screen on the main thread; library entries, whose
        // default Resolution comes from it, are also made on other threads.
        _ = ResolutionChoices.screen
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(ClaimGamepadEvents())
                .onAppear {
                    GamepadInput.shared.start()
                    HardwareInput.shared.start()
                    JITNetworkShortcut.shared.restoreLeftover()   // also starts its network path monitor
                }
                // madeira://jit-network/... (the Madeira JIT shortcut returning, JITNetwork.swift),
                // else madeira://play?exe=... (Home Screen shortcuts, SavesAndShortcuts.swift).
                .onOpenURL { url in
                    // Roblox Studio's browser login returns through this scheme.
                    // The native bridge validates OAuth state before waking Wine.
                    if winios_receive_auth_callback(url.absoluteString) != 0 { return }
                    if !JITNetworkShortcut.shared.handle(url) { ShortcutRouter.shared.handle(url) }
                }
        }
    }
}
