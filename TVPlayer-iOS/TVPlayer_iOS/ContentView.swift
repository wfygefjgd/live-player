import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject private var vm: PlayerViewModel

    var body: some View {
        ZStack {
            Color.black

            VideoPlayerView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

            if !vm.panelVisible {
                Color.clear
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
                        Color.black.opacity(0.001)
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
                .background(Color.black.opacity(0.5))
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
                    .padding(.bottom, 12)
                    .zIndex(60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all, edges: .all)
        .background(Color.black.ignoresSafeArea(.all, edges: .all))
        .onAppear { vm.startup() }
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
                let vertical = abs(value.translation.height) >= abs(value.translation.width)
                guard vertical, sx > w * 0.65 else { return }
                vm.handleVolumeDrag(translationHeight: value.translation.height, ended: false)
            }
            .onEnded { value in
                guard !vm.locked, !vm.panelVisible else { return }
                let w = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height, 1)
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
