import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject private var vm: PlayerViewModel

    var body: some View {
        GeometryReader { geo in
            let b = UIScreen.main.bounds
            let sw = max(b.width, b.height)
            let sh = min(b.width, b.height)
            // 用整屏尺寸，不要只用 geo（可能不含 home 区）
            let w = max(geo.size.width, sw, 1)
            let h = max(geo.size.height, sh, 1)

            ZStack {
                Color.black

                VideoPlayerView()
                    .frame(width: w, height: h)
                    // 相对 geo 居中，frame 可略大于 geo 以盖住底边
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .allowsHitTesting(false)

                if !vm.panelVisible {
                    Color.clear
                        .frame(width: geo.size.width, height: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.showFloat() }
                        .simultaneousGesture(playerDragGesture(screenWidth: max(geo.size.width, 1)))
                }

                if vm.panelVisible && !vm.locked {
                    HStack(spacing: 0) {
                        ChannelListPanel()
                            .frame(width: min(300, max(geo.size.width, 1) * 0.32))
                            .frame(maxHeight: .infinity)
                            .background(Color(white: 0.12).opacity(0.96))
                        Color.black.opacity(0.25)
                            .contentShape(Rectangle())
                            .onTapGesture { vm.panelVisible = false }
                    }
                    .zIndex(50)
                }

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

                if vm.showFloatOverlay || vm.locked {
                    floatingButtons
                        .padding(.top, 12)
                        .padding(.bottom, 20)
                        .zIndex(60)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea(.all, edges: .all)
        .background(Color.black.ignoresSafeArea(.all))
        .onAppear {
            vm.startup()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .tvPlayerNeedsRelayout, object: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            vm.pause()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            vm.resume()
            vm.onAppBecameActive()
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

    private func playerDragGesture(screenWidth w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard !vm.locked, !vm.panelVisible else { return }
                let sx = value.startLocation.x
                let vertical = abs(value.translation.height) >= abs(value.translation.width)
                guard vertical, sx > w * 0.65 else { return }
                vm.handleVolumeDrag(translationHeight: value.translation.height, ended: false)
            }
            .onEnded { value in
                guard !vm.locked, !vm.panelVisible else { return }
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
