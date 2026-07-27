import SwiftUI

struct ChannelListPanel: View {
    @EnvironmentObject private var vm: PlayerViewModel
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var onShowSettings: (() -> Void)?

    var body: some View {
        GeometryReader { geo in
            // 容器已右移；列表文字再内收，避免贴边/贴岛
            let topPad = max(geo.safeAreaInsets.top, 8) + 14
            let leadPad = max(geo.safeAreaInsets.leading, 14) + 6
            let trailPad = max(geo.safeAreaInsets.trailing, 10)

            VStack(spacing: 0) {
                Color.clear
                    .frame(height: topPad)

                // 顶部：设置 + 搜索
                HStack(spacing: 8) {
                    Button {
                        onShowSettings?()
                        haptic(.light)
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                            .font(.system(size: 12))

                        TextField("搜索", text: $searchText)
                            .textFieldStyle(.plain)
                            .foregroundColor(.white)
                            .font(.system(size: 14))
                            .focused($searchFocused)
                            .submitLabel(.search)
                            .onSubmit { searchFocused = false }

                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.gray)
                                    .font(.system(size: 13))
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.16))
                    .cornerRadius(6)
                }
                .padding(.leading, leadPad)
                .padding(.trailing, trailPad)
                .padding(.vertical, 8)
                .background(Color(white: 0.12))

                ScrollViewReader { proxy in
                    List {
                        ForEach(vm.sections(search: searchText)) { section in
                            Section {
                                ForEach(section.channels, id: \.id) { ch in
                                    channelRow(ch)
                                        .id(ch.key)
                                        .listRowInsets(EdgeInsets(
                                            top: 1,
                                            leading: leadPad,
                                            bottom: 1,
                                            trailing: trailPad
                                        ))
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(rowBackground(for: ch))
                                }
                            } header: {
                                Text(section.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.gray)
                                    .textCase(nil)
                                    .padding(.leading, max(0, leadPad - 8))
                            }
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.defaultMinListRowHeight, 32)
                    .scrollContentBackground(.hidden)
                    .background(Color(white: 0.12))
                    .onAppear {
                        scrollToCurrent(proxy)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            scrollToCurrent(proxy)
                        }
                    }
                    .onChange(of: vm.panelVisible) { visible in
                        if visible {
                            scrollToCurrent(proxy)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                scrollToCurrent(proxy)
                            }
                        }
                    }
                    .onChange(of: vm.currentIndex) { _ in
                        if vm.panelVisible { scrollToCurrent(proxy) }
                    }
                }

                Text(
                    vm.indicatorText.isEmpty
                        ? "\(vm.channels.count) 频道"
                        : vm.indicatorText
                )
                .font(.system(size: 10))
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .padding(.leading, leadPad)
                .padding(.trailing, trailPad)
                .background(Color(white: 0.1))
            }
            .background(Color(white: 0.12))
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let key = vm.currentChannel?.key else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.15)) {
                proxy.scrollTo(key, anchor: .center)
            }
        }
    }

    private func rowBackground(for ch: Channel) -> Color {
        if ch.key == vm.currentChannel?.key {
            return Color(red: 0.035, green: 0.278, blue: 0.443)
        }
        return Color(white: 0.12)
    }

    private func channelRow(_ ch: Channel) -> some View {
        HStack(spacing: 6) {
            Button { vm.selectChannel(ch) } label: {
                HStack(spacing: 4) {
                    Text(ch.name)
                        .foregroundColor(.white)
                        .font(.system(size: 14))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if ch.sourceCount > 1 {
                        Text("\(ch.sourceCount)")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { vm.toggleFavorite(for: ch) } label: {
                Text(vm.isFavorite(ch) ? "★" : "☆")
                    .foregroundColor(vm.isFavorite(ch) ? .yellow : .gray)
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 1)
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
