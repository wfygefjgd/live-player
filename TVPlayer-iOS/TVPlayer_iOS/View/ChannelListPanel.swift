import SwiftUI

struct ChannelListPanel: View {
    @EnvironmentObject private var vm: PlayerViewModel
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var onShowSettings: (() -> Void)?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // 🆕 安全区域顶部占位，确保工具栏不被遮挡
                Color.clear
                    .frame(height: geo.safeAreaInsets.top > 0 ? geo.safeAreaInsets.top : 0)

                // 顶部工具栏：设置按钮 + 搜索框
                HStack(spacing: 12) {
                    // 设置按钮
                    Button {
                        onShowSettings?()
                        haptic(.light)
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)

                    // 搜索框
                    HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                        .font(.caption)

                    TextField("搜索频道", text: $searchText)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit {
                            // 提交搜索后可以收起键盘
                            searchFocused = false
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding(8)
                .background(Color(white: 0.16))
                .cornerRadius(6)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                }
                .background(Color(white: 0.12))

                // 频道列表
            ScrollViewReader { proxy in
                List {
                    ForEach(vm.sections(search: searchText)) { section in
                        Section {
                            ForEach(section.channels, id: \.id) { ch in
                                channelRow(ch)
                                    .id(ch.key)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(rowBackground(for: ch))
                            }
                        } header: {
                            Text(section.title)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color(white: 0.12))
                .onAppear { scrollToCurrent(proxy) }
                .onChange(of: vm.panelVisible) { visible in
                    if visible { scrollToCurrent(proxy) }
                }
                .onChange(of: vm.currentIndex) { _ in
                    if vm.panelVisible { scrollToCurrent(proxy) }
                }
            }

            // 底部状态栏
            Text(vm.indicatorText.isEmpty
                 ? "已加载 \(vm.channels.count) 个频道"
                 : vm.indicatorText)
                .font(.caption2)
                .foregroundColor(.gray)
                .padding(4)
            }
            .background(Color(white: 0.12))
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let key = vm.currentChannel?.key else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(key, anchor: .center)
            }
        }
    }

    private func rowBackground(for ch: Channel) -> Color {
        // 高亮当前台（按 key，不依赖 raw 下标）
        if ch.key == vm.currentChannel?.key {
            return Color(red: 0.035, green: 0.278, blue: 0.443)
        }
        return Color(white: 0.12)
    }

    private func channelRow(_ ch: Channel) -> some View {
        HStack(spacing: 8) {
            Button { vm.selectChannel(ch) } label: {
                HStack {
                    Text(ch.name)
                        .foregroundColor(.white)
                        .font(.body)
                        .lineLimit(1)
                    Spacer()
                    if ch.sourceCount > 1 {
                        Text("\(ch.sourceCount)")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { vm.toggleFavorite(for: ch) } label: {
                Text(vm.isFavorite(ch) ? "★" : "☆")
                    .foregroundColor(vm.isFavorite(ch) ? .yellow : .gray)
                    .font(.body)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
}
