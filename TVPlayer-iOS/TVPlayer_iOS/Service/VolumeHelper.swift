import AVFoundation
import MediaPlayer
import UIKit

/// 系统音量调节 — 通过 MPVolumeView 公开 API 实现
/// 避免直接操作 slider.value（私有 API 风险）
enum VolumeHelper {
    private static var volumeView: MPVolumeView?
    private static var volumeSlider: UISlider?

    /// 当前系统音量 (0.0 - 1.0)
    static var current: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    private static func ensureInstalled() {
        guard volumeView == nil else {
            // 已安装但 slider 可能尚未就绪（极少情况）
            if volumeSlider == nil {
                volumeSlider = volumeView?.subviews.compactMap { $0 as? UISlider }.first
            }
            return
        }

        let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        view.alpha = 0.001
        view.isUserInteractionEnabled = false
        view.showsRouteButton = false
        volumeView = view
        volumeSlider = view.subviews.compactMap { $0 as? UISlider }.first

        if let window = keyWindow() {
            window.insertSubview(view, at: 0)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak view] in
                guard let view, let window = keyWindow(), view.superview == nil else { return }
                window.insertSubview(view, at: 0)
                if volumeSlider == nil {
                    volumeSlider = view.subviews.compactMap { $0 as? UISlider }.first
                }
            }
        }
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    /// 设置音量 (0.0 - 1.0) — 带系统音量 HUD 显示
    static func setVolume(_ value: Float) {
        ensureInstalled()
        let clamped = max(0, min(1, value))

        // 使用指数退避重试确保 slider 就绪
        ensureSlider { slider in
            guard let slider else {
                // 5 次重试后仍未获取到 slider，静默失败
                return
            }
            slider.setValue(clamped, animated: true)
        }
    }

    /// 确保 slider 就绪，带指数退避重试（最多 5 次，总计约 1.55 秒）
    private static func ensureSlider(completion: @escaping (UISlider?) -> Void) {
        // 如果已有 slider，立即回调
        if let slider = volumeSlider {
            DispatchQueue.main.async {
                completion(slider)
            }
            return
        }

        // 指数退避重试
        var attempts = 0
        func retry() {
            attempts += 1
            if attempts > 5 {
                // 超过 5 次，返回 nil
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            let delay = 0.05 * Double(attempts)  // 0.05s, 0.1s, 0.15s, 0.2s, 0.25s
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if let slider = volumeSlider ?? volumeView?.subviews.compactMap({ $0 as? UISlider }).first {
                    volumeSlider = slider
                    completion(slider)
                } else {
                    retry()
                }
            }
        }
        retry()
    }

    /// 调整音量（相对值）
    static func adjust(by delta: Float) {
        setVolume(current + delta)
    }

    /// 触觉反馈（用于音量调节时）
    static func hapticFeedback() {
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.impactOccurred(intensity: 0.5)
    }
}
