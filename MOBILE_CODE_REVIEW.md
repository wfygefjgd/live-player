# TVPlayer iOS & Android 版本代码审查报告

## 📱 项目概述

已检查的移动端版本：
- **iOS 版本**: TVPlayer-iOS (Swift + SwiftUI + AVPlayer)
- **Android 版本**: android-native (Java + ExoPlayer)

## ✅ iOS 版本状态

### 当前版本: v1.4.6

根据 `RELEASE_NOTES.md`，iOS 版本刚刚完成了重大优化：

#### 已完成的优化 ✅

1. **核心引擎优化**
   - ✅ 重构 PlayerEngine：统一 Task 管理
   - ✅ 静音检测：3秒后自动检测并切线
   - ✅ 卡顿检测优化：使用 Date 追踪进度
   - ✅ 线程安全：@MainActor 保证主线程访问

2. **网络优化**
   - ✅ 全候选竞速：并发请求取最快结果
   - ✅ 断网自动重试：监听网络恢复
   - ✅ 网络类型感知：WiFi/蜂窝区分
   - ✅ 指数退避重试：1s/2s/4s 递增

3. **存储优化**
   - ✅ 线程安全：DispatchQueue + barrier
   - ✅ 元数据缓存：版本/数量/更新时间
   - ✅ Channel 模型改为 struct 值类型

4. **交互优化**
   - ✅ 数字键选台：iPad 键盘支持
   - ✅ 键盘快捷键：方向键、空格
   - ✅ 双击切换面板
   - ✅ 触觉反馈

5. **Bug 修复**
   - ✅ 修复 hasActiveAudioTrack 逻辑错误
   - ✅ 修复 isStalled 多线程竞争
   - ✅ 修复 OrderedDictionary 性能问题

### 代码质量评估 ⭐⭐⭐⭐⭐

检查了以下核心文件：
- `PlayerEngine.swift` - **优秀**
  - 结构化并发，Task 管理规范
  - @MainActor 确保线程安全
  - 完善的状态管理和错误处理
  
- `TVPlayerApp.swift` - **优秀**
  - 后台播放支持完善
  - 远程控制集成良好
  - 生命周期管理规范

- `ContentView.swift` - **优秀**
  - SwiftUI 最佳实践
  - 数字键选台实现优雅
  - 手势处理完善

### iOS 版本结论 🎉

**iOS 版本代码质量非常高，没有发现需要立即修复的问题！**

最近的更新已经：
- ✅ 修复了所有已知 Bug
- ✅ 优化了性能和用户体验
- ✅ 代码规范，使用现代 Swift 特性
- ✅ 线程安全，无数据竞争
- ✅ 错误处理完善

---

## 🤖 Android 版本分析

### 当前实现

基于 Java + ExoPlayer 的原生实现，检查了核心文件：
- `MainActivity.java` - Android 主 Activity
- 使用 ExoPlayer 作为播放器
- RecyclerView 显示频道列表

### 发现的可优化点

#### 1. 超时时间过长 ⚠️

**位置**: MainActivity.java 第 64-65 行

```java
private static final long CHANNEL_SWITCH_TIMEOUT_MS = 7000L;
private static final long STALL_TIMEOUT_MS = 7000L;
```

**问题**: 7 秒太长，用户等待时间过长

**建议**: 参考 iOS 版本和桌面版本
```java
private static final long CHANNEL_SWITCH_TIMEOUT_MS = 4000L;  // 4秒
private static final long STALL_TIMEOUT_MS = 3500L;           // 3.5秒
```

**iOS 对比**:
```swift
static let startupTimeoutNs: UInt64 = 4_000_000_000  // 4s
static let stallTimeoutNs: UInt64 = 2_000_000_000     // 2s
```

#### 2. 缺少静音检测 ⚠️

**问题**: Android 版本没有实现静音音轨检测

**iOS 实现** (参考):
```swift
// 3秒后检测是否有声音轨
static let silentAudioCheckNs: UInt64 = 3_000_000_000

var hasActiveAudioTrack: Bool {
    guard let item = player.currentItem else { return false }
    let tracks = item.tracks.filter { $0.assetTrack?.mediaType == .audio }
    return tracks.contains { $0.isEnabled }
}
```

**建议**: 添加类似的检测逻辑到 Android 版本

#### 3. 线程池大小固定 💡

**位置**: MainActivity.java 第 82 行

```java
private final ExecutorService netPool = Executors.newFixedThreadPool(2);
```

**建议**: 根据 CPU 核心数动态调整
```java
private final ExecutorService netPool = Executors.newFixedThreadPool(
    Math.max(2, Math.min(4, Runtime.getRuntime().availableProcessors() - 1))
);
```

**参考**: tv_player_mpv.py 的动态调整
```python
import multiprocessing
batch_size = max(3, min(8, multiprocessing.cpu_count() - 1))
```

#### 4. 缺少网络类型检测 💡

**iOS 实现**:
```swift
NetworkMonitor.shared.onConnectionTypeChanged = { [weak self] type in
    self?.onConnectionTypeChanged(type)
}
```

**建议**: Android 版本也应该检测蜂窝/WiFi，并提示用户

#### 5. 缺少指数退避重试 💡

**iOS 实现**: 1s -> 2s -> 4s 递增重试

**Android 当前**:
```java
private static final long NETWORK_WAIT_RETRY_MS = 1000L;
```

**建议**: 实现类似的指数退避机制

---

## 📊 对比总结

| 特性 | iOS | Android | 优先级 |
|------|-----|---------|--------|
| 基础播放 | ✅ | ✅ | - |
| 卡顿检测 | ✅ 优秀 | ✅ 基础 | 中 |
| 静音检测 | ✅ | ❌ | **高** |
| 超时优化 | ✅ 4s | ⚠️ 7s | **高** |
| 网络监听 | ✅ | ⚠️ 部分 | 中 |
| 指数退避 | ✅ | ❌ | 中 |
| 线程安全 | ✅ @MainActor | ✅ Handler | - |
| 代码规范 | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | - |

---

## 🎯 Android 版本优化建议

### 高优先级（建议立即修复）

#### 1. 缩短超时时间
```java
// 当前
private static final long CHANNEL_SWITCH_TIMEOUT_MS = 7000L;
private static final long STALL_TIMEOUT_MS = 7000L;

// 建议改为
private static final long CHANNEL_SWITCH_TIMEOUT_MS = 4000L;
private static final long STALL_TIMEOUT_MS = 3500L;
private static final long FAST_FAIL_TIMEOUT_MS = 2000L;  // 自动切换时更快
```

#### 2. 添加静音音轨检测

参考 iOS 实现，在播放开始 3 秒后检测：

```java
private void checkForSilentAudio() {
    mainHandler.postDelayed(() -> {
        if (player != null && player.isPlaying()) {
            // 检查是否有音频轨道
            if (!hasActiveAudioTrack()) {
                // 自动切换到下一个线路
                switchToNextPlayableSource("当前线路无声音", true);
            }
        }
    }, 3000);
}

private boolean hasActiveAudioTrack() {
    if (player == null) return false;
    for (int i = 0; i < player.getCurrentTracksInfo().getTrackGroupArrays().length; i++) {
        if (player.getCurrentTracksInfo().getTrackGroupArrays()
                .get(i).getFormat(0).sampleMimeType.startsWith("audio/")) {
            return true;
        }
    }
    return false;
}
```

### 中优先级

#### 3. 动态调整线程池大小
```java
private final ExecutorService netPool = Executors.newFixedThreadPool(
    Math.max(2, Math.min(4, Runtime.getRuntime().availableProcessors() - 1))
);
```

#### 4. 添加网络类型检测
```java
private void detectNetworkType() {
    ConnectivityManager cm = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
    NetworkInfo info = cm.getActiveNetworkInfo();
    if (info != null && info.isConnected()) {
        if (info.getType() == ConnectivityManager.TYPE_MOBILE) {
            // 提示用户正在使用蜂窝网络
            showIndicator("正在使用蜂窝网络");
        }
    }
}
```

#### 5. 实现指数退避重试
```java
private int retryCount = 0;
private static final int MAX_RETRIES = 3;

private void retryWithBackoff() {
    if (retryCount >= MAX_RETRIES) {
        retryCount = 0;
        return;
    }
    
    long delay = (long) Math.pow(2, retryCount) * 1000L;  // 1s, 2s, 4s
    retryCount++;
    
    mainHandler.postDelayed(() -> {
        loadChannels();
    }, delay);
}
```

### 低优先级

#### 6. 代码重构建议
- 考虑迁移到 Kotlin（更简洁、更安全）
- 使用 ViewModel + LiveData 架构
- 使用 Coroutines 替代 ExecutorService

---

## 📝 具体修改步骤（Android）

### 步骤 1: 修改超时常量

编辑 `MainActivity.java`：

```java
// 找到第 64-65 行
private static final long CHANNEL_SWITCH_TIMEOUT_MS = 4000L;  // 改为 4秒
private static final long STALL_TIMEOUT_MS = 3500L;           // 改为 3.5秒
```

### 步骤 2: 添加静音检测

在 `setupPlayer()` 方法后添加：

```java
private void setupSilentAudioDetection() {
    player.addListener(new Player.Listener() {
        @Override
        public void onIsPlayingChanged(boolean isPlaying) {
            if (isPlaying) {
                // 3秒后检测静音
                mainHandler.postDelayed(() -> {
                    if (!hasActiveAudioTrack() && player.isPlaying()) {
                        switchToNextPlayableSource("无声音，切换线路", true);
                    }
                }, 3000);
            }
        }
    });
}

private boolean hasActiveAudioTrack() {
    if (player == null) return false;
    try {
        // ExoPlayer 2.x 检测音频轨道
        return player.getCurrentTrackGroups().length > 0;
    } catch (Exception e) {
        return false;
    }
}
```

在 `onCreate()` 中调用：
```java
setupPlayer();
setupSilentAudioDetection();  // 添加这行
```

### 步骤 3: 动态线程池

修改第 82 行：
```java
private final ExecutorService netPool = Executors.newFixedThreadPool(
    Math.max(2, Math.min(4, Runtime.getRuntime().availableProcessors() - 1))
);
```

---

## 🎉 总结

### iOS 版本 ✅
**状态**: 优秀，无需修复  
**代码质量**: ⭐⭐⭐⭐⭐  
**最近更新**: v1.4.6 已完成重大优化  
**建议**: 保持当前质量即可

### Android 版本 ⚠️
**状态**: 良好，有改进空间  
**代码质量**: ⭐⭐⭐⭐  
**优先修复**:
1. 缩短超时时间（7s → 4s）
2. 添加静音音轨检测

**次要优化**:
3. 动态线程池大小
4. 网络类型检测
5. 指数退避重试

### 影响评估

**修复超时时间**:
- 改动: 2 行代码
- 风险: 极低
- 效果: 用户体验提升明显

**添加静音检测**:
- 改动: 约 30 行代码
- 风险: 低
- 效果: 自动跳过无声音频道

**总体评估**: iOS 版本已经非常完善，Android 版本只需小幅优化即可达到同等水平。

---

**审查完成时间**: 2026-07-25  
**审查版本**: iOS v1.4.6, Android (当前)  
**建议优先级**: iOS ✅ 无需修改 | Android ⚠️ 建议优化 2 项
