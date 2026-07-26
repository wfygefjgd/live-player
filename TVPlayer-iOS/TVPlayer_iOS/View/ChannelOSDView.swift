import SwiftUI

/// 浮动频道 OSD — 外层已用 safeArea 抬高，此处不再额外大 padding
struct ChannelOSDView: View {
    let text: String

    var body: some View {
        VStack {
            if !text.isEmpty {
                Text(text)
                    .foregroundColor(.white.opacity(0.85))
                    .font(.subheadline.weight(.medium))
                    .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.5))
                    )
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.9).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .animation(.easeOut(duration: 0.2), value: text)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}
