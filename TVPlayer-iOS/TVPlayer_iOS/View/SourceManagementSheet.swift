import SwiftUI

struct SourceManagementSheet: View {
    @EnvironmentObject private var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var inputUrl = ""
    @State private var showInvalidAlert = false

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("输入 m3u / m3u8 地址", text: $inputUrl)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)
                            .submitLabel(.done)
                            .onSubmit { add() }

                        Button("添加") { add() }
                            .buttonStyle(.borderedProminent)
                            .disabled(inputUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if inputUrl.isEmpty {
                        Button {
                            if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                                inputUrl = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "doc.on.clipboard")
                                Text("粘贴剪贴板内容")
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                List {
                    Section {
                        Toggle(isOn: Binding(
                            get: { vm.lineTimeoutEnabled },
                            set: { vm.setLineTimeoutEnabled($0) }
                        )) {
                            HStack {
                                Image(systemName: "timer")
                                    .foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("线路超时")
                                    Text("关闭后不会因超时、卡顿自动换线")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("播放设置")
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("TVPlayer 1.8 稳定版")
                                .font(.headline)
                            Text("• 源可以自定义，支持添加和切换 M3U / M3U8 地址")
                            Text("• 支持预置源与自定义源切换，频道列表可自动刷新")
                            Text("• 支持多线路自动换线，遇到超时、卡顿、无声会自动切线")
                            Text("• 支持收藏频道、隐藏线路、后台音频播放")
                            Text("• 支持键盘数字选台与手势切台")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                    } header: {
                        Text("版本说明")
                    }

                    Section {
                        ForEach(Array(vm.sourceUrls.enumerated()), id: \.element) { i, url in
                            sourceRow(index: i, url: url)
                        }
                        .onDelete { offsets in
                            deleteSources(at: offsets)
                        }
                    } header: {
                        HStack {
                            Text("当前源：\(activeSourceLabel)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .padding(.vertical)
            .navigationTitle("切换来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("重置") {
                        resetToDefault()
                    }
                    .foregroundColor(.red)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .alert("地址无效", isPresented: $showInvalidAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("请输入以 http:// 或 https:// 开头的有效地址")
        }
    }

    private var activeSourceLabel: String {
        for p in PRESET_SOURCES where p.url == vm.activeSourceUrl {
            return p.name
        }
        return "自定义"
    }

    @ViewBuilder
    private func sourceRow(index: Int, url: String) -> some View {
        HStack(spacing: 12) {
            Button {
                vm.selectSource(url)
                dismiss()
            } label: {
                HStack {
                    Image(systemName: url == vm.activeSourceUrl ? "largecircle.fill.circle" : "circle")
                        .foregroundColor(url == vm.activeSourceUrl ? .blue : .gray)
                        .font(.body)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(for: url))
                            .font(.body)
                            .foregroundColor(.primary)

                        if displayName(for: url) != url {
                            Text(url)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if isBuiltin(url) {
                        Text("预置")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if url != DEFAULT_SOURCE_URL {
                Button("删除", role: .destructive) {
                    vm.deleteSourceUrl(url)
                }
            }
        }
    }

    private func displayName(for url: String) -> String {
        for p in PRESET_SOURCES where p.url == url {
            return p.name
        }
        return url
    }

    private func isBuiltin(_ url: String) -> Bool {
        PRESET_SOURCES.contains { $0.url == url }
    }

    private func add() {
        let url = inputUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }

        guard url.hasPrefix("http://") || url.hasPrefix("https://"),
              URL(string: url) != nil else {
            showInvalidAlert = true
            return
        }

        vm.selectSource(url)
        dismiss()
    }

    private func deleteSources(at offsets: IndexSet) {
        for i in offsets.sorted(by: >) {
            guard i < vm.sourceUrls.count else { continue }
            let url = vm.sourceUrls[i]
            if url != DEFAULT_SOURCE_URL {
                vm.deleteSourceUrl(url)
            }
        }
    }

    private func resetToDefault() {
        vm.selectSource(DEFAULT_SOURCE_URL)
        dismiss()
    }
}
