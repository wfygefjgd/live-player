import SwiftUI
import AVFoundation
import UIKit
import MediaPlayer

@main
final class AppDelegate: NSObject, UIApplicationDelegate {

    var window: UIWindow?
    private var viewModel: PlayerViewModel?
    private weak var rootContainer: FullScreenRootController?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        OrientationBootstrap.resetForColdLaunch()
        setupAudioSession()
        setupRemoteCommands()
        // scene 可能尚未就绪：先建，再在 scene 回调里绑 windowScene
        installMainWindow(application: application)
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .landscape
    }

    /// 模拟 didBecomeActive 里对播放器的恢复（不真正进后台）
    func simulateBecomeActiveRecovery() {
        viewModel?.resumeIfAppropriate()
        // 不走完整 onAppBecameActive 重拉线路，只钉画面
        viewModel?.bumpLayoutForRemount()
        WindowVideoSurface.shared.hardRemount(reason: "sim-become-active")
    }

    func installMainWindow(application: UIApplication, scene: UIWindowScene? = nil) {
        // 已有正确 scene 的 window 则只刷新，避免重复创建
        if let window, let rootContainer, scene == nil || window.windowScene === scene {
            if let scene, window.windowScene == nil {
                window.windowScene = scene
                window.frame = scene.coordinateSpace.bounds
            }
            window.makeKeyAndVisible()
            rootContainer.refreshSystemChrome()
            WindowVideoSurface.shared.forceFullBleed(reason: "reinstall-skip")
            return
        }

        let viewModel = self.viewModel ?? PlayerViewModel()
        self.viewModel = viewModel

        let rootView = AnyView(
            ContentView()
                .environmentObject(viewModel)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .defersSystemGestures(on: .all)
                .background(Color.clear)
                .ignoresSafeArea(.all, edges: .all)
        )
        let hosting = RootHostingController(rootView: rootView)
        hosting.view.backgroundColor = .clear
        hosting.view.isOpaque = false
        let container = FullScreenRootController(hosting: hosting)
        self.rootContainer = container

        let resolvedScene = scene
            ?? application.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        let window: UIWindow
        if let resolvedScene {
            if let existing = self.window, existing.windowScene == nil || existing.windowScene === resolvedScene {
                existing.windowScene = resolvedScene
                existing.frame = resolvedScene.coordinateSpace.bounds
                existing.rootViewController = container
                // 容器透明：底下是 window 最底层的画面 host（用户方案）
                existing.backgroundColor = .clear
                existing.isOpaque = false
                existing.clipsToBounds = false
                self.window = existing
                existing.makeKeyAndVisible()
            } else {
                let w = UIWindow(windowScene: resolvedScene)
                w.frame = resolvedScene.coordinateSpace.bounds
                w.backgroundColor = .clear
                w.isOpaque = false
                w.clipsToBounds = false
                w.rootViewController = container
                self.window = w
                w.makeKeyAndVisible()
            }
        } else {
            let w = self.window ?? UIWindow(frame: UIScreen.main.bounds)
            w.backgroundColor = .clear
            w.isOpaque = false
            w.clipsToBounds = false
            w.rootViewController = container
            self.window = w
            w.makeKeyAndVisible()
        }

        container.refreshSystemChrome()
        WindowVideoSurface.shared.forceFullBleed(reason: "launch")
        DispatchQueue.main.async {
            container.refreshSystemChrome()
            WindowVideoSurface.shared.forceFullBleed(reason: "launch-async")
            OrientationBootstrap.lockLandscapeAndRefresh()
        }
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
        refreshChromeAndVideo(reason: "app-active")
        viewModel?.resumeIfAppropriate()
        viewModel?.onAppBecameActive()
    }

    func applicationWillResignActive(_ application: UIApplication) {
        NotificationCenter.default.post(name: .tvPlayerWillResignActive, object: nil)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        NotificationCenter.default.post(name: .tvPlayerDidEnterBackground, object: nil)
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        refreshChromeAndVideo(reason: "foreground")
        viewModel?.resumeIfAppropriate()
        viewModel?.onAppBecameActive()
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        URLCache.shared.removeAllCachedResponses()
    }

    func refreshChromeAndVideo(reason: String) {
        if let window, !window.isKeyWindow {
            window.makeKeyAndVisible()
        }
        rootContainer?.refreshSystemChrome()
        // 只钉锁定全屏，不 hardRemount（防闪屏）
        WindowVideoSurface.shared.forceFullBleed(reason: reason)
        WindowVideoSurface.shared.rebindPlayer()
    }
}

/// Scene 就绪时把 window 绑到正确的 UIWindowScene（小白条/safeArea 依赖这个）
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        guard let app = UIApplication.shared.delegate as? AppDelegate else { return }
        if app.window == nil || app.window?.windowScene == nil {
            app.installMainWindow(application: UIApplication.shared, scene: windowScene)
        } else if app.window?.windowScene !== windowScene {
            app.window?.windowScene = windowScene
            app.window?.frame = windowScene.coordinateSpace.bounds
            app.window?.makeKeyAndVisible()
        }
        app.refreshChromeAndVideo(reason: "scene-connect")
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        (UIApplication.shared.delegate as? AppDelegate)?.refreshChromeAndVideo(reason: "scene-active")
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        (UIApplication.shared.delegate as? AppDelegate)?.refreshChromeAndVideo(reason: "scene-foreground")
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
