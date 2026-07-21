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
                floatingButtons
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .gesture(tapGesture)
            .gesture(channelDrag)
            .gesture(brightnessDrag)
            .gesture(volumeDrag)
            .onAppear { vm.startup() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                vm.pause()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                vm.resume()
            }
        }
    }

    // MARK: - Video Layer
    private var videoLayer: some View {
        VideoPlayerView()
            .ignoresSafeArea()
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
            onLongPanel: { vm.switchToNextSource() },
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
    private var tapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded { vm.onTap() }
    }

    private var channelDrag: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard !vm.locked else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                let x = value.location.x
                let w = UIScreen.main.bounds.width
                if abs(dx) > abs(dy) {
                    guard abs(dx) > 40 else { return }
                    if x < w * 0.35 || x > w * 0.65 {
                        if dx > 0 { vm.switchSource(direction: -1) }
                        else { vm.switchSource(direction: 1) }
                    }
                } else {
                    guard abs(dy) > 40 else { return }
                    if x >= w * 0.35 && x <= w * 0.65 {
                        if dy > 0 { vm.nextChannel() }
                        else { vm.prevChannel() }
                    }
                }
            }
    }

    private var brightnessDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !vm.locked, value.translation.width.magnitude < value.translation.height.magnitude else { return }
                if value.location.x < UIScreen.main.bounds.width * 0.35 {
                    vm.adjustBrightness(delta: Float(-value.translation.height) / 300)
                }
            }
    }

    private var volumeDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !vm.locked, value.translation.width.magnitude < value.translation.height.magnitude else { return }
                if value.location.x > UIScreen.main.bounds.width * 0.65 {
                    vm.adjustVolume(delta: Float(-value.translation.height) / 80)
                }
            }
    }
}
