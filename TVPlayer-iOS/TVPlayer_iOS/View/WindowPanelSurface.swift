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
    private var panelWidth: CGFloat = 280
    /// 刚打开时忽略遮罩点击，避免长按抬手点到 mask 立刻关掉
    private var ignoreMaskTapUntil: Date = .distantPast

    private init() {
        maskView.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        maskView.alpha = 0
        maskView.isUserInteractionEnabled = true
        containerView.backgroundColor = UIColor(white: 0.12, alpha: 0.98)
        containerView.clipsToBounds = true
        containerView.layer.cornerRadius = 0
        containerView.layer.shadowColor = UIColor.black.cgColor
        containerView.layer.shadowOpacity = 0.28
        containerView.layer.shadowRadius = 8
        containerView.layer.shadowOffset = CGSize(width: 2, height: 0)
        containerView.isUserInteractionEnabled = true
    }

    func setPanel(_ panel: AnyView, viewModel: PlayerViewModel) {
        if let existing = hostingController {
            existing.rootView = panel
        } else {
            let hosting = UIHostingController(rootView: panel)
            hosting.view.backgroundColor = .clear
            hosting.view.translatesAutoresizingMaskIntoConstraints = true
            hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            hosting.view.isUserInteractionEnabled = true
            containerView.addSubview(hosting.view)
            hostingController = hosting
        }
        // 预先挂到 window，保证首次 show 时 SwiftUI 已有正确 bounds
        _ = ensureOverlayWindow()
        layoutPanelViews(animated: false, open: false)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(maskTapped))
        tapGesture.cancelsTouchesInView = false
        maskView.gestureRecognizers?.forEach { maskView.removeGestureRecognizer($0) }
        maskView.addGestureRecognizer(tapGesture)
    }

    @objc private func maskTapped() {
        guard Date() >= ignoreMaskTapUntil else { return }
        NotificationCenter.default.post(name: .panelShouldClose, object: nil)
    }

    /// 打开设置菜单前：先把侧栏藏起，避免盖住 confirmationDialog
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
        // 抬手误触保护：约 0.45s 内点遮罩不关
        ignoreMaskTapUntil = Date().addingTimeInterval(0.45)

        layoutPanelViews(animated: false, open: false)
        hostingController?.view.setNeedsLayout()
        hostingController?.view.layoutIfNeeded()
        win.isHidden = false
        win.layoutIfNeeded()

        // 再强制一帧正确尺寸（修复首次弹出 UI 未自适应）
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.layoutPanelViews(animated: false, open: false)
            self.hostingController?.view.setNeedsLayout()
            self.hostingController?.view.layoutIfNeeded()
            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                usingSpringWithDamping: 0.9,
                initialSpringVelocity: 0.15,
                options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
            ) {
                self.layoutPanelViews(animated: false, open: true)
                self.maskView.alpha = 1
            }
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
            // 不移除 subview，只隐藏 window，避免下次首次布局错乱
            self.overlayWindow?.isHidden = true
            self.maskView.alpha = 0
            self.layoutPanelViews(animated: false, open: false)
        }

        guard animated else {
            finish()
            return
        }
        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            options: [.curveEaseIn, .allowUserInteraction, .beginFromCurrentState]
        ) {
            self.layoutPanelViews(animated: false, open: false)
            self.maskView.alpha = 0
        } completion: { _ in
            if !self.isVisible { finish() }
        }
    }

    func ensureOnTop() {
        guard isVisible else { return }
        _ = ensureOverlayWindow()
        layoutPanelViews(animated: false, open: true)
        maskView.alpha = 1
        hostingController?.view.setNeedsLayout()
        hostingController?.view.layoutIfNeeded()
        guard let win = overlayWindow else { return }
        win.bringSubviewToFront(maskView)
        win.bringSubviewToFront(containerView)
        win.isHidden = false
    }

    private func layoutPanelViews(animated: Bool, open: Bool) {
        guard let win = overlayWindow else { return }
        let sceneBounds = win.windowScene?.coordinateSpace.bounds ?? win.bounds
        let bounds = (win.bounds.width > 1 ? win.bounds : sceneBounds)
        if win.bounds.size != bounds.size {
            win.frame = CGRect(origin: .zero, size: bounds.size)
        }
        // 横屏灵动岛在左侧：侧栏整体右移，避免频道名被岛遮挡
        // 全屏/隐藏状态栏时 window.safeArea 常为 0，需从 scene 与设备兜底取值
        let safe = effectiveSafeAreaInsets(for: win)
        let isLandscape = bounds.width > bounds.height
        // 有系统 safe.left 用系统值；否则横屏兜底避开灵动岛
        let islandFallback: CGFloat = (isLandscape && safe.left < 1) ? 54 : 0
        let leadingInset = max(safe.left, islandFallback)
        let topInset = max(safe.top, isLandscape ? 10 : 12)
        let bottomInset = max(safe.bottom, 0)
        let maxW = max(200, bounds.width - leadingInset - 32)
        panelWidth = min(252, max(216, min(bounds.width * 0.33, maxW)))
        maskView.frame = CGRect(origin: .zero, size: bounds.size)
        let openX = leadingInset
        let x: CGFloat = open ? openX : (openX - panelWidth)
        let y = topInset
        let h = max(1, bounds.height - y - bottomInset)
        containerView.frame = CGRect(x: x, y: y, width: panelWidth, height: h)
        containerView.layer.cornerRadius = 12
        containerView.layer.maskedCorners = [
            .layerMaxXMinYCorner, .layerMaxXMaxYCorner,
            .layerMinXMinYCorner, .layerMinXMaxYCorner
        ]
        hostingController?.view.frame = containerView.bounds
    }

    /// 合并 window / scene / keyWindow 的 safeArea，避免全屏层读到全 0
    private func effectiveSafeAreaInsets(for win: UIWindow) -> UIEdgeInsets {
        var inset = win.safeAreaInsets
        if let scene = win.windowScene {
            for w in scene.windows {
                let s = w.safeAreaInsets
                inset.left = max(inset.left, s.left)
                inset.right = max(inset.right, s.right)
                inset.top = max(inset.top, s.top)
                inset.bottom = max(inset.bottom, s.bottom)
            }
        }
        return inset
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
            win.windowLevel = .alert - 1
            win.backgroundColor = .clear
            win.isHidden = true
            let root = PanelRootViewController()
            win.rootViewController = root
            overlayWindow = win
        }

        guard let win = overlayWindow else { return false }
        let bounds = win.bounds.size.width > 1 ? win.bounds : scene.coordinateSpace.bounds
        win.frame = CGRect(origin: .zero, size: bounds.size)

        let hostView = win.rootViewController?.view ?? win
        if maskView.superview !== hostView {
            maskView.removeFromSuperview()
            hostView.addSubview(maskView)
        }
        if containerView.superview !== hostView {
            containerView.removeFromSuperview()
            hostView.addSubview(containerView)
        }
        hostView.bringSubviewToFront(maskView)
        hostView.bringSubviewToFront(containerView)
        return true
    }
}

private final class PanelRootViewController: UIViewController {
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
    }
}

extension Notification.Name {
    static let panelShouldClose = Notification.Name("panelShouldClose")
}
