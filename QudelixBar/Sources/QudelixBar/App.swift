import SwiftUI

@main
struct QudelixBarApp: App {
    @StateObject private var controller = QudelixController()

    init() {
        #if DEBUG
        UIPreview.runIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(controller)
        } label: {
            Image(systemName: menuIcon)
                .onAppear { controller.start() }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuIcon: String {
        if case .connected = controller.connection { return "headphones.circle.fill" }
        return "headphones.circle"
    }
}
