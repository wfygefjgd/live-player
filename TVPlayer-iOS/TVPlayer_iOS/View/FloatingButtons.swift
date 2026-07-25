import SwiftUI

/// 悬浮控制按钮 — 带触觉反馈
struct FloatingButtons: View {
    let panelVisible: Bool
    let locked: Bool
    let onTogglePanel: () -> Void
    let onLongPanel: () -> Void
    let onToggleLock: () -> Void
    let onLongLock: () -> Void

    var body: some View {
        ZStack {
            // 左上角：切换面板
            VStack {
                HStack {
                    circleButton(
                        icon: panelVisible ? "◀" : "▶",
                        action: {
                            onTogglePanel()
                            haptic(.light)
                        },
                        onLongPress: onLongPanel
                    )
                    .opacity(locked ? 0 : 1)
                    .animation(.easeInOut(duration: 0.15), value: locked)

                    Spacer()
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)

            // 左下角：锁定
            VStack {
                Spacer()
                HStack {
                    circleButton(
                        icon: locked ? "🔒" : "🔓",
                        action: {
                            onToggleLock()
                            haptic(.medium)
                        },
                        onLongPress: onLongLock
                    )
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private func circleButton(
        icon: String,
        action: @escaping () -> Void,
        onLongPress: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.4))
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                )
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    haptic(.heavy)
                    onLongPress()
                }
        )
        .buttonStyle(PlainButtonStyle())
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
}
