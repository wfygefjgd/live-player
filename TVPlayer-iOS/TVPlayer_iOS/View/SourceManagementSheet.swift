import SwiftUI

struct SourceManagementSheet: View {
    @EnvironmentObject private var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var inputUrl = ""
    @State private var showInvalidAlert = false

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                // 软件 / 数据分离：一键拉 GitHub 官方最新线路
                Button {
                    vm.refreshLatestLineup()
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        if vm.isRefreshingLatest {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                .font(.system(size: 22))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.isRefreshingLatest ? "正在加载最新线路…" : "加载最新线路")
                                .font(.headline)
                            Text("从 GitHub 官方源更新频道（改仓库文件即可，不必重装 App）")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(
                            colors: [Color.blue, Color.cyan.opacity(0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .disabled(vm.isRefreshingLatest)
                .padding(.horizontal, 4)

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
                                    Text("自动跳过失败线路")
                                    Text("仅线路失败/源错误/长时间无画面才换；卡顿与慢线不切")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Toggle(isOn: Binding(
                            get: { vm.autoBlacklistEnabled },
                            set: { vm.setAutoBlacklistEnabled($0) }
                        )) {
                            HStack {
                                Image(systemName: "xmark.shield")
                                    .foregroundColor(.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("失败线路黑名单")
                                    Text("失败线路自动加入黑名单，换源后自动清空")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        if vm.autoBlacklistEnabled {
                            Button {
                                vm.clearBlacklist()
                            } label: {
                                HStack {
                                    Image(systemName: "trash")
                                        .foregroundColor(.blue)
                                    Text("清空黑名单")
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                    } header: {
                        Text("播放设置")
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("数据更新（与 App 发版无关）")
                                .font(.subheadline.weight(.semibold))
                            Text("官方线路文件：")
                                .font(.caption)
                            Text("iptv-mirrors/validated-channels.m3u")
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                            Text("你在 GitHub 改这个文件并 push 后，用户点「加载最新线路」即可更新，不必重新安装。")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("说明：Pages/raw 通常很快；jsDelivr 可能有数小时缓存，按钮会优先 Pages。")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("最新线路")
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("TVPlayer 1.9 正式版")
                                .font(.headline)
                            Text("• 新增「加载最新线路」：GitHub 数据与软件发版分离")
                            Text("• 新增自动跳过失败线路开关，可控制换线行为")
                            Text("• 新增失败线路黑名单功能，避免重复尝试失败线路")
                            Text("• 换源时自动清空黑名单，支持手动清空操作")
                            Text("• 源可以自定义，支持添加和切换 M3U / M3U8 地址")
                            Text("• 支持多线路自动换线，遇到超时、卡顿、无声会自动切线")
                            Text("• 支持收藏频道、隐藏线路、后台音频播放")
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
