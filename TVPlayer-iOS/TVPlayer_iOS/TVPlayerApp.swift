import SwiftUI
import AVFoundation
import UIKit
import MediaPlayer

struct TVPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var vm = PlayerViewModel()

    var body: some Scene {
        WindowGroup {
            // 隐藏小白条/延迟边缘手势必须挂在最外层：真正的 window rootViewController
            // 是包裹 RootView 的 SwiftUI HostingController，内层 RootHostingController
            // 的 prefersHomeIndicatorAutoHidden 等策略系统不会询问
            RootView(vm: vm)
                .ignoresSafeArea(.all, edges: .all)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .defersSystemGestures(on: .all)
        }
    }
}

/// Wraps ContentView in RootHostingController (home indicator policy + clear background)
struct RootView: UIViewControllerRepresentable {
    @ObservedObject var vm: PlayerViewModel

    func makeUIViewController(context: Context) -> RootHostingController<AnyView> {
        let finalView = AnyView(
            ContentView()
                .environmentObject(vm)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .defersSystemGestures(on: .all)
                .background(Color.clear)
        )
        let host = RootHostingController(rootView: finalView)
        host.view.backgroundColor = .clear
        return host
    }

    /// 不重建 ContentView，避免数字键/菜单 @State 丢失
    func updateUIViewController(_ uiViewController: RootHostingController<AnyView>, context: Context) {
        uiViewController.setNeedsUpdateOfHomeIndicatorAutoHidden()
        uiViewController.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        uiViewController.setNeedsStatusBarAppearanceUpdate()
    }
}

@main
final class AppDelegate: NSObject, UIApplicationDelegate {

    // UIApplicationDelegate exposes this property to the application lifecycle.
    // Keep it internal so UIKit can satisfy the protocol requirement while the
    // delegate retains the real top-level window for safe-area/home-indicator
    // policy updates.
    var window: UIWindow?

    private var wasPlayingBeforeInterruption = false

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let viewModel = PlayerViewModel()
        let rootView = AnyView(
            ContentView()
                .environmentObject(viewModel)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .defersSystemGestures(on: .all)
                // The video layer lives directly in the window. Keep the
                // hosting view transparent so it cannot cover the AVPlayerLayer.
                .background(Color.clear)
        )
        let rootController = RootHostingController(rootView: rootView)
        rootController.view.backgroundColor = .clear

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = .black
        window.rootViewController = rootController
        self.window = window
        window.makeKeyAndVisible()

        setupAudioSession()
        setupRemoteCommands()
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .landscape
    }

    // MARK: - Audio Session

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("Audio session setup failed: \(error)")
        }
    }

    // MARK: - 远程控制（耳机/锁屏控件）

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { (_: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
            NotificationCenter.default.post(name: .tvPlayerRemotePlay, object: nil)
            return .success
        }
        center.pauseCommand.addTarget { (_: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
            NotificationCenter.default.post(name: .tvPlayerRemotePause, object: nil)
            return .success
        }
        center.nextTrackCommand.addTarget { (_: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
            NotificationCenter.default.post(name: .tvPlayerRemoteNext, object: nil)
            return .success
        }
        center.previousTrackCommand.addTarget { (_: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
            NotificationCenter.default.post(name: .tvPlayerRemotePrevious, object: nil)
            return .success
        }

        // 禁用不需要的命令
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.ratingCommand.isEnabled = false
        center.changePlaybackRateCommand.isEnabled = false
    }

    // MARK: - 生命周期

    func applicationDidBecomeActive(_ application: UIApplication) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.backgroundColor = .black
                if let root = window.rootViewController {
                    root.view.backgroundColor = .clear
                    root.view.isOpaque = false
                    // 不在此清零 additionalSafeAreaInsets：由 RootHostingController 负向抵消小白条
                    root.setNeedsUpdateOfHomeIndicatorAutoHidden()
                    root.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
                    root.setNeedsStatusBarAppearanceUpdate()
                }
            }
        }
        WindowVideoSurface.shared.forceFullBleed(reason: "app-active")
        WindowVideoSurface.shared.rebindPlayer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            WindowVideoSurface.shared.forceFullBleed(reason: "app-active-delay")
            WindowVideoSurface.shared.rebindPlayer()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            WindowVideoSurface.shared.forceFullBleed(reason: "app-active-delay2")
        }
        NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // 即将进入后台
        NotificationCenter.default.post(name: .tvPlayerWillResignActive, object: nil)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        NotificationCenter.default.post(name: .tvPlayerDidEnterBackground, object: nil)
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        WindowVideoSurface.shared.forceFullBleed(reason: "foreground")
        WindowVideoSurface.shared.rebindPlayer()
        NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)
    }

    // MARK: - 内存警告

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        // 内存警告时释放不必要的资源
        URLCache.shared.removeAllCachedResponses()
    }
}

// MARK: - 远程控制通知名称

extension Notification.Name {
    static let tvPlayerRemotePlay = Notification.Name("tvPlayerRemotePlay")
    static let tvPlayerRemotePause = Notification.Name("tvPlayerRemotePause")
    static let tvPlayerRemoteNext = Notification.Name("tvPlayerRemoteNext")
    static let tvPlayerRemotePrevious = Notification.Name("tvPlayerRemotePrevious")
    static let tvPlayerWillResignActive = Notification.Name("tvPlayerWillResignActive")
    static let tvPlayerDidEnterBackground = Notification.Name("tvPlayerDidEnterBackground")
}
