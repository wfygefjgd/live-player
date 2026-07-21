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
                // 播放器占满可用区域，画面完整显示（可能有黑边，但不裁切台标）
                VideoPlayerView()
                    .frame(width: w, height: h)
                    .background(Color.black)
                    .onTapGesture { vm.showFloat() }

                if vm.panelVisible && !vm.locked {
                    HStack(spacing: 0) {
                        ChannelListPanel()
                            .frame(width: min(300, w * 0.32))
                        Spacer(minLength: 0)
                    }
                }

                ChannelOSDView(text: vm.channelOSD)
                IndicatorView(text: vm.indicatorText)

                if vm.showFloatOverlay {
                    floatingButtons
                }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(dragGesture(screenWidth: w))
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

    private func dragGesture(screenWidth w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !vm.locked else { return }
                let sx = value.startLocation.x
                let vertical = abs(value.translation.height) >= abs(value.translation.width)
                guard vertical else { return }
                if sx < w * 0.35 {
                    vm.adjustBrightness(delta: Float(-value.translation.height) / 300)
                } else if sx > w * 0.65 {
                    vm.adjustVolume(delta: Float(-value.translation.height) / 80)
                }
            }
            .onEnded { value in
                guard !vm.locked else { return }
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
