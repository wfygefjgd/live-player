import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject private var vm: PlayerViewModel

    // 数字键选台
    @State private var numberInput = ""
    @State private var numberInputTask: Task<Void, Never>?

    // 设置菜单
    @State private var showSettingsMenu = false

    var body: some View {
        ZStack {
            // 必须透明：真实画面在 keyWindow 底层 AVPlayerLayer，不透明黑底会挡成「有声无画」
            Color.clear
                .ignoresSafeArea(.all, edges: .all)

            VideoPlayerView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.all, edges: .all)
                .allowsHitTesting(false)
                .zIndex(1)

            // 手势交互层（长按优先于拖动，避免侧边栏弹不出）
            Color.clear
                .ignoresSafeArea(.all, edges: .all)
                .contentShape(Rectangle())
                .onTapGesture {
                    // 单击：无角标模式下不做事（避免误触）；面板关闭时保持干净画面
                }
                .highPriorityGesture(longPressGesture())
                .simultaneousGesture(doubleTapGesture())
                .simultaneousGesture(playerDragGesture())
                .zIndex(2)

            if vm.isBootstrapping {
                VStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    Text(vm.bootstrapMessage)
                        .foregroundColor(.white.opacity(0.9))
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .background(Color.black.opacity(0.55))
                .cornerRadius(12)
                .zIndex(9)
            } else if vm.channels.isEmpty {
                VStack(spacing: 12) {
                    Text("暂无频道")
                        .foregroundColor(.white)
                    Button("重新加载源") { vm.retryLoadSources() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .background(Color.black.opacity(0.55))
                .cornerRadius(12)
                .zIndex(8)
            }

            ChannelOSDView(text: vm.channelOSD)
                .allowsHitTesting(false)
                .zIndex(5)
            if !vm.isBootstrapping {
                IndicatorView(text: vm.indicatorText)
                    .allowsHitTesting(false)
                    .zIndex(5)
            }

            // 数字键选台输入显示
            if !numberInput.isEmpty {
                VStack {
                    Text(numberInput)
                        .font(.system(size: 60, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(16)
                    Text("按数字键选台")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
                .zIndex(70)
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .ignoresSafeArea(.all, edges: .all)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onAppear {
            vm.startup()
            NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)

            WindowPanelSurface.shared.setPanel(
                AnyView(
                    ChannelListPanel(onShowSettings: {
                        // 先降侧栏，再弹菜单，避免被盖住
                        vm.panelVisible = false
                        WindowPanelSurface.shared.prepareForModalPresentation()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            showSettingsMenu = true
                        }
                    })
                    .environmentObject(vm)
                ),
                viewModel: vm
            )
        }
        .onChange(of: vm.panelVisible) { visible in
            if visible {
                WindowPanelSurface.shared.show()
            } else {
                WindowPanelSurface.shared.hide()
            }
        }
        .onChange(of: showSettingsMenu) { open in
            // 菜单关闭后不自动开栏，由用户长按再开
            if !open { /* keep panel closed */ }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelShouldClose)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                vm.panelVisible = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // 不 pause：支持后台音频 / 锁屏续播
            cancelNumberInput()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            vm.resumeIfAppropriate()
            vm.onAppBecameActive()
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let root = windowScene.windows.first?.rootViewController {
                root.setNeedsUpdateOfHomeIndicatorAutoHidden()
                root.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            }
            WindowVideoSurface.shared.forceFullBleed(reason: "app-active")
            WindowVideoSurface.shared.rebindPlayer()
            NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerRemotePlay)) { _ in
            vm.resume()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerRemotePause)) { _ in
            vm.pause()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerRemoteNext)) { _ in
            vm.nextChannel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerRemotePrevious)) { _ in
            vm.prevChannel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerInterruptionBegan)) { _ in
            vm.noteInterruptionBegan()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerInterruptionEnded)) { _ in
            vm.noteInterruptionEnded(shouldResume: true)
        }
        .sheet(isPresented: $vm.showSourceSheet) {
            SourceManagementSheet()
                .environmentObject(vm)
        }
        .confirmationDialog("功能菜单", isPresented: $showSettingsMenu, titleVisibility: .visible) {
            Button("切换来源") {
                vm.showSourceSheet = true
            }
            Button("关闭", role: .cancel) {
                showSettingsMenu = false
            }
        }
        .then { base in
            if #available(iOS 17.0, *) {
                return AnyView(base.onKeyPress { press in handleKeyPress(press) })
            } else {
                return AnyView(base)
            }
        }
    }

    private func longPressGesture() -> some Gesture {
        // 略缩短，且与拖动手势 highPriority 分离，减少“长按被拖动吃掉”
        LongPressGesture(minimumDuration: 0.45)
            .onEnded { _ in
                if vm.panelVisible {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        vm.panelVisible = false
                    }
                    WindowPanelSurface.shared.hide()
                } else {
                    vm.panelVisible = true
                    WindowPanelSurface.shared.show()
                }
            }
    }

    private func playerDragGesture() -> some Gesture {
        // 提高最小位移，避免微抖触发拖动导致长按失败
        DragGesture(minimumDistance: 28)
            .onChanged { value in
                guard !vm.panelVisible else { return }
                let w = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height, 1)
                let sx = value.startLocation.x
                let dy = value.translation.height
                guard abs(dy) > abs(value.translation.width) else { return }
                // 仅右侧调音量；亮度交给系统；左+中竖滑换台
                if sx > w * 0.65 {
                    vm.handleVolumeDrag(translationHeight: dy, ended: false)
                }
            }
            .onEnded { value in
                guard !vm.panelVisible else { return }
                let w = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height, 1)
                let sx = value.startLocation.x
                let dx = value.translation.width
                let dy = value.translation.height

                if sx > w * 0.65 {
                    vm.handleVolumeDrag(translationHeight: dy, ended: true)
                    return
                }

                // 左右滑换线（全屏，除右侧正在调音量外）
                if abs(dx) > abs(dy) && abs(dx) > 50 {
                    if dx > 0 { vm.switchSource(direction: 1) }
                    else { vm.switchSource(direction: -1) }
                    return
                }

                // 左+中区竖滑换台
                if abs(dy) > abs(dx) && abs(dy) > 36, sx <= w * 0.65 {
                    if dy < 0 { vm.nextChannel() } else { vm.prevChannel() }
                }
            }
    }

    private func doubleTapGesture() -> some Gesture {
        TapGesture(count: 2)
            .onEnded {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    vm.togglePanel()
                }
            }
    }

    // MARK: - 数字键选台

    @available(iOS 17.0, *)
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard !vm.panelVisible else { return .ignored }

        if let digit = press.characters.first(where: { $0.isNumber }) {
            appendNumber(digit)
            return .handled
        }

        if press.key == .return {
            confirmNumberInput()
            return .handled
        }

        if press.key == .escape {
            cancelNumberInput()
            return .handled
        }
        if press.key == .delete {
            if !numberInput.isEmpty {
                numberInput.removeLast()
                if numberInput.isEmpty {
                    cancelNumberInput()
                }
                return .handled
            }
        }

        if press.key == .upArrow {
            vm.prevChannel()
            return .handled
        }
        if press.key == .downArrow {
            vm.nextChannel()
            return .handled
        }

        if press.key == .leftArrow {
            vm.switchSource(direction: -1)
            return .handled
        }
        if press.key == .rightArrow {
            vm.switchSource(direction: 1)
            return .handled
        }

        if press.characters == " " {
            if vm.player.isPlaying {
                vm.pause()
            } else {
                vm.resume()
            }
            return .handled
        }

        return .ignored
    }

    private func appendNumber(_ digit: Character) {
        numberInput.append(digit)
        numberInputTask?.cancel()
        numberInputTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                confirmNumberInput()
            }
        }
        if numberInput.count >= 4 {
            confirmNumberInput()
        }
    }

    private func confirmNumberInput() {
        guard let num = Int(numberInput), num > 0 else {
            cancelNumberInput()
            return
        }
        let index = num - 1
        if index < vm.channels.count {
            vm.selectChannel(vm.channels[index])
        } else if !vm.channels.isEmpty {
            vm.selectChannel(vm.channels[vm.channels.count - 1])
        }
        cancelNumberInput()
    }

    private func cancelNumberInput() {
        numberInput = ""
        numberInputTask?.cancel()
        numberInputTask = nil
    }
}

private extension View {
    @ViewBuilder
    func then<Content: View>(_ transform: (Self) -> Content) -> some View {
        transform(self)
    }
}
