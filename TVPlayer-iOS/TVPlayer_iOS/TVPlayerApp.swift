import SwiftUI
import AVFoundation
import UIKit
import MediaPlayer

@main
final class AppDelegate: NSObject, UIApplicationDelegate {

    var window: UIWindow?
    private var viewModel: PlayerViewModel?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let viewModel = PlayerViewModel()
        self.viewModel = viewModel

        let rootView = AnyView(
            ContentView()
                .environmentObject(viewModel)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .defersSystemGestures(on: .all)
                .background(Color.clear)
        )
        let rootController = RootHostingController(rootView: rootView)
        rootController.view.backgroundColor = .clear
        rootController.view.isOpaque = false
        rootController.view.clipsToBounds = false
        rootController.additionalSafeAreaInsets = .zero

        // 必须绑定 UIWindowScene，否则 bounds/safeArea 与物理屏脱节，小白条会顶画面
        let window: UIWindow
        if let scene = application.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        window.backgroundColor = .black
        window.clipsToBounds = false
        window.rootViewController = rootController
        self.window = window
        window.makeKeyAndVisible()

        setupAudioSession()
        setupRemoteCommands()

        WindowVideoSurface.shared.forceFullBleed(reason: "launch")
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .landscape
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("Audio session setup failed: \(error)")
        }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            NotificationCenter.default.post(name: .tvPlayerRemotePlay, object: nil)
            return .success
        }
        center.pauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: .tvPlayerRemotePause, object: nil)
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            NotificationCenter.default.post(name: .tvPlayerRemoteNext, object: nil)
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            NotificationCenter.default.post(name: .tvPlayerRemotePrevious, object: nil)
            return .success
        }
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.ratingCommand.isEnabled = false
        center.changePlaybackRateCommand.isEnabled = false
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        refreshWindows()
        WindowVideoSurface.shared.forceFullBleed(reason: "app-active")
        WindowVideoSurface.shared.rebindPlayer()
        viewModel?.resumeIfAppropriate()
        viewModel?.onAppBecameActive()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            WindowVideoSurface.shared.forceFullBleed(reason: "app-active-delay")
            WindowVideoSurface.shared.rebindPlayer()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            WindowVideoSurface.shared.forceFullBleed(reason: "app-active-delay2")
            WindowVideoSurface.shared.rebindPlayer()
        }
        NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)
    }

    func applicationWillResignActive(_ application: UIApplication) {
        NotificationCenter.default.post(name: .tvPlayerWillResignActive, object: nil)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        NotificationCenter.default.post(name: .tvPlayerDidEnterBackground, object: nil)
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        refreshWindows()
        WindowVideoSurface.shared.forceFullBleed(reason: "foreground")
        WindowVideoSurface.shared.rebindPlayer()
        viewModel?.resumeIfAppropriate()
        viewModel?.onAppBecameActive()
        NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        URLCache.shared.removeAllCachedResponses()
    }

    private func refreshWindows() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.backgroundColor = .black
                window.clipsToBounds = false
                if let root = window.rootViewController {
                    root.view.backgroundColor = .clear
                    root.view.isOpaque = false
                    root.view.clipsToBounds = false
                    root.additionalSafeAreaInsets = .zero
                    root.setNeedsUpdateOfHomeIndicatorAutoHidden()
                    root.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
                    root.setNeedsStatusBarAppearanceUpdate()
                }
            }
        }
    }
}

extension Notification.Name {
    static let tvPlayerRemotePlay = Notification.Name("tvPlayerRemotePlay")
    static let tvPlayerRemotePause = Notification.Name("tvPlayerRemotePause")
    static let tvPlayerRemoteNext = Notification.Name("tvPlayerRemoteNext")
    static let tvPlayerRemotePrevious = Notification.Name("tvPlayerRemotePrevious")
    static let tvPlayerWillResignActive = Notification.Name("tvPlayerWillResignActive")
    static let tvPlayerDidEnterBackground = Notification.Name("tvPlayerDidEnterBackground")
}
