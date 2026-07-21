import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject private var vm: PlayerViewModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                videoLayer
                if vm.panelVisible && !vm.locked {
                    channelPanel(width: min(300, geo.size.width * 0.32))
                }
                channelOSD
                indicator
                if vm.showFloatOverlay {
                    floatingButtons
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .gesture(dragGesture)
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
    }

    // MARK: - Video Layer
private var videoLayer: some View {
        VideoPlayerView()
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture { vm.showFloat() }
    }

    // MARK: - Channel Panel
    private func channelPanel(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ChannelListPanel()
                .frame(width: width)
            Spacer()
        }
    }

    // MARK: - OSD
    private var channelOSD: some View {
        ChannelOSDView(text: vm.channelOSD)
    }

    // MARK: - Indicator
    private var indicator: some View {
        IndicatorView(text: vm.indicatorText)
    }

    // MARK: - Floating Buttons
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

    // MARK: - Gestures
    // Unified drag: brightness left, volume right, channel switch middle
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !vm.locked else { return }
                let w = UIScreen.main.bounds.width
                let sx = value.startLocation.x
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
                let w = UIScreen.main.bounds.width
                let sx = value.startLocation.x
                if abs(dx) > abs(dy), abs(dx) > 40 {
                    if sx < w * 0.35 || sx > w * 0.65 {
                        if dx > 0 { vm.switchSource(direction: -1) }
                        else { vm.switchSource(direction: 1) }
                    }
                }
                if abs(dy) > abs(dx), abs(dy) > 40 {
                    if sx >= w * 0.35 && sx <= w * 0.65 {
                        if dy < 0 { vm.nextChannel() }
                        else { vm.prevChannel() }
                    }
                }
            }
    }
}
