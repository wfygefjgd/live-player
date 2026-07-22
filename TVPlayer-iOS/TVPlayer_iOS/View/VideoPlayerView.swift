import SwiftUI
import AVKit

/// 横屏优先：高度铺满屏幕，宽度按比例居中。
/// 若按高度铺满会导致左右裁切，则退回完整装入（只留黑边、绝不裁切）。
final class PlayerContainerView: UIView {
    let playerLayer = AVPlayerLayer()
    private var sizeObserver: NSKeyValueObservation?

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.player = newValue
            observeSize()
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func observeSize() {
        sizeObserver?.invalidate()
        sizeObserver = player?.currentItem?.observe(\.presentationSize, options: [.new, .initial]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.setNeedsLayout() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bw = bounds.width
        let bh = bounds.height
        guard bw > 1, bh > 1 else {
            playerLayer.frame = bounds
            return
        }

        let vs = playerLayer.player?.currentItem?.presentationSize ?? .zero
        if vs.width > 1, vs.height > 1 {
            let videoAspect = vs.width / vs.height
            // 先按高度铺满（上下顶头）
            var layerH = bh
            var layerW = layerH * videoAspect
            if layerW > bw + 0.5 {
                // 会裁左右 → 改为完整装入，保证不裁切
                layerW = bw
                layerH = layerW / videoAspect
            }
            playerLayer.frame = CGRect(
                x: (bw - layerW) / 2,
                y: (bh - layerH) / 2,
                width: layerW,
                height: layerH
            )
        } else {
            playerLayer.frame = bounds
        }
        playerLayer.videoGravity = .resizeAspect
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
    }
}
