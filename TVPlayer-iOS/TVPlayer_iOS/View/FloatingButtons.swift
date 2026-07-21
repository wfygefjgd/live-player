import SwiftUI

struct FloatingButtons: View {
    let panelVisible: Bool
    let locked: Bool
    let onTogglePanel: () -> Void
    let onLongPanel: () -> Void
    let onToggleLock: () -> Void
    let onLongLock: () -> Void

    var body: some View {
        ZStack {
            // Top-left: toggle panel
            VStack {
                HStack {
                    Button(action: onTogglePanel) {
                        Text(panelVisible ? "◀" : "▶")
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.35))
                            .cornerRadius(8)
                    }
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5)
                            .onEnded { _ in onLongPanel() }
                    )
                    .opacity(locked ? 0 : 1)
                    Spacer()
                }
                Spacer()
            }
            .padding(8)

            // Bottom-left: lock
            VStack {
                Spacer()
                HStack {
                    Button(action: onToggleLock) {
                        Text(locked ? "🔒" : "🔓")
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.35))
                            .cornerRadius(8)
                    }
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5)
                            .onEnded { _ in onLongLock() }
                    )
                    Spacer()
                }
            }
            .padding(8)
        }
    }
}
