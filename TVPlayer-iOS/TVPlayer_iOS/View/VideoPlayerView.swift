import SwiftUI
import AVKit
import UIKit
import Combine

/// Fill + 首次=回前�?relayout�?.3.0 架构，有画有声）
final class FullScreenPlayerViewController: UIViewController {
    private let playerLayer = AVPlayerLayer()
    private var cancellables = Set<AnyCancellable>()
    private var delayItems: [DispatchWorkItem] = []

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [.bottom, .top] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = false
        view.isOpaque = true
        playerLayer.videoGravity = .resizeAspect
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
                    self?.applyHomePolicy()
                    self?.forceRelayout()
                    self?.scheduleRelayoutPasses()
                }
                .store(in: &cancellables)
        }
    }

    deinit { delayItems.forEach { $0.cancel() } }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyHomePolicy()
        forceRelayout()
        scheduleRelayoutPasses()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        neutralizeSafeArea()
        layoutPlayer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        neutralizeSafeArea()
        layoutPlayer()
    }

    private func applyHomePolicy() {
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }

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
        playerLayer.videoGravity = .resizeAspect
        forceRelayout()
    }

    func onPlaybackReady() {
        applyHomePolicy()
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
                self?.applyHomePolicy()
                self?.neutralizeSafeArea()
                self?.layoutPlayer()
            }
            delayItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: item)
        }
    }

    private func layoutPlayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if playerLayer.superlayer == nil {
            view.layer.addSublayer(playerLayer)
        }
        if let window = view.window {
            var full = window.bounds
            let screen = window.screen.bounds
            if full.width * full.height < screen.width * screen.height * 0.95 {
                full = screen
            }
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
        playerLayer.videoGravity = .resizeAspect
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        CATransaction.commit()
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

extension Notification.Name {
    static let tvPlayerNeedsRelayout = Notification.Name("tvPlayerNeedsRelayout")
}
