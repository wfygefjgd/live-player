import SwiftUI

struct SourceManagementSheet: View {
    @EnvironmentObject private var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var inputUrl = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                Text("输入 m3u / m3u8 地址")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)

                TextField("https://...", text: $inputUrl)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                HStack(spacing: 12) {
                    Button("添加") { add() }
                        .buttonStyle(.borderedProminent)
                    Button("删除", role: .destructive) { delete() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("关闭") { dismiss() }
                }

                List {
                    ForEach(Array(vm.sourceUrls.enumerated()), id: \.offset) { (i, url) in
                        HStack {
                            Text(url == vm.activeSourceUrl ? "\u{25CF}" : "\u{25CB}")
                                .foregroundColor(url == vm.activeSourceUrl ? .blue : .gray)
                            Text(label(for: url))
                                .lineLimit(1)
                                .font(.body)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vm.selectSource(url)
                            dismiss()
                        }
                    }
                }
                .listStyle(.plain)
            }
            .padding()
            .navigationTitle("选择直播源")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func label(for url: String) -> String {
        if url == DEFAULT_SOURCE_URL { return "\u{9ED8}\u{8BA4}\u{6E90}" }
        return url
    }

    private func add() {
        let url = inputUrl.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        vm.selectSource(url)
        inputUrl = ""
        dismiss()
    }

    private func delete() { }
}
