import SwiftUI
import AVKit
import UIKit

/// 真正全屏：layer 永远等于 window.bounds，videoGravity = resizeAspectFill
/// 解决「中间一小块、四边黑框」——那是容器没铺满，不是直播天生如此。
final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.player = newValue
            applyFill()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        clipsToBounds = true
        isUserInteractionEnabled = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        applyFill()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyFill() {
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = UIColor.black.cgColor
        playerLayer.masksToBounds = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 强制与父视图同大，禁止系统动画导致短暂缩在中间
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if playerLayer.superlayer !== layer {
            layer.addSublayer(playerLayer)
        }
        playerLayer.frame = bounds
        playerLayer.videoGravity = .resizeAspectFill
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
        layoutIfNeeded()
    }
}

struct VideoPlayerView: UIViewRepresentable {
    @EnvironmentObject private var vm: PlayerViewModel

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.player = vm.player.player
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        if uiView.player !== vm.player.player {
            uiView.player = vm.player.player
        }
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
    }

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: ()) {
        uiView.player = nil
    }
}
