import SwiftUI

@main
struct CueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The app is driven by a manually managed status-bar item (see
        // StatusItemController) so the menu bar icon can do left-click → popover
        // and right-click → standard menu. This placeholder scene just satisfies
        // the `App` requirement; it's never shown for this LSUIElement agent app.
        Settings { EmptyView() }
    }
}
