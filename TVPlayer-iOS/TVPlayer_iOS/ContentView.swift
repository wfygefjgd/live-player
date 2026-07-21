import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject private var vm: PlayerViewModel

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            ZStack {
                Color.black

                // 手势仅挂在播放层，避免挡住侧栏 List 滚动
                VideoPlayerView()
                    .frame(width: w, height: h)
                    .background(Color.black)
                    .contentShape(Rectangle())
                    .gesture(playerDragGesture(screenWidth: w))
                    .onTapGesture { vm.showFloat() }

                if vm.panelVisible && !vm.locked {
                    HStack(spacing: 0) {
                        ChannelListPanel()
                            .frame(width: min(300, w * 0.32))
                            .frame(maxHeight: .infinity)
                            .background(Color(white: 0.12).opacity(0.96))
                            // 明确接收触摸，不被下层手势抢走
                            .contentShape(Rectangle())
                            .highPriorityGesture(DragGesture(minimumDistance: 0))
                        Spacer(minLength: 0)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                vm.panelVisible = false
                            }
                    }
                    .zIndex(10)
                }

                ChannelOSDView(text: vm.channelOSD)
                    .zIndex(5)
                IndicatorView(text: vm.indicatorText)
                    .zIndex(5)

                if vm.showFloatOverlay {
                    floatingButtons
                        .zIndex(20)
                }
            }
            .frame(width: w, height: h)
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
        .ignoresSafeArea(.all)
        .background(Color.black)
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

    /// 播放区手势：右滑音量 / 左右切线路 / 中间上下换台
    private func playerDragGesture(screenWidth w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !vm.locked, !vm.panelVisible else { return }
                let sx = value.startLocation.x
                let vertical = abs(value.translation.height) >= abs(value.translation.width)
                guard vertical, sx > w * 0.65 else { return }
                vm.adjustVolume(delta: Float(-value.translation.height) / 80)
            }
            .onEnded { value in
                guard !vm.locked, !vm.panelVisible else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                let sx = value.startLocation.x
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
