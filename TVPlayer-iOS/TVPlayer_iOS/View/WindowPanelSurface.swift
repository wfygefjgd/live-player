import SwiftUI
import UIKit

/// Window 级侧边栏浮层 - 完全覆盖小白条区域
final class WindowPanelSurface {
    static let shared = WindowPanelSurface()

    private let containerView = UIView(frame: .zero)
    private let maskView = UIView(frame: .zero)
    private var hostingController: UIHostingController<AnyView>?
    private var isVisible = false

    private init() {
        // 遮罩层配置
        maskView.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        maskView.alpha = 0
        maskView.isUserInteractionEnabled = true

        // 侧边栏容器配置
        containerView.backgroundColor = UIColor(white: 0.12, alpha: 0.98)
        containerView.clipsToBounds = true
        containerView.layer.shadowColor = UIColor.black.cgColor
        containerView.layer.shadowOpacity = 0.3
        containerView.layer.shadowRadius = 8
        containerView.layer.shadowOffset = CGSize(width: 2, height: 0)
    }

    func setPanel(_ panel: AnyView, viewModel: PlayerViewModel) {
        if let existing = hostingController {
            existing.rootView = panel
        } else {
            let hosting = UIHostingController(rootView: panel)
            hosting.view.backgroundColor = .clear
            hosting.view.frame = containerView.bounds
            hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            containerView.addSubview(hosting.view)
            hostingController = hosting
        }

        // 添加遮罩层点击手势
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(maskTapped))
        maskView.gestureRecognizers?.forEach { maskView.removeGestureRecognizer($0) }
        maskView.addGestureRecognizer(tapGesture)
    }

    @objc private func maskTapped() {
        NotificationCenter.default.post(name: .panelShouldClose, object: nil)
    }

    func show() {
        guard !isVisible else { return }
        isVisible = true
        install()

        guard let window = keyWindow() else { return }
        let screenBounds = window.bounds

        // 初始位置：从左侧屏幕外
        containerView.frame = CGRect(
            x: -320,
            y: 0,
            width: 320,
            height: screenBounds.height
        )

        // 动画滑入
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, options: .curveEaseOut) {
            self.containerView.frame = CGRect(
                x: 0,
                y: 0,
                width: 320,
                height: screenBounds.height
            )
            self.maskView.alpha = 1
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false

        guard let window = keyWindow() else { return }
        let screenBounds = window.bounds

        // 动画滑出
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, options: .curveEaseIn) {
            self.containerView.frame = CGRect(
                x: -320,
                y: 0,
                width: 320,
                height: screenBounds.height
            )
            self.maskView.alpha = 0
        } completion: { _ in
            self.uninstall()
        }
    }

    private func install() {
        guard let window = keyWindow() else { return }
        let screenBounds = window.bounds

        // 遮罩层全屏
        if maskView.superview !== window {
            maskView.removeFromSuperview()
            window.addSubview(maskView)
        }
        maskView.frame = screenBounds

        // 侧边栏容器
        if containerView.superview !== window {
            containerView.removeFromSuperview()
            window.addSubview(containerView)
        }

        // 确保在最顶层
        window.bringSubviewToFront(maskView)
        window.bringSubviewToFront(containerView)
    }

    private func uninstall() {
        maskView.removeFromSuperview()
        containerView.removeFromSuperview()
    }

    private func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive {
            if let w = scene.windows.first(where: \.isKeyWindow) { return w }
            if let w = scene.windows.first { return w }
        }
        return scenes.flatMap(\.windows).first
    }
}

extension Notification.Name {
    static let panelShouldClose = Notification.Name("panelShouldClose")
}
