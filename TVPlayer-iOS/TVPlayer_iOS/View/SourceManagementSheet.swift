import SwiftUI

struct SourceManagementSheet: View {
    @EnvironmentObject private var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var inputUrl = ""
    @State private var showInvalidAlert = false
    @State private var showFusionSettings = false
    @State private var isRefreshing = false

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                // 输入区域
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

                    // 快捷粘贴按钮
                    if inputUrl.isEmpty {
                        Button {
                            if let pasted = UIPasteboard.general.string,
                               !pasted.isEmpty {
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

                // 源列表
                List {
                    // 融合模式设置和刷新按钮
                    Section {
                        Button(action: { showFusionSettings = true }) {
                            HStack {
                                Image(systemName: "wand.and.stars")
                                    .foregroundColor(.purple)
                                Text("融合模式设置")
                                    .foregroundColor(.primary)
                                Spacer()
                                Text(fusionModeText)
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        // 刷新频道按钮
                        Button(action: {
                            Task {
                                isRefreshing = true
                                await vm.refreshChannelsFromRemote()
                                isRefreshing = false
                            }
                        }) {
                            HStack {
                                if isRefreshing {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.clockwise.circle")
                                        .foregroundColor(.blue)
                                }
                                Text("刷新频道列表")
                                    .foregroundColor(.primary)
                                Spacer()
                                if !isRefreshing {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .disabled(isRefreshing)
                    }

                    Section {
                        ForEach(Array(vm.sourceUrls.enumerated()), id: \.offset) { (i, url) in
                            sourceRow(index: i, url: url)
                        }
                        .onDelete { offsets in
                            deleteSources(at: offsets)
                        }
                    } header: {
                        HStack {
                            Text("当前源: \(activeSourceLabel)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .padding(.vertical)
            .navigationTitle("管理直播源")
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
            .sheet(isPresented: $showFusionSettings) {
                FusionModeSettingsView()
                    .environmentObject(vm)
            }
        }
        .alert("地址无效", isPresented: $showInvalidAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text("请输入以 http:// 或 https:// 开头的有效地址")
        }
    }

    private var fusionModeText: String {
        switch vm.fusionMode {
        case .fast: return "快速"
        case .balanced: return "平衡"
        case .complete: return "完整"
        case .smart: return "智能"
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
                    // 选中标记
                    Image(systemName: url == vm.activeSourceUrl ? "largecircle.fill.circle" : "circle")
                        .foregroundColor(url == vm.activeSourceUrl ? .blue : .gray)
                        .font(.body)

                    VStack(alignment: .leading, spacing: 2) {
                        // 预置源显示名称，自定义源显示 URL
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

                    // 预置源标签
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

        // URL 格式校验
        guard url.hasPrefix("http://") || url.hasPrefix("https://"),
              URL(string: url) != nil else {
            showInvalidAlert = true
            return
        }

        vm.selectSource(url)
        dismiss()
    }

    private func deleteSources(at offsets: IndexSet) {
        // 从后往前删，避免索引偏移
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
