import SwiftUI

@main
struct TVPlayerApp: App {
    @StateObject private var vm = PlayerViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .preferredColorScheme(.dark)
                .persistentSystemOverrides(.hidden)
                .statusBarHidden(true)
        }
    }
}
