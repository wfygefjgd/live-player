import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject private var vm: PlayerViewModel

    var body: some View {
        ZStack {
            // Video under everything (including Home Indicator overlay)
            VideoPlayerView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.all, edges: .all)
                .allowsHitTesting(false)

            // Helps system treat Home Indicator as overlay (auto-hide when possible)
            HomeIndicatorConfigurator()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

            if !vm.panelVisible {
                Color.clear
                    .ignoresSafeArea(.all, edges: .all)
                    .contentShape(Rectangle())
                    .onTapGesture { vm.showFloat() }
                    .simultaneousGesture(playerDragGesture())
            }

            if vm.panelVisible && !vm.locked {
                GeometryReader { geo in
                    let w = max(geo.size.width, 1)
                    HStack(spacing: 0) {
                        ChannelListPanel()
                            .frame(width: min(300, w * 0.32))
                            .frame(maxHeight: .infinity)
                            .background(Color(white: 0.12).opacity(0.96))
                        Color.black.opacity(0.25)
                            .contentShape(Rectangle())
                            .onTapGesture { vm.panelVisible = false }
                    }
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

            // Controls stay above Home Indicator with safe-area padding
            if vm.showFloatOverlay || vm.locked {
                floatingButtons
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .zIndex(60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea(.all, edges: .all)
        // Home Indicator overlays content; hide when idle if system allows
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
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

    private func playerDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard !vm.locked, !vm.panelVisible else { return }
                let w = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height, 1)
                let sx = value.startLocation.x
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dy) > abs(dx), sx > w * 0.65 else { return }
                vm.handleVolumeDrag(translationHeight: dy, ended: false)
            }
            .onEnded { value in
                guard !vm.locked, !vm.panelVisible else { return }
                let w = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height, 1)
                let sx = value.startLocation.x
                let dx = value.translation.width
                let dy = value.translation.height

                if sx > w * 0.65 {
                    vm.handleVolumeDrag(translationHeight: dy, ended: true)
                }

                if abs(dx) > abs(dy), abs(dx) > 50 {
                    if dx > 0 { vm.switchSource(direction: -1) }
                    else { vm.switchSource(direction: 1) }
                    return
                }

                if abs(dy) > abs(dx), abs(dy) > 40, sx >= w * 0.30, sx <= w * 0.65 {
                    if dy < 0 { vm.nextChannel() }
                    else { vm.prevChannel() }
                }
            }
    }
}
