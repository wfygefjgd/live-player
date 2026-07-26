import SwiftUI
import AVKit

/// SwiftUI Edge-to-Edge 全屏播放页
/// - 视频：.ignoresSafeArea() 贴物理边，Home Indicator 浮在画面上
/// - 仅浮动 OSD/提示：用 safeAreaInsets 抬高（不缩视频）
struct ContentView: View {
    @EnvironmentObject private var vm: PlayerViewModel

    @State private var numberInput = ""
    @State private var numberInputTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            // —— 视频：Edge-to-Edge，禁止 Safe Area 缩进 ——
            VideoPlayerView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .zIndex(1)

            // 手势全屏
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .highPriorityGesture(longPressGesture())
                .simultaneousGesture(doubleTapGesture())
                .simultaneousGesture(playerDragGesture())
                .zIndex(2)

            // —— 浮动控制层：才用 safe area 避让（视频不受影响）——
            floatingChrome()
                .zIndex(5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        // SwiftUI：隐藏状态栏 + 系统叠层 + 延迟边缘手势
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onAppear {
            vm.startup()
            refreshImmersiveChrome()
            WindowPanelSurface.shared.setPanel(
                AnyView(
                    ChannelListPanel(onShowSettings: {
                        vm.panelVisible = false
                        WindowPanelSurface.shared.prepareForModalPresentation()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            vm.showSourceSheet = true
                        }
                    })
                    .environmentObject(vm)
                ),
                viewModel: vm
            )
        }
        .onChange(of: vm.panelVisible) { visible in
            if visible { WindowPanelSurface.shared.show() }
            else { WindowPanelSurface.shared.hide() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelShouldClose)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                vm.panelVisible = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            cancelNumberInput()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            vm.resumeIfAppropriate()
            vm.onAppBecameActive()
            WindowVideoSurface.shared.rebindPlayer()
            refreshImmersiveChrome()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerRemotePlay)) { _ in vm.resume() }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerRemotePause)) { _ in vm.pause() }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerRemoteNext)) { _ in vm.nextChannel() }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerRemotePrevious)) { _ in vm.prevChannel() }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerInterruptionBegan)) { _ in
            vm.noteInterruptionBegan()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerInterruptionEnded)) { _ in
            vm.noteInterruptionEnded(shouldResume: true)
        }
        .sheet(isPresented: $vm.showSourceSheet) {
            SourceManagementSheet().environmentObject(vm)
        }
        .then { base in
            if #available(iOS 17.0, *) {
                AnyView(base.onKeyPress { press in handleKeyPress(press) })
            } else {
                AnyView(base)
            }
        }
    }

    /// 仅浮动 UI 抬高；等价 Flutter MediaQuery.padding.bottom
    @ViewBuilder
    private func floatingChrome() -> some View {
        GeometryReader { geo in
            let bottom = max(geo.safeAreaInsets.bottom, 8)
            let top = max(geo.safeAreaInsets.top, 8)

            ZStack {
                if vm.isBootstrapping {
                    VStack(spacing: 10) {
                        ProgressView().progressViewStyle(.circular).tint(.white)
                        Text(vm.bootstrapMessage)
                            .foregroundColor(.white.opacity(0.9))
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(12)
                } else if vm.channels.isEmpty {
                    VStack(spacing: 12) {
                        Text("暂无频道").foregroundColor(.white)
                        Button("重新加载源") { vm.retryLoadSources() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(12)
                }

                VStack {
                    ChannelOSDView(text: vm.channelOSD)
                        .padding(.top, top + 4)
                    Spacer(minLength: 0)
                    if !vm.isBootstrapping {
                        IndicatorView(text: vm.indicatorText)
                            .padding(.bottom, bottom + 4)
                    }
                }
                .allowsHitTesting(false)

                if !numberInput.isEmpty {
                    VStack {
                        Spacer()
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
                        Spacer().frame(height: bottom + 16)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }

    private func refreshImmersiveChrome() {
        guard let root = (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController else { return }
        root.setNeedsUpdateOfHomeIndicatorAutoHidden()
        root.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        root.setNeedsStatusBarAppearanceUpdate()
    }

    private func longPressGesture() -> some Gesture {
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
        DragGesture(minimumDistance: 28)
            .onChanged { value in
                guard !vm.panelVisible else { return }
                let w = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height, 1)
                let sx = value.startLocation.x
                let dy = value.translation.height
                guard abs(dy) > abs(value.translation.width) else { return }
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
                if abs(dx) > abs(dy) && abs(dx) > 50 {
                    if dx > 0 { vm.switchSource(direction: 1) }
                    else { vm.switchSource(direction: -1) }
                    return
                }
                if abs(dy) > abs(dx) && abs(dy) > 36, sx <= w * 0.65 {
                    if dy < 0 { vm.nextChannel() } else { vm.prevChannel() }
                }
            }
    }

    private func doubleTapGesture() -> some Gesture {
        TapGesture(count: 2).onEnded {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                vm.togglePanel()
            }
        }
    }

    @available(iOS 17.0, *)
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard !vm.panelVisible else { return .ignored }
        if let digit = press.characters.first(where: \.isNumber) {
            appendNumber(digit)
            return .handled
        }
        if press.key == .return { confirmNumberInput(); return .handled }
        if press.key == .escape { cancelNumberInput(); return .handled }
        if press.key == .delete, !numberInput.isEmpty {
            numberInput.removeLast()
            if numberInput.isEmpty { cancelNumberInput() }
            return .handled
        }
        if press.key == .upArrow { vm.prevChannel(); return .handled }
        if press.key == .downArrow { vm.nextChannel(); return .handled }
        if press.key == .leftArrow { vm.switchSource(direction: -1); return .handled }
        if press.key == .rightArrow { vm.switchSource(direction: 1); return .handled }
        if press.characters == " " {
            if vm.player.isPlaying { vm.pause() } else { vm.resume() }
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
            await MainActor.run { confirmNumberInput() }
        }
        if numberInput.count >= 4 { confirmNumberInput() }
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
