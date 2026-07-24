import SwiftUI
import AVKit
import UIKit
import Combine

/// Stretch full screen. Video draws under Home Indicator (indicator floats on top).
final class FullScreenPlayerViewController: UIViewController {
    private let playerLayer = AVPlayerLayer()
    private var cancellables = Set<AnyCancellable>()
    private var delayItems: [DispatchWorkItem] = []

    /// Allow system Home Indicator to auto-hide; when visible it overlays content (does not reserve black space).
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [.all] }
    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = false
        view.isOpaque = true
        playerLayer.videoGravity = .resize
        playerLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(playerLayer)

        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        if #available(iOS 11.0, *) {
            additionalSafeAreaInsets = .zero
        }

        for name: Notification.Name in [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification,
            UIDevice.orientationDidChangeNotification,
            .tvPlayerNeedsRelayout
        ] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.propagateHomeIndicatorPreference()
                    self?.forceRelayout()
                    self?.scheduleRelayoutPasses()
                }
                .store(in: &cancellables)
        }
    }

    deinit { delayItems.forEach { $0.cancel() } }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        propagateHomeIndicatorPreference()
        forceRelayout()
        scheduleRelayoutPasses()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // Keep using full window; do not shrink player for Home Indicator inset.
        neutralizeSafeArea()
        layoutPlayer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        neutralizeSafeArea()
        layoutPlayer()
    }

    /// Tell ancestors (including UIHostingController) to re-query home indicator policy.
    private func propagateHomeIndicatorPreference() {
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        var r: UIResponder? = self
        while let cur = r {
            if let vc = cur as? UIViewController {
                vc.setNeedsUpdateOfHomeIndicatorAutoHidden()
                vc.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            }
            r = cur.next
        }
    }

    /// Cancel safe-area padding so layout rect includes Home Indicator region.
    private func neutralizeSafeArea() {
        if #available(iOS 11.0, *) {
            let s = view.safeAreaInsets
            additionalSafeAreaInsets = UIEdgeInsets(
                top: -s.top, left: -s.left, bottom: -s.bottom, right: -s.right
            )
        }
    }

    func bind(player: AVPlayer?) {
        playerLayer.player = player
        playerLayer.videoGravity = .resize
        forceRelayout()
    }

    func onPlaybackReady() {
        propagateHomeIndicatorPreference()
        forceRelayout()
        scheduleRelayoutPasses()
    }

    func forceRelayout() {
        neutralizeSafeArea()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        layoutPlayer()
        DispatchQueue.main.async { [weak self] in
            self?.neutralizeSafeArea()
            self?.layoutPlayer()
        }
    }

    private func scheduleRelayoutPasses() {
        delayItems.forEach { $0.cancel() }
        delayItems.removeAll()
        for t in [0.0, 0.05, 0.15, 0.35, 0.7, 1.2, 2.0] {
            let item = DispatchWorkItem { [weak self] in
                self?.propagateHomeIndicatorPreference()
                self?.neutralizeSafeArea()
                self?.layoutPlayer()
            }
            delayItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: item)
        }
    }

    /// Always cover physical window (video under Home Indicator; bar floats above).
    private func layoutPlayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if playerLayer.superlayer == nil {
            view.layer.addSublayer(playerLayer)
        }

        if let window = view.window {
            // Full window bounds — includes area under Home Indicator
            let full = window.bounds
            playerLayer.frame = view.convert(full, from: nil)
        } else if view.bounds.width > 2, view.bounds.height > 2 {
            playerLayer.frame = view.bounds
        } else {
            let b = UIScreen.main.bounds
            playerLayer.frame = CGRect(
                x: 0, y: 0,
                width: max(b.width, b.height),
                height: min(b.width, b.height)
            )
        }

        if view.bounds.width > 2, view.bounds.height > 2 {
            if playerLayer.frame.width < view.bounds.width - 0.5
                || playerLayer.frame.height < view.bounds.height - 0.5 {
                playerLayer.frame = view.bounds
            }
        }

        playerLayer.videoGravity = .resize
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        CATransaction.commit()
    }
}

/// Forwards home-indicator preference to SwiftUI hosting controller chain.
final class HomeIndicatorForwarder: UIViewController {
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        var r: UIResponder? = self
        while let cur = r {
            if let vc = cur as? UIViewController {
                vc.setNeedsUpdateOfHomeIndicatorAutoHidden()
                vc.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            }
            r = cur.next
        }
    }
}

struct VideoPlayerView: UIViewControllerRepresentable {
    @EnvironmentObject private var vm: PlayerViewModel

    func makeUIViewController(context: Context) -> FullScreenPlayerViewController {
        let vc = FullScreenPlayerViewController()
        vc.bind(player: vm.player.player)
        return vc
    }

    func updateUIViewController(_ vc: FullScreenPlayerViewController, context: Context) {
        vc.bind(player: vm.player.player)
        _ = vm.playerLayoutEpoch
        if vm.player.isReady {
            vc.onPlaybackReady()
        } else {
            vc.forceRelayout()
        }
    }
}

/// Invisible VC that helps host prefer auto-hidden Home Indicator
struct HomeIndicatorConfigurator: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> HomeIndicatorForwarder {
        HomeIndicatorForwarder()
    }

    func updateUIViewController(_ uiViewController: HomeIndicatorForwarder, context: Context) {}
}

extension Notification.Name {
    static let tvPlayerNeedsRelayout = Notification.Name("tvPlayerNeedsRelayout")
}
