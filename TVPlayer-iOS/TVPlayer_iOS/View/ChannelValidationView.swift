import SwiftUI

struct ChannelValidationView: View {
    @StateObject private var validator = ChannelValidator()
    @EnvironmentObject private var vm: PlayerViewModel
    @Binding var isValidating: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer()

                // Logo 或标题
                Text("TVPlayer")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.white)

                VStack(spacing: 20) {
                    // 进度环
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 8)
                            .frame(width: 120, height: 120)

                        Circle()
                            .trim(from: 0, to: validator.progress)
                            .stroke(
                                LinearGradient(
                                    colors: [.cyan, .blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                style: StrokeStyle(lineWidth: 8, lineCap: .round)
                            )
                            .frame(width: 120, height: 120)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.3), value: validator.progress)

                        VStack(spacing: 4) {
                            Text("\(Int(validator.progress * 100))%")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(.white)

                            Text("\(validator.testedCount)/\(validator.totalCount)")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }

                    // 状态文字
                    VStack(spacing: 8) {
                        Text("正在检测频道可用性")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white)

                        Text("首次启动需要验证所有线路")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.6))

                        Text("请稍候...")
                            .font(.system(size: 14))
                            .foregroundColor(.cyan)
                    }
                }

                Spacer()

                // 提示信息
                Text("此过程仅在首次启动时执行")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.bottom, 40)
            }
            .padding()
        }
        .task {
            await performValidation()
        }
    }

    private func performValidation() async {
        // 🆕 第一步：发起简单的网络请求触发 iOS 权限弹窗
        await triggerNetworkPermission()

        // 🆕 延迟 2 秒等待用户点击"允许"
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // 🆕 第二步：在后台加载频道数据（不启动播放器）
        await MainActor.run {
            vm.loadChannelsOnly()  // 只加载频道，不启动播放
        }

        // 🆕 第三步：等待频道加载完成（最多等待 10 秒）
        var attempts = 0
        while vm.channels.isEmpty && attempts < 20 {
            try? await Task.sleep(nanoseconds: 500_000_000)  // 每次等待 0.5 秒
            attempts += 1
        }

        let channels = vm.channels

        guard !channels.isEmpty else {
            // 如果频道加载失败，直接进入主界面
            isValidating = false
            return
        }

        // 第四步：开始验证（50并发，3秒超时）
        let result = await validator.validateAllChannels(channels)

        // 保存验证结果
        ValidationStorage.shared.save(result)

        // 过滤出可用的频道
        vm.applyValidationResult(result)

        // 延迟一下让用户看到 100% 完成
        try? await Task.sleep(nanoseconds: 500_000_000)

        // 结束验证，进入播放界面
        isValidating = false
    }

    // 🆕 触发网络权限请求
    private func triggerNetworkPermission() async {
        // 发起一个简单的网络请求来触发 iOS 的网络权限弹窗
        guard let url = URL(string: "https://www.apple.com") else { return }
        var request = URLRequest(url: url, timeoutInterval: 3.0)
        request.httpMethod = "HEAD"
        do {
            _ = try await URLSession.shared.data(for: request)
        } catch {
            // 忽略错误，我们只是为了触发权限弹窗
        }
    }
}
