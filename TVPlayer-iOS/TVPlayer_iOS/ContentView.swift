import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject private var vm: PlayerViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea(.all)

            // 播放器贴满整个窗口（不依赖 GeometryReader 可能偏小的尺寸）
            VideoPlayerView()
                .ignoresSafeArea(.all)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

            if !vm.panelVisible {
                Color.clear
                    .ignoresSafeArea(.all)
                    .contentShape(Rectangle())
                    .onTapGesture { vm.showFloat() }
                    .simultaneousGesture(playerDragGesture())
            }

            if vm.panelVisible && !vm.locked {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        ChannelListPanel()
                            .frame(width: min(300, max(geo.size.width, 1) * 0.32))
                            .frame(maxHeight: .infinity)
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture { vm.panelVisible = false }
                    }
                }
                .zIndex(50)
            }

            ChannelOSDView(text: vm.channelOSD)
                .allowsHitTesting(false)
                .zIndex(5)
            IndicatorView(text: vm.indicatorText)
                .allowsHitTesting(false)
                .zIndex(5)

            if vm.showFloatOverlay || vm.locked {
                floatingButtons
                    .zIndex(60)
            }
        }
        .ignoresSafeArea(.all)
        .background(Color.black.ignoresSafeArea(.all))
        .onAppear { vm.startup() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            vm.pause()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            vm.resume()
        }
        .sheet(isPresented: $vm.showSourceSheet) {
            SourceManagementSheet()
                .environmentObject(vm)
        }
    }

    private var floatingButtons: some View {
        FloatingButtons(
            panelVisible: vm.panelVisible,
            locked: vm.locked,
            onTogglePanel: { vm.togglePanel() },
            onLongPanel: { vm.showSourceSheet = true },
            onToggleLock: { vm.toggleLock() },
            onLongLock: { vm.confirmDeleteLine() }
        )
        .alert("删除线路", isPresented: $vm.showDeleteAlert) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) { vm.doDeleteLine() }
        } message: {
            Text("确定删除当前线路？")
        }
    }

    private func playerDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard !vm.locked, !vm.panelVisible else { return }
                let w = max(UIScreen.main.bounds.width, 1)
                let sx = value.startLocation.x
                let vertical = abs(value.translation.height) >= abs(value.translation.width)
                guard vertical, sx > w * 0.65 else { return }
                vm.handleVolumeDrag(translationHeight: value.translation.height, ended: false)
            }
            .onEnded { value in
                guard !vm.locked, !vm.panelVisible else { return }
                let w = max(UIScreen.main.bounds.width, 1)
                let sx = value.startLocation.x
                if sx > w * 0.65 {
                    vm.handleVolumeDrag(translationHeight: value.translation.height, ended: true)
                }
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) > abs(dy), abs(dx) > 40 {
                    if sx < w * 0.35 || sx > w * 0.65 {
                        if dx > 0 { vm.switchSource(direction: -1) }
                        else { vm.switchSource(direction: 1) }
                    }
                } else if abs(dy) > abs(dx), abs(dy) > 40 {
                    if sx >= w * 0.35 && sx <= w * 0.65 {
                        if dy < 0 { vm.nextChannel() }
                        else { vm.prevChannel() }
                    }
                }
            }
    }
}
