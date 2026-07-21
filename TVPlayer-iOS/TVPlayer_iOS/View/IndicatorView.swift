import SwiftUI

struct IndicatorView: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .foregroundColor(.white)
                .font(.title3)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.6))
                .cornerRadius(8)
        }
    }
}
