import SwiftUI
import AVFoundation
import UIKit
import MediaPlayer

@main
struct TVPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var vm = PlayerViewModel()

    var body: some Scene {
        WindowGroup {
            RootView(vm: vm)
                .ignoresSafeArea(.all, edges: .all)
        }
    }
}

/// Wraps ContentView in RootHostingController (home indicator policy + clear background)
struct RootView: UIViewControllerRepresentable {
    @ObservedObject var vm: PlayerViewModel

    func makeUIViewController(context: Context) -> RootHostingController<AnyView> {
        let root = ContentView()
            .environmentObject(vm)
            .preferredColorScheme(.dark)
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .defersSystemGestures(on: .all)
            .background(Color.clear)
        let host = RootHostingController(rootView: AnyView(root))
        host.view.backgroundColor = .clear
        return host
    }

    func updateUIViewController(_ uiViewController: RootHostingController<AnyView>, context: Context) {
        let root = ContentView()
            .environmentObject(vm)
            .preferredColorScheme(.dark)
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .defersSystemGestures(on: .all)
            .background(Color.clear)
        uiViewController.rootView = AnyView(root)
        uiViewController.setNeedsUpdateOfHomeIndicatorAutoHidden()
        uiViewController.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {

    private var wasPlayingBeforeInterruption = false

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        setupAudioSession()
        setupRemoteCommands()
        return true
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

        center.playCommand.addTarget { [weak self] (_: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
            NotificationCenter.default.post(name: .tvPlayerRemotePlay, object: nil)
            return .success
        }
        center.pauseCommand.addTarget { [weak self] (_: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
            NotificationCenter.default.post(name: .tvPlayerRemotePause, object: nil)
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] (_: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
            NotificationCenter.default.post(name: .tvPlayerRemoteNext, object: nil)
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] (_: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
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
        // 窗口布局修复
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.backgroundColor = .black
                if let root = window.rootViewController {
                    root.view.backgroundColor = .clear
                    root.view.isOpaque = false
                    // 强制隐藏 Home Indicator
                    root.setNeedsUpdateOfHomeIndicatorAutoHidden()
                    root.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()

                    // 延迟再次调用，确保生效
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        root.setNeedsUpdateOfHomeIndicatorAutoHidden()
                        root.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
                    }
                }
            }
        }
        WindowVideoSurface.shared.install(reason: "app-active")
        NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // 即将进入后台
        NotificationCenter.default.post(name: .tvPlayerWillResignActive, object: nil)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // 已进入后台，激活后台播放
        WindowVideoSurface.shared.install(reason: "background")
        NotificationCenter.default.post(name: .tvPlayerDidEnterBackground, object: nil)
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // 即将回前台
        WindowVideoSurface.shared.install(reason: "foreground")
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
