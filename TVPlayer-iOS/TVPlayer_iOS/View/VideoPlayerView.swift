import SwiftUI
import AVKit

/// 水管式布局：高度贴满屏幕，宽度按视频比例居中（左右可溢出/留黑，不裁切画面）
final class PlayerContainerView: UIView {
    let playerLayer = AVPlayerLayer()
    private var sizeObserver: NSKeyValueObservation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = false
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func bind(player: AVPlayer) {
        playerLayer.player = player
        sizeObserver?.invalidate()
        sizeObserver = player.currentItem?.observe(\.presentationSize, options: [.new, .initial]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.setNeedsLayout() }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bh = bounds.height
        let bw = bounds.width
        guard bh > 0, bw > 0 else {
            playerLayer.frame = bounds
            return
        }
        let videoSize = playerLayer.player?.currentItem?.presentationSize ?? .zero
        if videoSize.width > 1, videoSize.height > 1 {
            // 以高度为基准（水管只管上下），宽度按比例，水平居中
            let aspect = videoSize.width / videoSize.height
            let layerH = bh
            let layerW = layerH * aspect
            playerLayer.frame = CGRect(
                x: (bw - layerW) / 2,
                y: 0,
                width: layerW,
                height: layerH
            )
        } else {
            playerLayer.frame = bounds
        }
    }
}

struct VideoPlayerView: UIViewRepresentable {
    @EnvironmentObject private var vm: PlayerViewModel

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.bind(player: vm.player.player)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.bind(player: vm.player.player)
        uiView.setNeedsLayout()
    }
}
