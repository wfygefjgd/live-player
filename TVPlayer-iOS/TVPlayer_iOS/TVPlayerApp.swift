import SwiftUI
import AVFoundation
import UIKit

@main
struct TVPlayerApp: App {
    @StateObject private var vm = PlayerViewModel()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .background(Color.clear)
        }
    }
}

/// 确保 keyWindow 背景黑、根视图透明，视频层可显示
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        clearHostingBackgrounds()
        NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)
    }

    private func clearHostingBackgrounds() {
        for scene in applicationScenes() {
            for window in scene.windows {
                window.backgroundColor = .black
                window.rootViewController?.view.backgroundColor = .clear
                window.rootViewController?.view.isOpaque = false
            }
        }
    }

    private func applicationScenes() -> [UIWindowScene] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    }
}
