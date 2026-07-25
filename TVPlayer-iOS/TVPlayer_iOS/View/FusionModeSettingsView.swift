import SwiftUI

/// 融合模式设置视图
struct FusionModeSettingsView: View {
    @EnvironmentObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("选择频道融合模式")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } header: {
                    Text("融合模式")
                }

                Section {
                    FusionModeRow(
                        mode: .fast,
                        title: "⚡️ 快速模式",
                        description: "只使用最快响应的源\n启动最快，频道数量较少",
                        isSelected: viewModel.fusionMode == .fast
                    )
                    .onTapGesture {
                        viewModel.switchFusionMode(.fast)
                    }

                    FusionModeRow(
                        mode: .balanced,
                        title: "⚖️ 平衡模式",
                        description: "融合前3个源\n速度与数量平衡",
                        isSelected: viewModel.fusionMode == .balanced
                    )
                    .onTapGesture {
                        viewModel.switchFusionMode(.balanced)
                    }

                    FusionModeRow(
                        mode: .complete,
                        title: "🎯 完整模式",
                        description: "融合所有源并测速\n频道最多，线路质量最优",
                        isSelected: viewModel.fusionMode == .complete
                    )
                    .onTapGesture {
                        viewModel.switchFusionMode(.complete)
                    }

                    FusionModeRow(
                        mode: .smart,
                        title: "✨ 智能模式（推荐）",
                        description: "快速启动 + 后台融合\n兼顾速度与质量",
                        isSelected: viewModel.fusionMode == .smart
                    )
                    .onTapGesture {
                        viewModel.switchFusionMode(.smart)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        InfoRow(icon: "checkmark.circle.fill", color: .green, text: "当前模式：\(modeDisplayName)")

                        if !viewModel.channels.isEmpty {
                            let totalLines = viewModel.channels.reduce(0) { $0 + $1.sourceCount }
                            InfoRow(icon: "tv.circle.fill", color: .blue, text: "\(viewModel.channels.count) 个频道")
                            InfoRow(icon: "antenna.radiowaves.left.and.right.circle.fill", color: .orange, text: "\(totalLines) 条线路")
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("当前状态")
                }

                Section {
                    Button(action: {
                        viewModel.loadChannels(force: true, silent: false, preferActiveOnly: false)
                        dismiss()
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise.circle.fill")
                            Text("重新加载频道")
                        }
                    }
                } footer: {
                    Text("切换模式后会自动重新加载频道")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("融合模式设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") {
                    dismiss()
                }
            }
        }
    }

    private var modeDisplayName: String {
        switch viewModel.fusionMode {
        case .fast: return "快速模式"
        case .balanced: return "平衡模式"
        case .complete: return "完整模式"
        case .smart: return "智能模式"
        }
    }
}

/// 融合模式选项行
struct FusionModeRow: View {
    let mode: FusionMode
    let title: String
    let description: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .regular)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
                    .font(.title3)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// 信息行
struct InfoRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.body)

            Text(text)
                .font(.subheadline)
        }
    }
}

// MARK: - 预览

#Preview {
    FusionModeSettingsView()
        .environmentObject(PlayerViewModel())
}
