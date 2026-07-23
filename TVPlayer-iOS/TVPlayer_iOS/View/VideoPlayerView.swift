import SwiftUI
import AVKit
import UIKit
import Combine

/// 回滚基准 1.3.4：画面在 SwiftUI 层级内（有画有声）。
/// aspectFill + window 对齐；ready/回前台/延迟 relayout。
final class FullScreenPlayerViewController: UIViewController {
    private let playerLayer = AVPlayerLayer()
    private var cancellables = Set<AnyCancellable>()
    private var delayItems: [DispatchWorkItem] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = false
        view.isOpaque = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(playerLayer)

        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        if #available(iOS 11.0, *) {
            additionalSafeAreaInsets = .zero
        }

        let notes: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification,
            UIDevice.orientationDidChangeNotification,
            .tvPlayerNeedsRelayout
        ]
        for name in notes {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.forceRelayout()
                    self?.scheduleRelayoutPasses()
                }
                .store(in: &cancellables)
        }
    }

    deinit {
        delayItems.forEach { $0.cancel() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        forceRelayout()
        scheduleRelayoutPasses()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if #available(iOS 11.0, *) {
            let s = view.safeAreaInsets
            additionalSafeAreaInsets = UIEdgeInsets(
                top: -s.top, left: -s.left, bottom: -s.bottom, right: -s.right
            )
        }
        layoutPlayer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPlayer()
    }

    func bind(player: AVPlayer?) {
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        forceRelayout()
    }

    func onPlaybackReady() {
        forceRelayout()
        scheduleRelayoutPasses()
    }

    func forceRelayout() {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        layoutPlayer()
        DispatchQueue.main.async { [weak self] in
            self?.layoutPlayer()
        }
    }

    private func scheduleRelayoutPasses() {
        delayItems.forEach { $0.cancel() }
        delayItems.removeAll()
        for t in [0.05, 0.15, 0.35, 0.7, 1.2] {
            let item = DispatchWorkItem { [weak self] in self?.layoutPlayer() }
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
            playerLayer.frame = view.convert(window.bounds, from: nil)
        } else if view.bounds.width > 1, view.bounds.height > 1 {
            playerLayer.frame = view.bounds
        } else {
            let b = UIScreen.main.bounds
            playerLayer.frame = CGRect(
                x: 0, y: 0,
                width: max(b.width, b.height),
                height: min(b.width, b.height)
            )
        }
        if playerLayer.frame.width < view.bounds.width - 1
            || playerLayer.frame.height < view.bounds.height - 1 {
            playerLayer.frame = view.bounds
        }
        playerLayer.videoGravity = .resizeAspectFill
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

    func updateUIViewController(_ uiViewController: FullScreenPlayerViewController, context: Context) {
        uiViewController.bind(player: vm.player.player)
        _ = vm.playerLayoutEpoch
        if vm.player.isReady {
            uiViewController.onPlaybackReady()
        } else {
            uiViewController.forceRelayout()
        }
    }
}

extension Notification.Name {
    static let tvPlayerNeedsRelayout = Notification.Name("tvPlayerNeedsRelayout")
}
