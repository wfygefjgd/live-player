import SwiftUI
import Foundation

// MARK: - PlayerViewModel 融合功能扩展

extension PlayerViewModel {

    // MARK: - 融合观察者设置

    /// 设置融合引擎的通知观察者
    func setupFusionObserver() {
        NotificationCenter.default.addObserver(
            forName: .channelsOptimized,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let optimized = notification.object as? [Channel] {
                self.channels = self.applyRules(optimized)
                self.showIndicator("线路优化完成！")
            }
        }
    }

    // MARK: - 融合模式切换

    /// 切换融合模式
    func switchFusionMode(_ mode: FusionMode) {
        fusionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "fusionMode")
        showIndicator("已切换到 \(modeName(mode)) 模式")

        // 重新加载频道
        loadChannels(force: true, silent: false, preferActiveOnly: false)
    }

    /// 获取模式名称
    private func modeName(_ mode: FusionMode) -> String {
        switch mode {
        case .fast: return "快速"
        case .balanced: return "平衡"
        case .complete: return "完整"
        case .smart: return "智能"
        }
    }

    /// 从 UserDefaults 恢复融合模式设置
    func restoreFusionMode() {
        if let saved = UserDefaults.standard.string(forKey: "fusionMode"),
           let mode = FusionMode(rawValue: saved) {
            fusionMode = mode
        }
    }
}
