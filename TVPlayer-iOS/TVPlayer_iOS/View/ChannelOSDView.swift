import SwiftUI

struct ChannelOSDView: View {
    let text: String

    var body: some View {
        VStack {
            if !text.isEmpty {
                Text(text)
                    .foregroundColor(.white.opacity(0.7))
                    .font(.subheadline)
                    .shadow(color: .black, radius: 4)
                    .padding(.top, 48)
            }
            Spacer()
        }
    }
}
