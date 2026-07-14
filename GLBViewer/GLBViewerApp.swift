import SwiftUI

@main
struct GLBViewerApp: App {

    init() {
        SelfTest.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
