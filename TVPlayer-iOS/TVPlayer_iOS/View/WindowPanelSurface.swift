import SwiftUI
import UIKit

/// Window 级侧边栏浮层 - 完全覆盖小白条区域
/// 必须始终压在 WindowVideoSurface 之上，避免画面层 install 重排后被遮挡
final class WindowPanelSurface {
    static let shared = WindowPanelSurface()

    private let containerView = UIView(frame: .zero)
    private let maskView = UIView(frame: .zero)
    private var hostingController: UIHostingController<AnyView>?
    private(set) var isVisible = false
    private var panelWidth: CGFloat = 320

    private init() {
        maskView.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        maskView.alpha = 0
        maskView.isUserInteractionEnabled = true
        // 高于默认层级，避免被其它 window 子视图盖住
        maskView.layer.zPosition = 9_000
        containerView.layer.zPosition = 9_001

        containerView.backgroundColor = UIColor(white: 0.12, alpha: 0.98)
        containerView.clipsToBounds = false
        containerView.layer.shadowColor = UIColor.black.cgColor
        containerView.layer.shadowOpacity = 0.35
        containerView.layer.shadowRadius = 10
        containerView.layer.shadowOffset = CGSize(width: 3, height: 0)
        containerView.isUserInteractionEnabled = true
    }

    func setPanel(_ panel: AnyView, viewModel: PlayerViewModel) {
        if let existing = hostingController {
            existing.rootView = panel
        } else {
            let hosting = UIHostingController(rootView: panel)
            hosting.view.backgroundColor = .clear
            hosting.view.frame = containerView.bounds
            hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            hosting.view.isUserInteractionEnabled = true
            containerView.addSubview(hosting.view)
            hostingController = hosting
        }

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(maskTapped))
        maskView.gestureRecognizers?.forEach { maskView.removeGestureRecognizer($0) }
        maskView.addGestureRecognizer(tapGesture)
    }

    @objc private func maskTapped() {
        NotificationCenter.default.post(name: .panelShouldClose, object: nil)
    }

    func show() {
        if isVisible {
            // 已显示时仍强制置顶 + 校正尺寸（防止被画面层 install 压住）
            ensureOnTop()
            return
        }
        isVisible = true
        guard install() else {
            // window 尚未就绪：短延迟重试
            isVisible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.show()
            }
            return
        }

        guard let window = keyWindow() else { return }
        let bounds = window.bounds
        panelWidth = min(320, max(260, bounds.width * 0.42))

        containerView.frame = CGRect(x: -panelWidth, y: 0, width: panelWidth, height: bounds.height)
        maskView.frame = bounds
        maskView.alpha = 0
        hostingController?.view.frame = containerView.bounds

        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.2, options: [.curveEaseOut, .allowUserInteraction]) {
            self.containerView.frame = CGRect(x: 0, y: 0, width: self.panelWidth, height: bounds.height)
            self.maskView.alpha = 1
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false

        guard let window = keyWindow() else {
            uninstall()
            return
        }
        let bounds = window.bounds
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseIn, .allowUserInteraction]) {
            self.containerView.frame = CGRect(x: -self.panelWidth, y: 0, width: self.panelWidth, height: bounds.height)
            self.maskView.alpha = 0
        } completion: { _ in
            if !self.isVisible {
                self.uninstall()
            }
        }
    }

    /// 画面层每次 install 后调用：保证侧边栏仍在最顶层
    func ensureOnTop() {
        guard isVisible else { return }
        _ = install()
        guard let window = keyWindow() else { return }
        let bounds = window.bounds
        panelWidth = min(320, max(260, bounds.width * 0.42))
        maskView.frame = bounds
        // 展开状态保持 x=0
        if containerView.frame.origin.x >= -1 {
            containerView.frame = CGRect(x: 0, y: 0, width: panelWidth, height: bounds.height)
        }
        hostingController?.view.frame = containerView.bounds
        window.bringSubviewToFront(maskView)
        window.bringSubviewToFront(containerView)
    }

    @discardableResult
    private func install() -> Bool {
        guard let window = keyWindow() else { return false }
        let bounds = window.bounds

        if maskView.superview !== window {
            maskView.removeFromSuperview()
            window.addSubview(maskView)
        }
        maskView.frame = bounds

        if containerView.superview !== window {
            containerView.removeFromSuperview()
            window.addSubview(containerView)
        }

        window.bringSubviewToFront(maskView)
        window.bringSubviewToFront(containerView)
        return true
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
