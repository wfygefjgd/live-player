import UIKit

/// 方向策略：固定横屏（竖→横冲击试验已废弃，iPhone Air 无效）
enum OrientationBootstrap {
    private(set) static var allowedMask: UIInterfaceOrientationMask = .landscape
    private static var didPrime = false

    static var isLandscapeLocked: Bool { true }

    static func resetForColdLaunch() {
        didPrime = false
        allowedMask = .landscape
    }

    /// 兼容旧调用：不再做竖屏，直接锁横屏并触发与「回前台」同等的 hard remount
    static func schedulePortraitToLandscapeShock(after delay: TimeInterval = 0) {
        lockLandscapeAndRefresh()
    }

    static func lockLandscapeAndRefresh() {
        allowedMask = .landscape
        applyLandscape()

        // 与 applicationDidBecomeActive 同路径：多次 hardRemount
        let delays: [TimeInterval] = [0.0, 0.05, 0.15, 0.35, 0.7, 1.2, 2.0]
        for t in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                WindowVideoSurface.shared.hardRemount(reason: "landscape-prime-\(t)")
                if let app = UIApplication.shared.delegate as? AppDelegate {
                    app.refreshChromeAndVideo(reason: "landscape-prime")
                }
            }
        }
        didPrime = true
    }

    /// 出画后 / 尺寸变化后：模拟「切后台再回来」的那一次有效恢复
    static func simulateForegroundRecovery(reason: String) {
        if let app = UIApplication.shared.delegate as? AppDelegate {
            app.refreshChromeAndVideo(reason: "sim-fg-\(reason)")
            app.simulateBecomeActiveRecovery()
        } else {
            WindowVideoSurface.shared.hardRemount(reason: "sim-fg-\(reason)")
        }
    }

    private static func applyLandscape() {
        allowedMask = .landscape
        if #available(iOS 16.0, *) {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscape)
                scene.requestGeometryUpdate(prefs) { _ in }
                scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            }
        }
    }
}
