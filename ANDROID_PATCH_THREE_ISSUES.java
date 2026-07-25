package org.tvplayer.app;

/*
 * 三大问题修复补丁
 *
 * 问题1: 快速切换 - 超时从7秒改为3秒，移动网络1.5秒
 * 问题2: 多源加载 - 6个优质源自动拼接，镜像加速
 * 问题3: 全屏显示 - 完美沉浸式，解决Home条挤占
 *
 * 使用方法：
 * 1. 打开 MainActivity.java
 * 2. 参考本文件进行修改
 * 3. 重点修改位置已标注行号
 */

// ============================================================================
// 修改1: 超时常量优化（第 64-67 行）
// ============================================================================

// ❌ 删除这些旧的常量
// private static final long CHANNEL_SWITCH_TIMEOUT_MS = 7000L;
// private static final long STALL_TIMEOUT_MS = 7000L;
// private static final long NETWORK_WAIT_RETRY_MS = 1000L;

// ✅ 替换为这些新的常量
private static final long CHANNEL_SWITCH_TIMEOUT_MS = 3000L;      // 3秒快速切换
private static final long STALL_TIMEOUT_MS = 2500L;               // 2.5秒卡顿检测
private static final long FAST_FAIL_TIMEOUT_MS = 1500L;           // 1.5秒快速失败（新增）
private static final long NETWORK_WAIT_RETRY_MS = 500L;           // 0.5秒快速重试


// ============================================================================
// 修改2: 多源配置（第 56-62 行）
// ============================================================================

// ❌ 删除旧的单源配置
// private static final String DEFAULT_SOURCE_URL = ...
// private static final String[] DEFAULT_MIRRORS = {...};

// ✅ 替换为多源配置
private static final String[] MULTI_SOURCE_URLS = {
    "best-fan/iptv-sources/master/cn_all_status.m3u8",      // 状态检测版
    "fanmingming/live/main/tv/m3u/ipv6.m3u",                // IPv6 高清
    "YueChan/Live/main/IPTV.m3u",                           // 稳定源
    "Supprise0901/TVBox_live/main/live.txt",                // TVBox
    "vbskycn/iptv/master/tv/tv.m3u",                        // 综合源
    "YanG-1989/m3u/main/Gather.m3u",                        // 高质量
};

private static final String[] MIRROR_PREFIXES = {
    "https://ghfast.top/raw.githubusercontent.com/",
    "https://raw.gitmirror.com/",
    "https://raw.kkgithub.com/",
    "https://gcore.jsdelivr.net/gh/",
};


// ============================================================================
// 修改3: 添加成员变量（第 82-105 行后）
// ============================================================================

// 在现有成员变量后添加这些
private ConnectivityManager connectivityManager;
private boolean isNetworkSlow = false;


// ============================================================================
// 修改4: onCreate 方法增强（第 107-136 行）
// ============================================================================

@Override
protected void onCreate(@Nullable Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);

    // ✅ 新增：设置沉浸式全屏
    setupImmersiveMode();

    requestWindowFeature(Window.FEATURE_NO_TITLE);
    getWindow().setFlags(
            WindowManager.LayoutParams.FLAG_FULLSCREEN,
            WindowManager.LayoutParams.FLAG_FULLSCREEN);
    getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE);

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        WindowManager.LayoutParams lp = getWindow().getAttributes();
        lp.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        getWindow().setAttributes(lp);
    }

    setContentView(R.layout.activity_main);

    // ✅ 新增：再次应用沉浸式
    applyImmersiveMode();

    audioManager = (AudioManager) getSystemService(AUDIO_SERVICE);
    storage = new StorageHelper(this);

    // ✅ 新增：初始化网络管理器和检测
    connectivityManager = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
    checkNetworkSpeed();

    restoreSourceState();
    bindViews();
    setupPlayer();
    setupList();
    setupGestures();
    setupButtons();
    loadBrightness();
    loadChannels();
}


// ============================================================================
// 修改5: 修改 loadChannels 方法（约第 200-250 行，找到原有方法并替换）
// ============================================================================

private void loadChannels() {
    // 先从缓存加载
    List<Channel> cached = storage.loadChannels();
    if (!cached.isEmpty()) {
        channels.clear();
        channels.addAll(cached);
        adapter.setChannels(channels);
        status.setText(String.format("已加载 %d 个频道（缓存）", channels.size()));
        playCurrent(false);
    }

    // 后台刷新多源
    loadChannelsFromMultiSources();
}


// ============================================================================
// 修改6: 在类的末尾添加所有新方法
// ============================================================================

/**
 * 检测网络速度
 */
private void checkNetworkSpeed() {
    NetworkInfo activeNetwork = connectivityManager.getActiveNetworkInfo();
    if (activeNetwork != null && activeNetwork.isConnected()) {
        if (activeNetwork.getType() == ConnectivityManager.TYPE_MOBILE) {
            isNetworkSlow = true;
            pendingStallTimeoutMs = FAST_FAIL_TIMEOUT_MS;
            showIndicator("移动网络，快速切换模式");
        } else {
            isNetworkSlow = false;
            pendingStallTimeoutMs = CHANNEL_SWITCH_TIMEOUT_MS;
        }
    } else {
        isNetworkSlow = true;
        pendingStallTimeoutMs = FAST_FAIL_TIMEOUT_MS;
    }
}

/**
 * 从多个源加载并合并频道
 */
private void loadChannelsFromMultiSources() {
    showIndicator("正在加载多个直播源...");
    status.setText("加载中，请稍候...");

    netPool.execute(() -> {
        List<Channel> allChannels = new ArrayList<>();
        Set<String> seenUrls = new LinkedHashSet<>();

        int successCount = 0;
        int totalSources = MULTI_SOURCE_URLS.length;

        for (int i = 0; i < MULTI_SOURCE_URLS.length; i++) {
            String sourceUrl = MULTI_SOURCE_URLS[i];
            final int index = i + 1;

            mainHandler.post(() ->
                showIndicator(String.format("加载源 %d/%d", index, totalSources))
            );

            for (String prefix : MIRROR_PREFIXES) {
                String fullUrl = prefix + sourceUrl;

                try {
                    URL url = new URL(fullUrl);
                    HttpURLConnection conn = (HttpURLConnection) url.openConnection();
                    conn.setConnectTimeout(5000);
                    conn.setReadTimeout(10000);
                    conn.setRequestProperty("User-Agent", "TVPlayer/1.0");

                    if (conn.getResponseCode() == 200) {
                        BufferedReader reader = new BufferedReader(
                            new InputStreamReader(conn.getInputStream())
                        );

                        List<Channel> sourceChannels = M3UParser.parse(reader);

                        for (Channel channel : sourceChannels) {
                            if (channel.getUrls().isEmpty()) continue;

                            String firstUrl = channel.getUrls().get(0);
                            if (!seenUrls.contains(firstUrl) && isQualityUrl(firstUrl)) {
                                allChannels.add(channel);
                                seenUrls.add(firstUrl);
                            }
                        }

                        successCount++;
                        break;
                    }
                } catch (Exception e) {
                    continue;
                }
            }
        }

        List<Channel> mergedChannels = mergeChannelsByName(allChannels);

        final int finalSuccessCount = successCount;
        mainHandler.post(() -> {
            if (mergedChannels.isEmpty()) {
                status.setText("加载失败，请检查网络");
                showIndicator("所有源均加载失败");
            } else {
                channels.clear();
                channels.addAll(mergedChannels);
                adapter.setChannels(channels);
                storage.saveChannels(channels);

                status.setText(String.format(
                    "加载成功：%d 个频道（来自 %d/%d 个源）",
                    channels.size(), finalSuccessCount, totalSources
                ));

                if (currentIndex >= channels.size()) {
                    currentIndex = 0;
                }
                playCurrent(false);
            }
        });
    });
}

/**
 * URL 质量筛选
 */
private boolean isQualityUrl(String url) {
    if (url == null || url.isEmpty()) return false;

    String lower = url.toLowerCase();

    // 排除测试链接
    if (lower.contains("test") || lower.contains("demo") || lower.contains("example")) {
        return false;
    }

    // 排除非标准端口
    if (lower.matches(".*:\\d{5,}.*")) {
        return false;
    }

    // 只接受常见协议
    return lower.startsWith("http://") || lower.startsWith("https://") ||
           lower.startsWith("rtmp://") || lower.startsWith("rtsp://");
}

/**
 * 合并同名频道
 */
private List<Channel> mergeChannelsByName(List<Channel> channels) {
    Map<String, Channel> mergedMap = new LinkedHashMap<>();

    for (Channel channel : channels) {
        String key = channel.getName().trim().toLowerCase();

        if (mergedMap.containsKey(key)) {
            Channel existing = mergedMap.get(key);
            for (String url : channel.getUrls()) {
                existing.addUrl(url);
            }
        } else {
            mergedMap.put(key, channel);
        }
    }

    return new ArrayList<>(mergedMap.values());
}

/**
 * 设置沉浸式全屏模式
 */
private void setupImmersiveMode() {
    Window window = getWindow();
    View decorView = window.getDecorView();

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        window.setDecorFitsSystemWindows(false);
        WindowInsetsController controller = window.getInsetsController();
        if (controller != null) {
            controller.hide(WindowInsets.Type.statusBars() | WindowInsets.Type.navigationBars());
            controller.setSystemBarsBehavior(
                WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            );
        }
    } else {
        int flags = View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY;
        decorView.setSystemUiVisibility(flags);
    }
}

/**
 * 应用沉浸式模式
 */
private void applyImmersiveMode() {
    Window window = getWindow();

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        WindowInsetsController controller = window.getInsetsController();
        if (controller != null) {
            controller.hide(WindowInsets.Type.statusBars() | WindowInsets.Type.navigationBars());
        }
    } else {
        window.getDecorView().setSystemUiVisibility(
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            | View.SYSTEM_UI_FLAG_FULLSCREEN
            | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        );
    }
}

@Override
public void onWindowFocusChanged(boolean hasFocus) {
    super.onWindowFocusChanged(hasFocus);
    if (hasFocus) {
        applyImmersiveMode();
    }
}

@Override
protected void onResume() {
    super.onResume();
    applyImmersiveMode();
}


// ============================================================================
// 修改7: 添加必要的导入（文件顶部）
// ============================================================================

// 在文件开头的 import 区域添加：
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import java.net.URL;
import java.net.HttpURLConnection;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.Map;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;


/*
 * ============================================================================
 * 修改完成！
 * ============================================================================
 *
 * 编译命令:
 *   cd android-native
 *   ./gradlew clean assembleDebug
 *
 * 安装命令:
 *   adb install -r app/build/outputs/apk/debug/app-debug.apk
 *
 * 测试要点:
 *   1. 切换速度是否变快（3秒内）
 *   2. 频道数量是否增加（800+）
 *   3. 全屏显示是否完美（无Home条）
 *
 * 如有问题，查看: THREE_ISSUES_FIX_GUIDE.md
 */
