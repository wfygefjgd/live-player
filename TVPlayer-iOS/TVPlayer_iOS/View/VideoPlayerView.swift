import SwiftUI
import AVKit
import UIKit
import Combine

/// 最简全屏：AVPlayerLayer 作为 view.layer，frame 永远 = 物理全屏。
/// resizeAspectFill：铺满、可轻微裁切，消除「四边大黑边」。
final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    private var cancellables = Set<AnyCancellable>()
    private var delayItems: [DispatchWorkItem] = []

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.player = newValue
            playerLayer.videoGravity = .resizeAspectFill
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        clipsToBounds = true
        isUserInteractionEnabled = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = UIColor.black.cgColor

        for name: Notification.Name in [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification,
            UIDevice.orientationDidChangeNotification,
            .tvPlayerNeedsRelayout
        ] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.applyFullscreenFrame()
                    self?.schedulePasses()
                }
                .store(in: &cancellables)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        delayItems.forEach { $0.cancel() }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyFullscreenFrame()
        schedulePasses()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyFullscreenFrame()
    }

    func applyFullscreenFrame() {
        // 物理全屏矩形（横屏时用 window.bounds，已含 home 区）
        let target: CGRect
        if let window = window {
            target = convert(window.bounds, from: nil)
        } else if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let win = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first {
            target = convert(win.bounds, from: nil)
        } else {
            let b = UIScreen.main.bounds
            // 横屏 App：宽高可能瞬时颠倒，取实际较大区域
            target = CGRect(x: 0, y: 0, width: max(b.width, b.height), height: min(b.width, b.height))
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 自身也尽量铺满父视图
        if let superview, superview.bounds.width > 1 {
            frame = superview.bounds
        }
        // layer 铺满「转换后的 window 全屏」；若比 bounds 大，允许画出 view（父级需不 clip）
        playerLayer.frame = target
        // 若 target 无效，退回 bounds
        if playerLayer.frame.width < 2 || playerLayer.frame.height < 2 {
            playerLayer.frame = bounds
        }
        // 至少盖住自己
        if playerLayer.frame.width < bounds.width || playerLayer.frame.height < bounds.height {
            playerLayer.frame = bounds
        }
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.isHidden = false
        playerLayer.opacity = 1
        CATransaction.commit()
    }

    private func schedulePasses() {
        delayItems.forEach { $0.cancel() }
        delayItems.removeAll()
        for t in [0.0, 0.05, 0.12, 0.3, 0.6, 1.0] {
            let item = DispatchWorkItem { [weak self] in self?.applyFullscreenFrame() }
            delayItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: item)
        }
    }
}

struct VideoPlayerView: UIViewRepresentable {
    @EnvironmentObject private var vm: PlayerViewModel

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.player = vm.player.player
        return v
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.player !== vm.player.player {
            uiView.player = vm.player.player
        }
        _ = vm.playerLayoutEpoch
        uiView.applyFullscreenFrame()
        if vm.player.isReady {
            uiView.applyFullscreenFrame()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: PlayerUIView,
        context: Context
    ) -> CGSize? {
        let b = UIScreen.main.bounds
        let sw = max(b.width, b.height)
        let sh = min(b.width, b.height)
        return CGSize(
            width: max(proposal.width ?? sw, sw),
            height: max(proposal.height ?? sh, sh)
        )
    }
}

extension Notification.Name {
    static let tvPlayerNeedsRelayout = Notification.Name("tvPlayerNeedsRelayout")
}
