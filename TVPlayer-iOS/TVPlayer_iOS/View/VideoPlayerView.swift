import SwiftUI
import AVKit
import UIKit
import MediaPlayer
import Combine

// MARK: - 窗口级全屏画面（防崩溃版）
//
// 1.5.42 闪退原因：hardRemount → layoutIfNeeded → viewDidLayoutSubviews → hardRemount 递归爆栈。
// 本版：防重入 + 节流；layout 只调 forceFullBleed；hardRemount 仅在回前台/出画/旋转结束调用。

final class WindowVideoSurface {
    static let shared = WindowVideoSurface()

    private let host = TouchThroughView(frame: .zero)
    private let playerLayer = AVPlayerLayer()
    private var cancellables = Set<AnyCancellable>()
    private var delayItems: [DispatchWorkItem] = []
    private weak var boundPlayer: AVPlayer?
    private var lastAppliedSize: CGSize = .zero

    /// 防重入
    private var isRemounting = false
    private var isLayingOut = false
    private var lastRemountAt: Date = .distantPast
    private let remountMinInterval: TimeInterval = 0.25

    private init() {
        host.backgroundColor = .black
        host.isUserInteractionEnabled = false
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.clipsToBounds = true
        host.layer.zPosition = -1_000

        playerLayer.videoGravity = .resize
        playerLayer.backgroundColor = UIColor.black.cgColor
        playerLayer.isOpaque = true
        playerLayer.masksToBounds = true
        host.layer.addSublayer(playerLayer)

        setupNotifications()
        setupAudioSession()
    }

    private func setupNotifications() {
        // 回前台：轻量 + 一次 hard（带节流）
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willEnterForegroundNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.forceFullBleed(reason: name.rawValue)
                    self?.hardRemount(reason: name.rawValue)
                }
                .store(in: &cancellables)
        }
        for name in [UIDevice.orientationDidChangeNotification, UIWindow.didBecomeKeyNotification, .tvPlayerNeedsRelayout] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.forceFullBleed(reason: name.rawValue) }
                .store(in: &cancellables)
        }
        NotificationCenter.default.publisher(for: .tvPlayerHardRemount)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.hardRemount(reason: "notify") }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.handleInterruption(note) }
            .store(in: &cancellables)
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

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            NotificationCenter.default.post(name: .tvPlayerInterruptionBegan, object: nil)
        case .ended:
            let should = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            if should {
                NotificationCenter.default.post(name: .tvPlayerInterruptionEnded, object: nil)
            }
            forceFullBleed(reason: "interruptionEnded")
            rebindPlayer()
        @unknown default:
            break
        }
    }

    // MARK: - Player

    func setPlayer(_ player: AVPlayer?) {
        boundPlayer = player
        playerLayer.player = player
        playerLayer.videoGravity = .resize
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        forceFullBleed(reason: "setPlayer")
        scheduleLightPasses()
    }

    func rebindPlayer() {
        guard let p = boundPlayer else { return }
        if playerLayer.player !== p {
            playerLayer.player = p
        }
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        playerLayer.videoGravity = .resize
        guard host.bounds.width > 1, host.bounds.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = host.bounds
        CATransaction.commit()
    }

    /// 安全 hardRemount：防重入、节流；禁止在 layout 回调链里同步 layoutIfNeeded
    func hardRemount(reason: String = "") {
        if isRemounting || isLayingOut { return }
        let now = Date()
        if now.timeIntervalSince(lastRemountAt) < remountMinInterval {
            // 合并到稍后一次
            DispatchQueue.main.asyncAfter(deadline: .now() + remountMinInterval) { [weak self] in
                self?.hardRemount(reason: "deferred-\(reason)")
            }
            return
        }
        lastRemountAt = now
        isRemounting = true
        defer { isRemounting = false }

        guard let window = Self.mainWindow() else {
            forceFullBleed(reason: "hard-no-window")
            return
        }

        let p = boundPlayer
        // 不断开 player 太久，避免黑屏；仅重挂 frame
        // 若需要断绑：仅在回前台 reason 时做
        let shouldDetachPlayer = reason.contains("active") || reason.contains("foreground") || reason.contains("ready")
        if shouldDetachPlayer {
            playerLayer.player = nil
        }

        if host.superview !== window {
            host.removeFromSuperview()
            window.insertSubview(host, at: 0)
        } else {
            window.sendSubviewToBack(host)
        }

        window.backgroundColor = .black
        window.clipsToBounds = false

        let rect = Self.fullScreenRect(for: window)
        guard rect.width > 1, rect.height > 1 else { return }

        host.isHidden = false
        host.alpha = 1
        host.backgroundColor = .black
        host.clipsToBounds = true
        host.isUserInteractionEnabled = false
        host.layer.zPosition = -1_000
        host.frame = rect
        host.bounds = CGRect(origin: .zero, size: rect.size)
        lastAppliedSize = rect.size

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = host.bounds
        playerLayer.videoGravity = .resize
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        CATransaction.commit()

        if shouldDetachPlayer {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.playerLayer.player = p ?? self.boundPlayer
                self.rebindPlayer()
            }
        } else {
            playerLayer.player = p ?? boundPlayer
            rebindPlayer()
        }

        // 只跟 2 次轻量钉，避免风暴
        for t in [0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                self?.forceFullBleed(reason: "hard-follow")
                self?.rebindPlayer()
            }
        }
    }

    func cleanup() {
        delayItems.forEach { $0.cancel() }
        delayItems.removeAll()
    }

    deinit {
        cleanup()
        cancellables.removeAll()
    }

    func install(reason: String = "") {
        forceFullBleed(reason: reason)
    }

    /// 轻量全屏：绝不调用 hardRemount，避免 layout 递归
    func forceFullBleed(reason: String = "") {
        if isLayingOut { return }
        isLayingOut = true
        defer { isLayingOut = false }

        guard let window = Self.mainWindow() else { return }

        window.backgroundColor = .black
        window.clipsToBounds = false

        if let root = window.rootViewController {
            root.view.backgroundColor = .clear
            root.view.isOpaque = false
            root.view.clipsToBounds = false
            root.view.insetsLayoutMarginsFromSafeArea = false
            // 不在这里 layoutIfNeeded / hardRemount
            root.setNeedsUpdateOfHomeIndicatorAutoHidden()
            root.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            root.setNeedsStatusBarAppearanceUpdate()
        }

        host.layer.zPosition = -1_000
        if host.superview !== window {
            host.removeFromSuperview()
            window.insertSubview(host, at: 0)
        } else {
            window.sendSubviewToBack(host)
        }

        let rect = Self.fullScreenRect(for: window)
        guard rect.width > 1, rect.height > 1 else { return }

        host.isHidden = false
        host.alpha = 1
        host.backgroundColor = .black
        host.clipsToBounds = true
        host.isUserInteractionEnabled = false
        host.frame = rect
        host.bounds = CGRect(origin: .zero, size: rect.size)
        lastAppliedSize = rect.size

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = host.bounds
        playerLayer.videoGravity = .resize
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        if playerLayer.player == nil {
            playerLayer.player = boundPlayer
        }
        CATransaction.commit()
    }

    private func scheduleLightPasses() {
        delayItems.forEach { $0.cancel() }
        delayItems.removeAll()
        for t in [0.05, 0.2, 0.5] {
            let item = DispatchWorkItem { [weak self] in
                self?.forceFullBleed(reason: "delay")
                self?.rebindPlayer()
            }
            delayItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: item)
        }
    }

    /// 与 window 同向全屏（不改 window.frame，避免系统崩溃）
    private static func fullScreenRect(for window: UIWindow) -> CGRect {
        let wb = window.bounds
        if wb.width > 1, wb.height > 1 {
            return CGRect(origin: .zero, size: wb.size)
        }
        let screen = window.windowScene?.screen ?? window.screen
        let b = screen.bounds
        let long = max(b.width, b.height)
        let short = min(b.width, b.height)
        // 默认横屏目标
        return CGRect(x: 0, y: 0, width: long, height: short)
    }

    private static func mainWindow() -> UIWindow? {
        if let app = UIApplication.shared.delegate as? AppDelegate, let w = app.window {
            return w
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive {
            let normals = scene.windows.filter { $0.windowLevel <= .normal && !$0.isHidden }
            if let key = normals.first(where: \.isKeyWindow) { return key }
            if let first = normals.first { return first }
        }
        return scenes.flatMap(\.windows).first { $0.windowLevel <= .normal }
    }
}

private final class TouchThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

final class PlayerAnchorView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        WindowVideoSurface.shared.forceFullBleed(reason: "anchor-window")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 只轻量，绝不 hardRemount
        WindowVideoSurface.shared.forceFullBleed(reason: "anchor-layout")
    }
}

struct VideoPlayerView: UIViewRepresentable {
    @EnvironmentObject private var vm: PlayerViewModel

    func makeUIView(context: Context) -> PlayerAnchorView {
        let v = PlayerAnchorView()
        WindowVideoSurface.shared.setPlayer(vm.player.player)
        return v
    }

    func updateUIView(_ uiView: PlayerAnchorView, context: Context) {
        WindowVideoSurface.shared.setPlayer(vm.player.player)
        _ = vm.playerLayoutEpoch
        WindowVideoSurface.shared.forceFullBleed(reason: "swiftui-update")
    }
}

// MARK: - 根容器

final class FullScreenRootController: UIViewController {
    private let hosted: UIViewController

    init(hosting: UIViewController) {
        self.hosted = hosting
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { nil }
    override var childForStatusBarHidden: UIViewController? { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isOpaque = true
        view.clipsToBounds = false
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        additionalSafeAreaInsets = .zero
        view.insetsLayoutMarginsFromSafeArea = false

        addChild(hosted)
        hosted.view.translatesAutoresizingMaskIntoConstraints = false
        hosted.view.backgroundColor = .clear
        hosted.view.isOpaque = false
        view.addSubview(hosted.view)
        NSLayoutConstraint.activate([
            hosted.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosted.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosted.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosted.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hosted.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshSystemChrome()
        WindowVideoSurface.shared.forceFullBleed(reason: "root-appear")
        // 出画后延迟一次 hard（不在 layout 里）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            WindowVideoSurface.shared.hardRemount(reason: "root-appear-delay")
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            WindowVideoSurface.shared.forceFullBleed(reason: "transition")
        }, completion: { _ in
            WindowVideoSurface.shared.hardRemount(reason: "transition-end")
        })
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        refreshSystemChrome()
        WindowVideoSurface.shared.forceFullBleed(reason: "safeArea")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 禁止 hardRemount，否则递归闪退
        WindowVideoSurface.shared.forceFullBleed(reason: "root-layout")
    }

    func refreshSystemChrome() {
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsStatusBarAppearanceUpdate()
    }
}

final class RootHostingController<Content: View>: UIHostingController<Content> {
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { nil }
    override var childForStatusBarHidden: UIViewController? { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = false
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        additionalSafeAreaInsets = .zero
        view.insetsLayoutMarginsFromSafeArea = false
        if #available(iOS 16.4, *) {
            safeAreaRegions = []
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsStatusBarAppearanceUpdate()
        WindowVideoSurface.shared.forceFullBleed(reason: "host-appear")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        WindowVideoSurface.shared.forceFullBleed(reason: "host-layout")
    }
}

final class NowPlayingController {
    static let shared = NowPlayingController()
    private let infoCenter = MPNowPlayingInfoCenter.default()

    func update(title: String, artist: String, isPlaying: Bool) {
        var info = infoCenter.nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = artist
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        infoCenter.nowPlayingInfo = info
    }

    func updateElapsedTime(_ time: TimeInterval) {
        var info = infoCenter.nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
        infoCenter.nowPlayingInfo = info
    }

    func updatePlaybackRate(_ rate: Float) {
        var info = infoCenter.nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        infoCenter.nowPlayingInfo = info
    }

    func clear() {
        infoCenter.nowPlayingInfo = nil
    }
}

extension Notification.Name {
    static let tvPlayerNeedsRelayout = Notification.Name("tvPlayerNeedsRelayout")
    static let tvPlayerInterruptionBegan = Notification.Name("tvPlayerInterruptionBegan")
    static let tvPlayerInterruptionEnded = Notification.Name("tvPlayerInterruptionEnded")
    static let tvPlayerHardRemount = Notification.Name("tvPlayerHardRemount")
}
