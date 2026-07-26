import UIKit

/// 冷启动：先竖屏黑屏 → 极短延迟切横屏，用旋转「冲击」系统 safe area / Home Indicator 布局。
/// 用户方案试验版：尽量短、黑屏掩盖，减少可感知闪动。
enum OrientationBootstrap {
    /// 启动阶段允许的方向；切到横屏后固定为 landscape
    private(set) static var allowedMask: UIInterfaceOrientationMask = .portrait
    private static var didKick = false
    private static var landscapeLocked = false

    static var isLandscapeLocked: Bool { landscapeLocked }

    static func resetForColdLaunch() {
        didKick = false
        landscapeLocked = false
        allowedMask = .portrait
    }

    /// 在 window 已 key 后调用：竖屏停留约 0.28s（黑屏）再切横屏
    static func schedulePortraitToLandscapeShock(after delay: TimeInterval = 0.28) {
        guard !didKick else { return }
        didKick = true
        allowedMask = .portrait
        landscapeLocked = false

        // 立刻请求竖屏（启动可能已是横屏设备姿态，仍强制走一遍）
        applyMask(.portrait, preferred: .portrait)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            lockLandscapeAndRefresh()
        }
    }

    static func lockLandscapeAndRefresh() {
        landscapeLocked = true
        allowedMask = .landscape
        applyMask(.landscape, preferred: .landscapeRight)

        // 旋转动画帧后再钉画面
        let delays: [TimeInterval] = [0.0, 0.05, 0.12, 0.25, 0.45, 0.8]
        for t in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                if let app = UIApplication.shared.delegate as? AppDelegate {
                    app.refreshChromeAndVideo(reason: "orient-shock")
                } else {
                    WindowVideoSurface.shared.forceFullBleed(reason: "orient-shock")
                    WindowVideoSurface.shared.rebindPlayer()
                }
            }
        }
    }

    private static func applyMask(_ mask: UIInterfaceOrientationMask, preferred: UIInterfaceOrientation) {
        allowedMask = mask

        // 通知系统重新询问 supportedInterfaceOrientations
        if #available(iOS 16.0, *) {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
                scene.requestGeometryUpdate(prefs) { _ in }
                scene.windows.forEach { win in
                    win.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
            }
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
            let value: Int
            switch preferred {
            case .portrait: value = UIInterfaceOrientation.portrait.rawValue
            case .landscapeLeft: value = UIInterfaceOrientation.landscapeLeft.rawValue
            case .landscapeRight: value = UIInterfaceOrientation.landscapeRight.rawValue
            default: value = UIInterfaceOrientation.landscapeRight.rawValue
            }
            UIDevice.current.setValue(value, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }

        // 再刷一次 VC 策略
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for win in scene.windows {
                win.rootViewController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
                win.rootViewController?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
                if #available(iOS 16.0, *) {
                    win.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
            }
        }
    }
}
