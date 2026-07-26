import SwiftUI
import UIKit

/// 侧边栏：独立 UIWindow，层级高于主界面，避免 confirmationDialog / sheet 被盖住
final class WindowPanelSurface {
    static let shared = WindowPanelSurface()

    private var overlayWindow: UIWindow?
    private let containerView = UIView(frame: .zero)
    private let maskView = UIView(frame: .zero)
    private var hostingController: UIHostingController<AnyView>?
    private(set) var isVisible = false
    private var panelWidth: CGFloat = 320

    private init() {
        maskView.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        maskView.alpha = 0
        maskView.isUserInteractionEnabled = true
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

    /// 打开设置菜单前：先把侧栏降到主 window 下，避免盖住 confirmationDialog
    func prepareForModalPresentation() {
        hide(animated: false)
    }

    func show() {
        if isVisible {
            ensureOnTop()
            return
        }
        isVisible = true
        guard ensureOverlayWindow() else {
            isVisible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.show()
            }
            return
        }

        guard let win = overlayWindow else { return }
        let bounds = win.bounds
        panelWidth = min(320, max(260, bounds.width * 0.42))

        containerView.frame = CGRect(x: -panelWidth, y: 0, width: panelWidth, height: bounds.height)
        maskView.frame = bounds
        maskView.alpha = 0
        hostingController?.view.frame = containerView.bounds
        // 不 makeKey：保持主 window 为 key，Home Indicator 策略不丢
        win.isHidden = false

        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.2, options: [.curveEaseOut, .allowUserInteraction]) {
            self.containerView.frame = CGRect(x: 0, y: 0, width: self.panelWidth, height: bounds.height)
            self.maskView.alpha = 1
        }
        if let app = UIApplication.shared.delegate as? AppDelegate {
            app.window?.makeKey()
        }
    }

    func hide(animated: Bool = true) {
        guard isVisible else {
            overlayWindow?.isHidden = true
            return
        }
        isVisible = false

        let finish: () -> Void = {
            self.maskView.removeFromSuperview()
            self.containerView.removeFromSuperview()
            self.overlayWindow?.isHidden = true
        }

        guard animated, let win = overlayWindow else {
            finish()
            return
        }
        let bounds = win.bounds
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseIn, .allowUserInteraction]) {
            self.containerView.frame = CGRect(x: -self.panelWidth, y: 0, width: self.panelWidth, height: bounds.height)
            self.maskView.alpha = 0
        } completion: { _ in
            if !self.isVisible { finish() }
        }
    }

    func ensureOnTop() {
        guard isVisible else { return }
        _ = ensureOverlayWindow()
        guard let win = overlayWindow else { return }
        let bounds = win.bounds
        panelWidth = min(320, max(260, bounds.width * 0.42))
        maskView.frame = bounds
        if containerView.frame.origin.x >= -1 {
            containerView.frame = CGRect(x: 0, y: 0, width: panelWidth, height: bounds.height)
        }
        hostingController?.view.frame = containerView.bounds
        win.bringSubviewToFront(maskView)
        win.bringSubviewToFront(containerView)
        win.isHidden = false
    }

    @discardableResult
    private func ensureOverlayWindow() -> Bool {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return false }

        if overlayWindow == nil || overlayWindow?.windowScene !== scene {
            let win = UIWindow(windowScene: scene)
            // 高于主界面，低于系统 alert；永不 makeKey，避免抢走 Home Indicator 策略
            win.windowLevel = .alert - 1
            win.backgroundColor = .clear
            win.isHidden = true
            // 空 root：同样声明隐藏小白条，防止系统问到这个 window 时显示白条
            let root = PanelRootViewController()
            win.rootViewController = root
            overlayWindow = win
        }

        guard let win = overlayWindow else { return false }
        let bounds = win.bounds.size.width > 1 ? win.bounds : scene.coordinateSpace.bounds
        win.frame = bounds

        let hostView = win.rootViewController?.view ?? win
        if maskView.superview !== hostView {
            maskView.removeFromSuperview()
            hostView.addSubview(maskView)
        }
        maskView.frame = hostView.bounds

        if containerView.superview !== hostView {
            containerView.removeFromSuperview()
            hostView.addSubview(containerView)
        }
        hostView.bringSubviewToFront(maskView)
        hostView.bringSubviewToFront(containerView)
        // 明确不抢 keyWindow
        win.isHidden = win.isHidden
        return true
    }
}

/// 侧栏 window 的 root：不抢 key
private final class PanelRootViewController: UIViewController {
    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
    }
}

extension Notification.Name {
    static let panelShouldClose = Notification.Name("panelShouldClose")
}
