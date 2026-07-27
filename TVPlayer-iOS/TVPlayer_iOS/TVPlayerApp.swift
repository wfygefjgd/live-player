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
        setupAudioSession()
        setupRemoteCommands()
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

    func installMainWindow(application: UIApplication, scene: UIWindowScene? = nil) {
        guard let scene else { return }
        if let window, rootContainer != nil {
            if window.windowScene !== scene {
                window.windowScene = scene
            }
            window.frame = scene.coordinateSpace.bounds
            window.makeKeyAndVisible()
            requestLandscape(for: scene, root: rootContainer)
            rootContainer?.refreshSystemChrome()
            return
        }

        let viewModel = self.viewModel ?? PlayerViewModel()
        self.viewModel = viewModel

        let rootView = AnyView(
            ContentView()
                .environmentObject(viewModel)
                .preferredColorScheme(.dark)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .ignoresSafeArea(.all, edges: .all)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .defersSystemGestures(on: .all)
        )
        let hosting = RootHostingController(rootView: rootView)
        let container = FullScreenRootController(hosting: hosting)
        self.rootContainer = container

        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.backgroundColor = .black
        window.isOpaque = true
        window.rootViewController = container
        self.window = window
        window.makeKeyAndVisible()
        requestLandscape(for: scene, root: container)
        WindowVideoSurface.shared.setPlayer(viewModel.player.player)
        WindowVideoSurface.shared.rebindPlayer()
        container.refreshSystemChrome()
    }

    private func requestLandscape(for scene: UIWindowScene?, root: UIViewController?) {
        root?.setNeedsUpdateOfSupportedInterfaceOrientations()
        UIViewController.attemptRotationToDeviceOrientation()
        guard let scene else { return }
        if #available(iOS 16.0, *) {
            let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscape)
            scene.requestGeometryUpdate(prefs) { error in
                print("requestGeometryUpdate failed: \(error.localizedDescription)")
            }
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
        requestLandscape(for: window?.windowScene, root: rootContainer)
        rootContainer?.refreshSystemChrome()
        viewModel?.resumeIfAppropriate()
        viewModel?.onAppBecameActive()
        WindowVideoSurface.shared.rebindPlayer()
    }

    func applicationWillResignActive(_ application: UIApplication) {
        NotificationCenter.default.post(name: .tvPlayerWillResignActive, object: nil)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        NotificationCenter.default.post(name: .tvPlayerDidEnterBackground, object: nil)
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        requestLandscape(for: window?.windowScene, root: rootContainer)
        viewModel?.resumeIfAppropriate()
        viewModel?.onAppBecameActive()
        WindowVideoSurface.shared.rebindPlayer()
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        URLCache.shared.removeAllCachedResponses()
    }

    func refreshChromeAndVideo(reason: String) {
        WindowVideoSurface.shared.rebindPlayer()
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        guard let app = UIApplication.shared.delegate as? AppDelegate else { return }
        app.installMainWindow(application: UIApplication.shared, scene: windowScene)
        (app.window?.rootViewController as? FullScreenRootController)?.refreshSystemChrome()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        if let app = UIApplication.shared.delegate as? AppDelegate {
            (app.window?.rootViewController as? FullScreenRootController)?.refreshSystemChrome()
        }
        WindowVideoSurface.shared.rebindPlayer()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        if let app = UIApplication.shared.delegate as? AppDelegate {
            (app.window?.rootViewController as? FullScreenRootController)?.refreshSystemChrome()
        }
        WindowVideoSurface.shared.rebindPlayer()
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
