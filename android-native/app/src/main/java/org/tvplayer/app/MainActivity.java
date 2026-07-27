package org.tvplayer.app;

import android.app.AlertDialog;
import android.content.Context;
import android.content.pm.ActivityInfo;
import android.net.ConnectivityManager;
import android.net.NetworkInfo;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.InputType;
import android.view.KeyEvent;
import android.view.GestureDetector;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;
import android.widget.Toast;
import android.view.inputmethod.InputMethodManager;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import android.widget.ArrayAdapter;

import com.google.android.exoplayer2.C;
import com.google.android.exoplayer2.ExoPlayer;
import com.google.android.exoplayer2.MediaItem;
import com.google.android.exoplayer2.Player;
import com.google.android.exoplayer2.ui.PlayerView;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class MainActivity extends AppCompatActivity {

    // 默认源：本仓库严格筛选 validated-channels（拉取时 MirrorResolver 扩镜像竞速）
    private static final String DEFAULT_SOURCE_URL =
            "https://cdn.jsdelivr.net/gh/wfygefjgd/live-player@main/iptv-mirrors/validated-channels.m3u";

    // 预置 M3U 源（与 iOS PRESET_SOURCES 对齐）
    private static final String[] MULTI_SOURCE_URLS = {
            "https://cdn.jsdelivr.net/gh/wfygefjgd/live-player@main/iptv-mirrors/validated-channels.m3u",
            "https://fastly.jsdelivr.net/gh/wfygefjgd/live-player@main/iptv-mirrors/validated-channels.m3u",
            "https://wfygefjgd.github.io/live-player/iptv-mirrors/validated-channels.m3u",
            "https://raw.githubusercontent.com/wfygefjgd/live-player/main/iptv-mirrors/validated-channels.m3u",
            "https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.m3u",
            "https://raw.githubusercontent.com/vbskycn/iptv/master/tv/iptv4.m3u",
            "https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u",
            "https://wfygefjgd.github.io/live-player/iptv-mirrors/burningc4-chinese-iptv.m3u",
            "https://wfygefjgd.github.io/live-player/iptv-mirrors/zbefine-iptv.m3u",
            "https://wfygefjgd.github.io/live-player/iptv-mirrors/suxuang-myiptv.m3u"
    };

    private static final long CHANNEL_OSD_MS = 2500L;
    private static final long CHANNEL_SWITCH_TIMEOUT_MS = 5000L;      // 5秒起播：给弱网出画机会
    private static final long STALL_TIMEOUT_MS = 4500L;               // 4.5秒持续卡顿才切
    private static final long FAST_FAIL_TIMEOUT_MS = 3500L;           // 自动换线后稍短超时
    private static final long NETWORK_WAIT_RETRY_MS = 500L;
    private static final long SILENT_AUDIO_CHECK_MS = 8000L;          // 8s 后再查无声，减少误切
    private static final long READY_PROTECT_MS = 2500L;               // 刚就绪保护期，避免误切
    private static final int AUTO_RECOVER_MAX_CHANNELS = 25;

    private PlayerView playerView;
    private ExoPlayer player;
    private View leftPanel;
    private TextView status;
    private TextView channelLabel;
    private TextView indicator;
    private TextView gestureHint;
    private View btnSourceManage;
    private RecyclerView channelList;

    private final List<Channel> channels = new ArrayList<>();
    private final List<String> sourceUrls = new ArrayList<>();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ExecutorService netPool = Executors.newFixedThreadPool(
            Math.max(2, Math.min(4, Runtime.getRuntime().availableProcessors() - 1)));

    private ChannelAdapter adapter;
    private AudioManager audioManager;
    private StorageHelper storage;
    private GestureDetector gestureDetector;
    private Runnable hideIndicatorRunnable;
    private Runnable hideChannelLabelRunnable;
    private Runnable stallRunnable;
    private Runnable silentAudioRunnable;
    private Runnable hideGestureHintRunnable;

    private int currentIndex = 0;
    private int currentSourceIndex = 0;
    private boolean panelVisible = false;
    private boolean loading = false;
    private int loadGeneration = 0;
    private boolean waitingForReady = false;
    private float brightness = 0.5f;
    private long pendingStallTimeoutMs = CHANNEL_SWITCH_TIMEOUT_MS;

    // 新增成员变量：网络检测
    private ConnectivityManager connectivityManager;
    private boolean isNetworkSlow = false;
    private int playbackToken = 0;
    private String activeSourceUrl = "";
    private boolean autoSwitchingSource = false;
    private boolean currentPlaybackReachedReady = false;
    private final Set<Integer> triedLineIndices = new HashSet<>();
    private int autoRecoverChannelHops = 0;
    private long readyAtMs = 0L;
    private int consecutiveBufferEvents = 0;
    private LineReputationStore reputation;
    private Runnable preferLineRunnable;
    private static final long PREFER_LINE_STABLE_MS = 6000L;

    /** 融合模式：off / fast / balanced / complete / smart（与 iOS 对齐） */
    private String fusionMode = "smart";

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // 设置沉浸式全屏
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

        // 再次应用沉浸式
        applyImmersiveMode();

        audioManager = (AudioManager) getSystemService(AUDIO_SERVICE);
        storage = new StorageHelper(this);
        reputation = new LineReputationStore(this);

        // 初始化网络管理器和检测
        connectivityManager = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
        checkNetworkSpeed();

        restoreSourceState();
        fusionMode = storage.loadFusionMode();
        if (fusionMode == null || fusionMode.isEmpty()) {
            fusionMode = "smart";
        }

        bindViews();
        setupPlayer();
        setupList();
        setupGestures();
        setupButtons();
        loadBrightness();
        loadChannels();
    }

    private void bindViews() {
        playerView = findViewById(R.id.player_view);
        leftPanel = findViewById(R.id.left_panel);
        status = findViewById(R.id.status);
        channelLabel = findViewById(R.id.channel_label);
        indicator = findViewById(R.id.indicator);
        gestureHint = findViewById(R.id.gesture_hint);
        btnSourceManage = findViewById(R.id.btn_source_manage);
        channelList = findViewById(R.id.channel_list);

        playerView.setUseController(false);
        playerView.setKeepContentOnPlayerReset(true);
        channelLabel.setVisibility(View.GONE);
        status.setVisibility(View.VISIBLE);
        leftPanel.setVisibility(View.GONE);
        if (gestureHint != null) {
            hideGestureHintRunnable = () -> {
                if (gestureHint != null) {
                    gestureHint.setVisibility(View.GONE);
                }
            };
            mainHandler.postDelayed(hideGestureHintRunnable, 5000L);
        }
    }

    private void setupPlayer() {
        player = new ExoPlayer.Builder(this).build();
        playerView.setPlayer(player);
        player.addListener(new Player.Listener() {
            @Override
            public void onPlaybackStateChanged(int state) {
                if (state == Player.STATE_READY) {
                    // 必须真正 isPlaying 才算就绪；仅 playWhenReady 是假 READY
                    boolean reallyPlaying = player != null && player.isPlaying();
                    waitingForReady = false;
                    autoSwitchingSource = false;
                    consecutiveBufferEvents = 0;
                    cancelStallCheck();
                    if (reallyPlaying) {
                        currentPlaybackReachedReady = true;
                        readyAtMs = System.currentTimeMillis();
                        autoRecoverChannelHops = 0;
                        scheduleSilentAudioCheck();
                        scheduleRememberPreferredLine();
                    } else {
                        // 假 READY：不写成功信誉，继续等出画/超时
                        currentPlaybackReachedReady = false;
                        scheduleStallCheck(STALL_TIMEOUT_MS);
                    }
                    return;
                }
                if (state == Player.STATE_BUFFERING) {
                    // 起播阶段：不要反复重置超时计时器（之前每次 BUFFERING 都会重装，导致永远不超时）
                    if (!currentPlaybackReachedReady) {
                        if (stallRunnable == null) {
                            scheduleStallCheck(pendingStallTimeoutMs);
                        }
                        return;
                    }
                    // 已出画后：累计缓冲，连续多次才进入卡顿计时
                    if (!inReadyProtect()) {
                        consecutiveBufferEvents++;
                        if (consecutiveBufferEvents >= 3 && stallRunnable == null) {
                            scheduleStallCheck(STALL_TIMEOUT_MS);
                        }
                    }
                    return;
                }
                cancelSilentAudioCheck();
                if (state == Player.STATE_IDLE || state == Player.STATE_ENDED) {
                    if (!currentPlaybackReachedReady) {
                        if (stallRunnable == null) {
                            scheduleStallCheck(pendingStallTimeoutMs);
                        }
                    } else if (!inReadyProtect() && stallRunnable == null) {
                        scheduleStallCheck(STALL_TIMEOUT_MS);
                    }
                }
            }

            @Override
            public void onIsPlayingChanged(boolean isPlaying) {
                if (isPlaying) {
                    consecutiveBufferEvents = 0;
                    // 仅取消“已出画后的卡顿检测”，不起播超时
                    if (currentPlaybackReachedReady) {
                        cancelStallCheck();
                    }
                }
            }

            @Override
            public void onPlayerError(com.google.android.exoplayer2.PlaybackException error) {
                mainHandler.post(() -> {
                    waitingForReady = false;
                    autoSwitchingSource = false;
                    cancelStallCheck();
                    cancelPreferLineTask();
                    switchToNextPlayableSource("线路失败", true, true);
                });
            }
        });
    }

    private void setupList() {
        adapter = new ChannelAdapter();
        channelList.setLayoutManager(new LinearLayoutManager(this));
        channelList.setAdapter(adapter);
        // 点选 / 遥控 OK 确认：播放并关侧栏（侧栏打开期间上下不直接换台）
        adapter.setOnChannelClick(this::selectChannelFromPanel);
        channelList.setDescendantFocusability(ViewGroup.FOCUS_AFTER_DESCENDANTS);
    }

    private void setupButtons() {
        if (btnSourceManage != null) {
            btnSourceManage.setFocusable(true);
            btnSourceManage.setClickable(true);
            btnSourceManage.setOnClickListener(v -> showSourceInputDialog());
        }
        if (status != null) {
            status.setFocusable(true);
            status.setClickable(true);
            status.setOnClickListener(v -> showSourceInputDialog());
        }
    }

    /** 侧栏确认选台：播放并关闭侧栏，之后才恢复全屏换台键 */
    private void selectChannelFromPanel(int position) {
        if (position < 0 || position >= channels.size()) {
            return;
        }
        currentIndex = position;
        currentSourceIndex = 0;
        resetTriedLines();
        autoRecoverChannelHops = 0;
        playCurrent(true);
        closePanel();
    }

    private void setupGestures() {
        gestureDetector = new GestureDetector(this, new GestureDetector.SimpleOnGestureListener() {
            private static final int SWIPE_MIN = 72;
            private static final int SWIPE_VEL = 120;

            @Override
            public boolean onDown(MotionEvent e) {
                return true;
            }

            /**
             * 触控分区（手机）：
             * - 左半屏：竖滑 fling = 换台；横滑 fling = 换线
             * - 右半屏：不处理音量/亮度（交给系统）
             * - 侧栏打开时：禁止画面换台/换线，避免与列表滚动冲突
             */
            @Override
            public boolean onFling(MotionEvent e1, MotionEvent e2, float velocityX, float velocityY) {
                if (e1 == null || e2 == null) {
                    return false;
                }
                if (panelVisible) {
                    return false;
                }
                int width = playerView.getWidth() > 0
                        ? playerView.getWidth()
                        : getResources().getDisplayMetrics().widthPixels;
                // 仅左半区响应换台/换线
                if (e1.getX() > width * 0.5f) {
                    return false;
                }
                float dx = e2.getX() - e1.getX();
                float dy = e2.getY() - e1.getY();
                // 横滑优先：换线
                if (Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > SWIPE_MIN && Math.abs(velocityX) > SWIPE_VEL) {
                    if (dx > 0) {
                        switchSource(-1, true);
                    } else {
                        switchSource(1, true);
                    }
                    return true;
                }
                // 竖滑：换台
                if (Math.abs(dy) > Math.abs(dx) && Math.abs(dy) > SWIPE_MIN && Math.abs(velocityY) > SWIPE_VEL) {
                    if (dy < 0) {
                        playNextChannel(true);
                    } else {
                        playPreviousChannel(true);
                    }
                    return true;
                }
                return false;
            }

            @Override
            public boolean onScroll(MotionEvent e1, MotionEvent e2, float distanceX, float distanceY) {
                // 不再用滑动调音量/亮度
                return false;
            }

            @Override
            public boolean onSingleTapConfirmed(MotionEvent e) {
                if (panelVisible) {
                    closePanel();
                    return true;
                }
                if (player != null) {
                    if (player.isPlaying()) {
                        player.pause();
                    } else {
                        player.play();
                    }
                }
                return true;
            }

            @Override
            public boolean onDoubleTap(MotionEvent e) {
                if (panelVisible) {
                    return false;
                }
                showSourceInputDialog();
                return true;
            }

            @Override
            public void onLongPress(MotionEvent e) {
                // 长按 = 开关侧栏（与遥控 OK 一致）
                togglePanel();
            }
        });

        View.OnTouchListener touchListener = (v, event) -> {
            // 点在侧栏上：交给列表，不走播放器手势
            if (panelVisible && isTouchOnPanel(event)) {
                return false;
            }
            // 侧栏打开时，点在画面上也可关栏（单击空白处）——仍允许 longPress/ fling 被上面 panelVisible 挡住
            return gestureDetector.onTouchEvent(event);
        };
        playerView.setOnTouchListener(touchListener);
        findViewById(R.id.root).setOnTouchListener(touchListener);
    }

    private boolean isTouchOnPanel(MotionEvent event) {
        if (leftPanel.getVisibility() != View.VISIBLE) {
            return false;
        }
        int[] loc = new int[2];
        leftPanel.getLocationOnScreen(loc);
        float x = event.getRawX();
        float y = event.getRawY();
        return x >= loc[0] && x <= loc[0] + leftPanel.getWidth()
                && y >= loc[1] && y <= loc[1] + leftPanel.getHeight();
    }

    private void loadBrightness() {
        try {
            int sys = Settings.System.getInt(getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, 128);
            brightness = Math.max(0.05f, Math.min(1f, sys / 255f));
        } catch (Exception e) {
            brightness = 0.5f;
        }
        applyBrightness();
    }

    private void applyBrightness() {
        WindowManager.LayoutParams lp = getWindow().getAttributes();
        lp.screenBrightness = brightness;
        getWindow().setAttributes(lp);
    }

    private void adjustBrightness(float delta) {
        brightness = Math.max(0.05f, Math.min(1f, brightness + delta));
        applyBrightness();
        showIndicator(getString(R.string.brightness) + " " + (int) (brightness * 100) + "%");
    }

    private void adjustVolume(int direction) {
        if (audioManager == null) {
            return;
        }
        int max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
        int cur = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC);
        int next = Math.max(0, Math.min(max, cur + direction));
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, next, 0);
        int pct = max == 0 ? 0 : (int) (next * 100f / max);
        showIndicator(getString(R.string.volume) + " " + pct + "%");
    }

    private void showIndicator(String text) {
        indicator.setText(text);
        indicator.setVisibility(View.VISIBLE);
        if (hideIndicatorRunnable != null) {
            mainHandler.removeCallbacks(hideIndicatorRunnable);
        }
        hideIndicatorRunnable = () -> indicator.setVisibility(View.GONE);
        mainHandler.postDelayed(hideIndicatorRunnable, 1200);
    }

    private void showChannelOsd() {
        if (channels.isEmpty() || currentIndex < 0 || currentIndex >= channels.size()) {
            return;
        }
        Channel channel = channels.get(currentIndex);
        String text = (currentIndex + 1) + "/" + channels.size() + " " + channel.name;
        if (channel.getSourceCount() > 1) {
            text += " 线路 " + (currentSourceIndex + 1) + "/" + channel.getSourceCount();
        }
        channelLabel.setText(text);
        channelLabel.setVisibility(View.VISIBLE);
        if (hideChannelLabelRunnable != null) {
            mainHandler.removeCallbacks(hideChannelLabelRunnable);
        }
        hideChannelLabelRunnable = () -> channelLabel.setVisibility(View.GONE);
        mainHandler.postDelayed(hideChannelLabelRunnable, CHANNEL_OSD_MS);
    }

    private void togglePanel() {
        if (panelVisible) {
            closePanel();
        } else {
            openPanel();
        }
    }

    private void openPanel() {
        panelVisible = true;
        if (leftPanel != null) {
            leftPanel.setVisibility(View.VISIBLE);
            leftPanel.bringToFront();
            leftPanel.setFocusable(true);
        }
        if (btnSourceManage != null) {
            btnSourceManage.setFocusable(true);
        }
        if (channelList != null) {
            channelList.setFocusable(true);
            channelList.setDescendantFocusability(ViewGroup.FOCUS_AFTER_DESCENDANTS);
            if (currentIndex >= 0 && currentIndex < channels.size()) {
                channelList.scrollToPosition(currentIndex);
            }
            channelList.post(() -> {
                int idx = Math.max(0, Math.min(currentIndex, channels.size() - 1));
                RecyclerView.ViewHolder vh = channelList.findViewHolderForAdapterPosition(idx);
                if (vh != null) {
                    vh.itemView.requestFocus();
                } else if (btnSourceManage != null) {
                    btnSourceManage.requestFocus();
                } else {
                    channelList.requestFocus();
                }
            });
        }
    }

    private void closePanel() {
        panelVisible = false;
        if (leftPanel != null) {
            leftPanel.setVisibility(View.GONE);
        }
        if (playerView != null) {
            playerView.requestFocus();
        }
    }

    /**
     * 侧栏打开时按 OK：确认当前焦点项。
     * - 焦点在频道行 → 播放并关栏
     * - 焦点在「源管理」→ 打开源对话框
     * - 其它 → 仅关栏回到画面（恢复换台键）
     */
    private boolean handlePanelOkKey() {
        if (!panelVisible) {
            openPanel();
            return true;
        }
        View focus = getCurrentFocus();
        if (focus != null && btnSourceManage != null
                && (focus == btnSourceManage || focus.getId() == R.id.btn_source_manage)) {
            showSourceInputDialog();
            return true;
        }
        if (focus != null && status != null && focus == status) {
            showSourceInputDialog();
            return true;
        }
        if (focus != null && channelList != null) {
            View item = focus;
            while (item != null && item.getParent() != channelList) {
                if (!(item.getParent() instanceof View)) {
                    break;
                }
                item = (View) item.getParent();
            }
            if (item != null && item.getParent() == channelList) {
                int pos = channelList.getChildAdapterPosition(item);
                if (pos == RecyclerView.NO_POSITION && item.getTag() instanceof Integer) {
                    pos = (Integer) item.getTag();
                }
                if (pos >= 0 && pos < channels.size()) {
                    selectChannelFromPanel(pos);
                    return true;
                }
            }
        }
        // 无明确选中：关栏回到全屏（换台键恢复）
        closePanel();
        return true;
    }

    private void restoreLastChannelPosition() {
        if (channels.isEmpty()) {
            currentIndex = 0;
            currentSourceIndex = 0;
            return;
        }
        String key = storage.loadLastChannelKey();
        int si = storage.loadLastSourceIndex();
        if (key != null && !key.isEmpty()) {
            for (int i = 0; i < channels.size(); i++) {
                if (key.equals(channels.get(i).key)) {
                    currentIndex = i;
                    int cnt = channels.get(i).getSourceCount();
                    currentSourceIndex = cnt <= 0 ? 0 : Math.min(Math.max(0, si), cnt - 1);
                    return;
                }
            }
        }
        // 默认 CCTV
        for (int i = 0; i < channels.size(); i++) {
            String n = channels.get(i).name;
            if (n != null && (n.contains("CCTV") || n.contains("央视") || n.toLowerCase().contains("cctv"))) {
                currentIndex = i;
                currentSourceIndex = 0;
                return;
            }
        }
        currentIndex = 0;
        currentSourceIndex = 0;
    }
    private void loadChannels() {
        loadChannels(true);
    }

    /** @param useCache 冷启动可用缓存；换源传 false，避免播错旧融合列表 */
    private void loadChannels(boolean useCache) {
        loading = true;
        waitingForReady = false;
        cancelStallCheck();

        if (useCache) {
            List<Channel> cached = storage.loadChannels();
            final boolean hasCache = cached != null && !cached.isEmpty();
            if (channels.isEmpty() && hasCache) {
                channels.clear();
                channels.addAll(cached);
                reputation.applyToChannels(channels);
                adapter.setData(channels);
                restoreLastChannelPosition();
                status.setText(String.format("已加载 %d 个频道（缓存）", channels.size()));
                playCurrent(false, CHANNEL_SWITCH_TIMEOUT_MS);
            }
        }

        loadChannelsFromMultiSources();
    }

    private List<Channel> fetchChannels() {
        for (String logical : buildSourceCandidates()) {
            try {
                String body = httpGetWithMirrors(logical);
                if (body != null && !body.isEmpty()) {
                    List<Channel> parsed = M3UParser.parse(body);
                    if (!parsed.isEmpty()) {
                        return parsed;
                    }
                }
            } catch (Exception ignored) {
            }
        }
        return new ArrayList<>();
    }

    /** 逻辑源列表（未展开镜像）；实际拉取走 httpGetWithMirrors */
    private List<String> buildSourceCandidates() {
        LinkedHashSet<String> urls = new LinkedHashSet<>();
        if (activeSourceUrl != null && !activeSourceUrl.isEmpty()) {
            urls.add(activeSourceUrl.trim());
        }
        if (sourceUrls != null) {
            for (String u : sourceUrls) {
                if (u != null && !u.trim().isEmpty()) urls.add(u.trim());
            }
        }
        for (String sourceUrl : MULTI_SOURCE_URLS) {
            urls.add(sourceUrl);
        }
        if (urls.isEmpty()) {
            urls.add(DEFAULT_SOURCE_URL);
        }
        return new ArrayList<>(urls);
    }

    private void showSourceInputDialog() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(16);
        root.setPadding(pad, pad, pad, pad);
        root.setFocusable(false);

        Button fusionButton = new Button(this);
        fusionButton.setText("融合模式: " + fusionModeLabel(fusionMode));
        fusionButton.setFocusable(true);
        fusionButton.setAllCaps(false);
        root.addView(fusionButton, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        // 输入框：电视/手机均可获焦并弹键盘
        final EditText input = new EditText(this);
        input.setSingleLine(true);
        input.setFocusable(true);
        input.setFocusableInTouchMode(true);
        input.setClickable(true);
        input.setLongClickable(true);
        input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        input.setImeOptions(android.view.inputmethod.EditorInfo.IME_FLAG_NO_FULLSCREEN
                | android.view.inputmethod.EditorInfo.IME_ACTION_DONE);
        input.setHint("输入 m3u / m3u8 地址（点此弹出键盘）");
        input.setPrivateImeOptions("inputType=InputType.TYPE_CLASS_TEXT");
        root.addView(input, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        LinearLayout actions = new LinearLayout(this);
        actions.setOrientation(LinearLayout.HORIZONTAL);
        root.addView(actions, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        Button addButton = new Button(this);
        addButton.setText("添加");
        addButton.setFocusable(true);
        actions.addView(addButton, new LinearLayout.LayoutParams(
                0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));

        Button deleteButton = new Button(this);
        deleteButton.setText("删除");
        deleteButton.setFocusable(true);
        actions.addView(deleteButton, new LinearLayout.LayoutParams(
                0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));

        ListView listView = new ListView(this);
        listView.setFocusable(true);
        listView.setItemsCanFocus(true);
        root.addView(listView, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, dp(260)));

        List<String> dialogSources = new ArrayList<>(sourceUrls);
        ArrayAdapter<String> srcAdapter = new ArrayAdapter<>(
                this, android.R.layout.simple_list_item_single_choice, dialogSources);
        listView.setChoiceMode(ListView.CHOICE_MODE_SINGLE);
        listView.setAdapter(srcAdapter);
        int checked = dialogSources.indexOf(activeSourceUrl);
        if (checked >= 0) {
            listView.setItemChecked(checked, true);
        }

        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle("选择直播源")
                .setView(root)
                .setNegativeButton("关闭", null)
                .create();

        final int[] selectedIndex = {checked};

        fusionButton.setOnClickListener(v -> showFusionModeDialog(fusionButton));

        Runnable showKeyboard = () -> {
            input.requestFocus();
            input.postDelayed(() -> {
                InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
                if (imm != null) {
                    imm.restartInput(input);
                    // SHOW_FORCED：电视/部分盒子 IMPLICIT 不出键盘
                    imm.showSoftInput(input, InputMethodManager.SHOW_FORCED);
                }
                if (dialog.getWindow() != null) {
                    dialog.getWindow().setSoftInputMode(
                            WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE
                                    | WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
                }
            }, 120);
        };

        input.setOnFocusChangeListener((v, hasFocus) -> {
            if (hasFocus) {
                showKeyboard.run();
            }
        });
        input.setOnClickListener(v -> showKeyboard.run());

        addButton.setOnClickListener(v -> {
            String url = input.getText().toString().trim();
            if (url.isEmpty()) {
                showIndicator("源地址不能为空");
                showKeyboard.run();
                return;
            }
            if (!dialogSources.contains(url)) {
                dialogSources.add(url);
                sourceUrls.clear();
                sourceUrls.addAll(dialogSources);
                persistSourceState();
                srcAdapter.notifyDataSetChanged();
            }
            int idx = dialogSources.indexOf(url);
            if (idx >= 0) {
                selectedIndex[0] = idx;
                listView.setItemChecked(idx, true);
            }
            input.setText("");
            selectSource(url);
            dialog.dismiss();
        });

        deleteButton.setOnClickListener(v -> {
            int idx = listView.getCheckedItemPosition();
            if (idx == ListView.INVALID_POSITION && selectedIndex[0] >= 0 && selectedIndex[0] < dialogSources.size()) {
                idx = selectedIndex[0];
            }
            if (idx < 0 || idx >= dialogSources.size()) {
                showIndicator("请先选择要删除的源");
                return;
            }
            String target = dialogSources.get(idx);
            dialogSources.remove(idx);
            sourceUrls.clear();
            sourceUrls.addAll(dialogSources);
            if (target.equals(activeSourceUrl)) {
                activeSourceUrl = dialogSources.isEmpty() ? "" : dialogSources.get(0);
                persistSourceState();
                srcAdapter.notifyDataSetChanged();
                dialog.dismiss();
                reloadActiveSource();
                return;
            }
            persistSourceState();
            srcAdapter.notifyDataSetChanged();
            selectedIndex[0] = dialogSources.indexOf(activeSourceUrl);
            listView.clearChoices();
            if (selectedIndex[0] >= 0) {
                listView.setItemChecked(selectedIndex[0], true);
            }
        });

        listView.setOnItemClickListener((parent, view, position, id) -> {
            selectedIndex[0] = position;
            selectSource(dialogSources.get(position));
            dialog.dismiss();
        });

        dialog.setOnShowListener(d -> {
            if (dialog.getWindow() != null) {
                dialog.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM);
                dialog.getWindow().setSoftInputMode(
                        WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE
                                | WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
            }
            // 先让融合/列表可 DPAD；点输入框再弹键盘
            fusionButton.requestFocus();
        });

        dialog.show();
    }

    private void selectSource(String url) {
        String clean = url == null ? "" : url.trim();
        if (clean.isEmpty()) {
            showIndicator("源地址不能为空");
            return;
        }
        if (clean.equals(activeSourceUrl)) {
            return;
        }
        activeSourceUrl = clean;
        persistSourceState();
        reloadActiveSource();
    }

    private void reloadActiveSource() {
        channels.clear();
        adapter.setData(channels);
        currentIndex = 0;
        currentSourceIndex = 0;
        resetTriedLines();
        autoRecoverChannelHops = 0;
        if (player != null) {
            player.stop();
            player.clearMediaItems();
        }
        status.setText("正在切换源...");
        // 换源禁止灌入旧融合缓存
        loadChannels(false);
    }

    private void restoreSourceState() {
        LinkedHashSet<String> urls = new LinkedHashSet<>();
        for (String preset : MULTI_SOURCE_URLS) {
            urls.add(preset);
        }
        urls.addAll(storage.loadSourceUrls());
        String legacy = storage.loadCustomSourceUrl();
        if (legacy != null && !legacy.trim().isEmpty()) {
            urls.add(legacy.trim());
        }
        sourceUrls.clear();
        sourceUrls.addAll(urls);
        String selected = storage.loadSelectedSourceUrl();
        if (selected != null && !selected.trim().isEmpty()) {
            activeSourceUrl = selected.trim();
            if (!sourceUrls.contains(activeSourceUrl)) {
                sourceUrls.add(activeSourceUrl);
            }
        } else {
            activeSourceUrl = DEFAULT_SOURCE_URL;
            if (!sourceUrls.contains(activeSourceUrl)) {
                sourceUrls.add(0, activeSourceUrl);
            }
        }
        persistSourceState();
    }

    private void persistSourceState() {
        storage.saveSourceUrls(sourceUrls);
        storage.saveSelectedSourceUrl(activeSourceUrl);
        storage.saveCustomSourceUrl(activeSourceUrl);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private String httpGet(String urlStr) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(urlStr).openConnection();
        conn.setConnectTimeout(6000);
        conn.setReadTimeout(10000);
        conn.setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android 10) TVPlayer/1.5.6");
        conn.setInstanceFollowRedirects(true);
        int code = conn.getResponseCode();
        if (code < 200 || code >= 300) {
            conn.disconnect();
            return null;
        }
        InputStream is = conn.getInputStream();
        BufferedReader br = new BufferedReader(new InputStreamReader(is, "UTF-8"));
        StringBuilder sb = new StringBuilder();
        String line;
        while ((line = br.readLine()) != null) {
            sb.append(line).append('\n');
        }
        br.close();
        conn.disconnect();
        return sb.toString();
    }

    /**
     * 单一逻辑源 + 镜像竞速：GitHub 系地址自动展开镜像并发请求，任一候选返回可用文本即胜出。
     * 对齐 iOS NetworkService.fetchTextWithMirrors。
     */
    private String httpGetWithMirrors(String logicalUrl) {
        if (logicalUrl == null || logicalUrl.trim().isEmpty()) return null;
        List<String> candidates = MirrorResolver.candidates(logicalUrl.trim());
        if (candidates.isEmpty()) return null;
        if (candidates.size() == 1) {
            try {
                return httpGet(candidates.get(0));
            } catch (Exception e) {
                return null;
            }
        }
        final java.util.concurrent.atomic.AtomicReference<String> winner =
                new java.util.concurrent.atomic.AtomicReference<>();
        final java.util.concurrent.CountDownLatch done =
                new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.atomic.AtomicInteger remaining =
                new java.util.concurrent.atomic.AtomicInteger(candidates.size());
        for (String cand : candidates) {
            netPool.execute(() -> {
                if (winner.get() != null) {
                    if (remaining.decrementAndGet() == 0) done.countDown();
                    return;
                }
                try {
                    String body = httpGet(cand);
                    if (body != null && !body.isEmpty()) {
                        if (winner.compareAndSet(null, body)) {
                            done.countDown();
                        }
                    }
                } catch (Exception ignored) {
                } finally {
                    if (remaining.decrementAndGet() == 0) {
                        done.countDown();
                    }
                }
            });
        }
        try {
            done.await(12, java.util.concurrent.TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        return winner.get();
    }

    private boolean inReadyProtect() {
        return currentPlaybackReachedReady
                && readyAtMs > 0
                && (System.currentTimeMillis() - readyAtMs) < READY_PROTECT_MS;
    }

    private void scheduleStallCheck(long timeoutMs) {
        if (channels.isEmpty()) {
            return;
        }
        // 已出画且在保护期内：不因短暂缓冲误切
        if (currentPlaybackReachedReady && inReadyProtect()) {
            return;
        }
        // 起播阶段必须 waiting；已出画后的卡顿检测允许在 BUFFERING 触发
        if (!waitingForReady && !currentPlaybackReachedReady) {
            return;
        }
        cancelStallCheck();
        final int token = playbackToken;
        final boolean wasReady = currentPlaybackReachedReady;
        if (!hasNetworkConnection()) {
            stallRunnable = () -> {
                if (token == playbackToken) {
                    scheduleStallCheck(timeoutMs);
                }
            };
            mainHandler.postDelayed(stallRunnable, NETWORK_WAIT_RETRY_MS);
            return;
        }
        stallRunnable = () -> {
            if (token != playbackToken) {
                return;
            }
            // 若已恢复播放则不切
            if (player != null && player.isPlaying() && player.getPlaybackState() == Player.STATE_READY) {
                consecutiveBufferEvents = 0;
                return;
            }
            if (wasReady && inReadyProtect()) {
                return;
            }
            // 已出画：需仍处于缓冲/不可播，才确认卡顿
            if (wasReady) {
                if (player != null && player.isPlaying()
                        && player.getPlaybackState() == Player.STATE_READY) {
                    consecutiveBufferEvents = 0;
                    return;
                }
                // 用户暂停时不自动切
                if (player != null && !player.getPlayWhenReady()) {
                    return;
                }
                waitingForReady = false;
                autoSwitchingSource = false;
                switchToNextPlayableSource("画面持续卡顿", true, true);
                return;
            }
            if (waitingForReady || !currentPlaybackReachedReady) {
                // 起播超时：仍未真正出画
                if (player != null && player.isPlaying()
                        && player.getPlaybackState() == Player.STATE_READY) {
                    return;
                }
                waitingForReady = false;
                autoSwitchingSource = false;
                switchToNextPlayableSource("线路超时无画面", true, true);
            }
        };
        mainHandler.postDelayed(stallRunnable, timeoutMs);
    }

    private void scheduleSilentAudioCheck() {
        cancelSilentAudioCheck();
        if (channels.isEmpty() || currentIndex < 0 || currentIndex >= channels.size()) {
            return;
        }
        // 单线路频道很多本身无音轨，不因无声误切
        Channel ch = channels.get(currentIndex);
        if (ch.getSourceCount() <= 1) {
            return;
        }
        final int token = playbackToken;
        silentAudioRunnable = () -> {
            if (token != playbackToken) {
                return;
            }
            if (player == null || player.getPlaybackState() != Player.STATE_READY) {
                return;
            }
            if (!currentPlaybackReachedReady || inReadyProtect()) {
                return;
            }
            if (hasAudioTrack()) {
                return;
            }
            // 再等一轮确认（HLS 晚选轨）
            mainHandler.postDelayed(() -> {
                if (token != playbackToken) return;
                if (player == null || !currentPlaybackReachedReady) return;
                if (hasAudioTrack()) return;
                switchToNextPlayableSource("当前线路无声音", true, true);
            }, 1500L);
        };
        mainHandler.postDelayed(silentAudioRunnable, SILENT_AUDIO_CHECK_MS);
    }

    private void cancelStallCheck() {
        if (stallRunnable != null) {
            mainHandler.removeCallbacks(stallRunnable);
            stallRunnable = null;
        }
    }

    private void cancelSilentAudioCheck() {
        if (silentAudioRunnable != null) {
            mainHandler.removeCallbacks(silentAudioRunnable);
            silentAudioRunnable = null;
        }
    }

    private void resetTriedLines() {
        triedLineIndices.clear();
    }

    private void cancelPreferLineTask() {
        if (preferLineRunnable != null) {
            mainHandler.removeCallbacks(preferLineRunnable);
            preferLineRunnable = null;
        }
    }

    private void scheduleRememberPreferredLine() {
        cancelPreferLineTask();
        if (channels.isEmpty() || currentIndex < 0 || currentIndex >= channels.size()) {
            return;
        }
        final int token = playbackToken;
        final Channel ch = channels.get(currentIndex);
        final String key = ch.key;
        final String url = (currentSourceIndex >= 0 && currentSourceIndex < ch.getSourceCount())
                ? ch.getUrls().get(currentSourceIndex) : "";
        preferLineRunnable = () -> {
            if (token != playbackToken || !currentPlaybackReachedReady) {
                return;
            }
            if (player == null || !player.isPlaying()) {
                return;
            }
            if (url != null && !url.isEmpty()) {
                reputation.markSuccess(url, key);
            }
        };
        mainHandler.postDelayed(preferLineRunnable, PREFER_LINE_STABLE_MS);
    }

    private boolean isPlayableUrl(String url) {
        if (url == null) {
            return false;
        }
        String u = url.trim().toLowerCase();
        return u.startsWith("http://") || u.startsWith("https://")
                || u.startsWith("rtmp://") || u.startsWith("rtsp://");
    }

    private void playCurrent(boolean showOsd, long timeoutMs) {
        if (channels.isEmpty() || currentIndex < 0 || currentIndex >= channels.size()) {
            return;
        }
        Channel channel = channels.get(currentIndex);
        // 信誉重排：好线靠前、黑名单后置
        List<String> ordered = reputation.orderedURLs(channel.getUrls(), channel.key);
        if (!ordered.equals(channel.getUrls())) {
            Channel nc = new Channel(channel.name, channel.group, channel.key, ordered);
            channels.set(currentIndex, nc);
            channel = nc;
            if (adapter != null) {
                adapter.setData(channels);
            }
        }
        int count = channel.getSourceCount();
        if (count <= 0) {
            waitingForReady = false;
            showIndicator("当前频道地址无效");
            switchToNextPlayableSource("当前频道地址无效", true, true);
            return;
        }

        // 本台首次尝试：偏好 URL 或首条未拉黑线
        if (triedLineIndices.isEmpty()) {
            String pref = reputation.preferredURL(channel.key);
            if (pref != null) {
                int pi = channel.getUrls().indexOf(pref);
                if (pi >= 0) {
                    currentSourceIndex = pi;
                }
            } else {
                for (int i = 0; i < count; i++) {
                    if (!reputation.isBlacklisted(channel.getUrls().get(i))) {
                        currentSourceIndex = i;
                        break;
                    }
                }
            }
        }
        if (currentSourceIndex < 0 || currentSourceIndex >= count) {
            currentSourceIndex = 0;
        }

        // 跳过非法 URL / 黑名单（保留至少一条兜底）
        int guard = 0;
        String url = "";
        while (guard < count) {
            guard++;
            if (currentSourceIndex < 0 || currentSourceIndex >= count) {
                currentSourceIndex = 0;
            }
            url = channel.getUrls().get(currentSourceIndex);
            boolean black = reputation.isBlacklisted(url) && triedLineIndices.size() < count - 1;
            if (isPlayableUrl(url) && !black) {
                break;
            }
            triedLineIndices.add(currentSourceIndex);
            currentSourceIndex = (currentSourceIndex + 1) % count;
            url = "";
        }
        if (!isPlayableUrl(url)) {
            waitingForReady = false;
            showIndicator("当前频道地址无效");
            switchToNextPlayableSource("当前频道地址无效", true, true);
            return;
        }

        adapter.setSelected(currentIndex);
        channelList.scrollToPosition(currentIndex);
        if (channel.key != null) {
            storage.saveLastChannel(channel.key, currentSourceIndex);
        }
        playbackToken++;
        waitingForReady = true;
        autoSwitchingSource = false;
        currentPlaybackReachedReady = false;
        readyAtMs = 0L;
        consecutiveBufferEvents = 0;
        pendingStallTimeoutMs = timeoutMs;
        triedLineIndices.add(currentSourceIndex);
        cancelSilentAudioCheck();
        cancelPreferLineTask();
        // 起播只装一次超时，避免 BUFFERING 反复重置
        scheduleStallCheck(timeoutMs);

        try {
            player.setMediaItem(MediaItem.fromUri(Uri.parse(url)));
            player.prepare();
            player.play();
            if (showOsd) {
                showChannelOsd();
            }
        } catch (Exception e) {
            waitingForReady = false;
            autoSwitchingSource = false;
            cancelStallCheck();
            switchToNextPlayableSource("线路失败", true, true);
        }
    }

    private void playCurrent(boolean showOsd) {
        playCurrent(showOsd, CHANNEL_SWITCH_TIMEOUT_MS);
    }

    private void playNextChannel(boolean showOsd) {
        if (channels.isEmpty()) {
            return;
        }
        currentIndex = (currentIndex + 1) % channels.size();
        currentSourceIndex = 0;
        resetTriedLines();
        autoRecoverChannelHops = 0;
        playCurrent(showOsd, CHANNEL_SWITCH_TIMEOUT_MS);
    }

    private void playPreviousChannel(boolean showOsd) {
        if (channels.isEmpty()) {
            return;
        }
        currentIndex = (currentIndex - 1 + channels.size()) % channels.size();
        currentSourceIndex = 0;
        resetTriedLines();
        autoRecoverChannelHops = 0;
        playCurrent(showOsd, CHANNEL_SWITCH_TIMEOUT_MS);
    }

    private void switchSource(int direction, boolean showOsd) {
        if (channels.isEmpty() || currentIndex < 0 || currentIndex >= channels.size()) {
            return;
        }
        Channel channel = channels.get(currentIndex);
        if (channel.getSourceCount() <= 1) {
            showIndicator("当前频道只有一个来源");
            if (showOsd) {
                showChannelOsd();
            }
            return;
        }
        int count = channel.getSourceCount();
        currentSourceIndex = (currentSourceIndex + direction + count) % count;
        resetTriedLines();
        autoRecoverChannelHops = 0;
        playCurrent(showOsd, CHANNEL_SWITCH_TIMEOUT_MS);
    }

    /** 兼容旧调用 */
    private void switchToNextPlayableSource(String hint, boolean showOsd) {
        switchToNextPlayableSource(hint, showOsd, true);
    }

    /**
     * 自动换线：仅 confirmedBad 时切换；试完本台所有线路后自动下一台，直到出画。
     */
    private void switchToNextPlayableSource(String hint, boolean showOsd, boolean confirmedBad) {
        if (!confirmedBad) {
            showIndicator(hint);
            return;
        }
        if (channels.isEmpty() || currentIndex < 0 || currentIndex >= channels.size()) {
            showIndicator(hint);
            return;
        }
        // autoSwitchingSource 仅作短互斥；硬失败时强制放行，避免卡死
        if (autoSwitchingSource) {
            autoSwitchingSource = false;
        }
        Channel channel = channels.get(currentIndex);
        int count = channel.getSourceCount();
        cancelSilentAudioCheck();
        cancelPreferLineTask();
        triedLineIndices.add(currentSourceIndex);
        // 写入信誉：失败线 24h 拉黑，避免明天再踩
        if (currentSourceIndex >= 0 && currentSourceIndex < count) {
            String failUrl = channel.getUrls().get(currentSourceIndex);
            reputation.markFailure(failUrl, channel.key, true);
        }

        // 多线路：按信誉顺序找未试过且合法的下一条
        if (count > 1) {
            List<String> candidates = reputation.orderedURLs(channel.getUrls(), channel.key);
            for (String candidate : candidates) {
                int next = channel.getUrls().indexOf(candidate);
                if (next < 0 || triedLineIndices.contains(next)) {
                    continue;
                }
                if (reputation.isBlacklisted(candidate) && triedLineIndices.size() + 1 < count) {
                    triedLineIndices.add(next);
                    continue;
                }
                if (isPlayableUrl(candidate)) {
                    autoSwitchingSource = true;
                    currentSourceIndex = next;
                    showIndicator(hint + " · 线路 " + (next + 1) + "/" + count);
                    playCurrent(showOsd, FAST_FAIL_TIMEOUT_MS);
                    return;
                }
                triedLineIndices.add(next);
            }
        }

        // 本台线路耗尽 → 自动下一频道
        autoSwitchingSource = false;
        if (autoRecoverChannelHops >= AUTO_RECOVER_MAX_CHANNELS) {
            showIndicator("连续多台无可用线路，请手动换台或换源");
            return;
        }
        autoRecoverChannelHops++;
        showIndicator(hint + " · 本台不可用，切下一台");
        currentIndex = (currentIndex + 1) % channels.size();
        currentSourceIndex = 0;
        resetTriedLines();
        playCurrent(showOsd, CHANNEL_SWITCH_TIMEOUT_MS);
    }

    private boolean hasAudioTrack() {
        if (player == null) {
            return false;
        }
        try {
            // 有可选音轨即视为有声；未 selected 时很多 HLS 仍在协商
            if (player.getCurrentTracks().isTypeSelected(C.TRACK_TYPE_AUDIO)) {
                return true;
            }
            // 遍历分组看是否存在 audio track group
            com.google.android.exoplayer2.Tracks tracks = player.getCurrentTracks();
            for (int i = 0; i < tracks.getGroups().size(); i++) {
                com.google.android.exoplayer2.Tracks.Group g = tracks.getGroups().get(i);
                if (g.getType() == C.TRACK_TYPE_AUDIO && g.length > 0) {
                    return true;
                }
            }
            return false;
        } catch (Exception e) {
            return true; // 不确定时不误切
        }
    }

    private List<Channel> applyChannelLineRules(List<Channel> input) {
        List<Channel> output = new ArrayList<>();
        if (input == null) {
            return output;
        }
        for (Channel source : input) {
            if (source == null) {
                continue;
            }
            Channel filtered = new Channel(source.name, source.group, source.key, null);
            List<String> urls = source.getUrls();
            for (int i = 0; i < urls.size(); i++) {
                String url = urls.get(i);
                if (storage.isLineHidden(url)) {
                    continue;
                }
                if (shouldSkipChannelLine(source.key, i, url)) {
                    continue;
                }
                filtered.addUrl(url);
            }
            if (filtered.getSourceCount() > 0) {
                output.add(filtered);
            }
        }
        return output;
    }

    /**
     * 判断是否应跳过该线路（黑名单 / 无效协议 / 质量过滤）
     * 对齐 iOS applyRules + M3UParser 质量筛选逻辑
     */
    private boolean shouldSkipChannelLine(String key, int index, String url) {
        if (url == null || url.trim().isEmpty()) {
            return true;
        }
        // 黑名单线路：跳过（保留至少一条兜底）
        if (reputation != null && reputation.isBlacklisted(url)) {
            return true;
        }
        // 无效协议
        String u = url.trim().toLowerCase();
        if (!u.startsWith("http://") && !u.startsWith("https://")
                && !u.startsWith("rtmp://") && !u.startsWith("rtsp://")) {
            return true;
        }
        // 测试/示例链接
        if (u.contains("test") || u.contains("demo") || u.contains("example")) {
            return true;
        }
        // 非标准端口（排除常见端口）
        try {
            java.net.URI uri = new java.net.URI(url);
            int port = uri.getPort();
            if (port > 0 && port != 80 && port != 443 && port != 8080 && port != 1935) {
                return true;
            }
        } catch (Exception ignored) {
        }
        return false;
    }

    private boolean hasNetworkConnection() {
        ConnectivityManager cm = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
        if (cm == null) {
            return false;
        }
        try {
            NetworkInfo info = cm.getActiveNetworkInfo();
            return info != null && info.isConnected();
        } catch (Exception ignored) {
            return false;
        }
    }

    /**
     * 电视遥控：
     * - 侧栏关闭：上/下换台，左/右换线，OK 开侧栏
     * - 侧栏打开：上/下/左/右只移动焦点（不换台）；OK=确认选台并关栏（或进源管理）
     * - 返回：侧栏开着则只关栏
     */
    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER
                || keyCode == KeyEvent.KEYCODE_ENTER
                || keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER
                || keyCode == KeyEvent.KEYCODE_BUTTON_A) {
            return handlePanelOkKey();
        }
        if (keyCode == KeyEvent.KEYCODE_BACK || keyCode == KeyEvent.KEYCODE_ESCAPE) {
            if (panelVisible) {
                closePanel();
                return true;
            }
        }

        // 侧栏打开：方向键全部交给侧栏焦点链，禁止换台/换线
        if (panelVisible) {
            if (keyCode == KeyEvent.KEYCODE_DPAD_UP
                    || keyCode == KeyEvent.KEYCODE_DPAD_DOWN
                    || keyCode == KeyEvent.KEYCODE_DPAD_LEFT
                    || keyCode == KeyEvent.KEYCODE_DPAD_RIGHT
                    || keyCode == KeyEvent.KEYCODE_CHANNEL_UP
                    || keyCode == KeyEvent.KEYCODE_CHANNEL_DOWN
                    || keyCode == KeyEvent.KEYCODE_PAGE_UP
                    || keyCode == KeyEvent.KEYCODE_PAGE_DOWN) {
                return super.onKeyDown(keyCode, event);
            }
            // 其它媒体键在侧栏打开时也不换台
            if (keyCode == KeyEvent.KEYCODE_MEDIA_NEXT
                    || keyCode == KeyEvent.KEYCODE_MEDIA_PREVIOUS
                    || keyCode == KeyEvent.KEYCODE_MEDIA_FAST_FORWARD
                    || keyCode == KeyEvent.KEYCODE_MEDIA_REWIND) {
                return true;
            }
            return super.onKeyDown(keyCode, event);
        }

        // 侧栏关闭 = 全屏播放：换台 / 换线
        if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT
                || keyCode == KeyEvent.KEYCODE_MEDIA_REWIND
                || keyCode == KeyEvent.KEYCODE_MEDIA_PREVIOUS) {
            switchSource(-1, true);
            return true;
        }
        if (keyCode == KeyEvent.KEYCODE_DPAD_RIGHT
                || keyCode == KeyEvent.KEYCODE_MEDIA_FAST_FORWARD
                || keyCode == KeyEvent.KEYCODE_MEDIA_NEXT) {
            switchSource(1, true);
            return true;
        }
        if (keyCode == KeyEvent.KEYCODE_DPAD_UP
                || keyCode == KeyEvent.KEYCODE_CHANNEL_UP
                || keyCode == KeyEvent.KEYCODE_PAGE_UP) {
            playPreviousChannel(true);
            return true;
        }
        if (keyCode == KeyEvent.KEYCODE_DPAD_DOWN
                || keyCode == KeyEvent.KEYCODE_CHANNEL_DOWN
                || keyCode == KeyEvent.KEYCODE_PAGE_DOWN) {
            playNextChannel(true);
            return true;
        }
        if (keyCode == KeyEvent.KEYCODE_SPACE) {
            if (player != null) {
                if (player.isPlaying()) {
                    player.pause();
                } else {
                    player.play();
                }
                return true;
            }
        }
        return super.onKeyDown(keyCode, event);
    }

    @Override
    protected void onStart() {
        super.onStart();
        if (player != null) {
            player.setPlayWhenReady(true);
        }
    }

    @Override
    protected void onStop() {
        cancelStallCheck();
        cancelSilentAudioCheck();
                if (player != null) {
            player.setPlayWhenReady(false);
        }
        super.onStop();
    }

    @Override
    protected void onDestroy() {
        cancelStallCheck();
        cancelSilentAudioCheck();
        if (hideIndicatorRunnable != null) {
            mainHandler.removeCallbacks(hideIndicatorRunnable);
        }
        if (hideChannelLabelRunnable != null) {
            mainHandler.removeCallbacks(hideChannelLabelRunnable);
        }
        if (hideGestureHintRunnable != null) {
            mainHandler.removeCallbacks(hideGestureHintRunnable);
        }
        if (player != null) {
            player.release();
            player = null;
        }
        netPool.shutdownNow();
        super.onDestroy();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            hideSystemUI();
        }
    }

    private void hideSystemUI() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            getWindow().setDecorFitsSystemWindows(false);
            getWindow().getInsetsController().hide(
                    android.view.WindowInsets.Type.statusBars()
                            | android.view.WindowInsets.Type.navigationBars());
            getWindow().getInsetsController().setSystemBarsBehavior(
                    android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        } else {
            View decor = getWindow().getDecorView();
            decor.setSystemUiVisibility(
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                            | View.SYSTEM_UI_FLAG_FULLSCREEN
                            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                            | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                            | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                            | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
        }
    }

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

    private String fusionModeLabel(String mode) {
        if (mode == null) mode = "smart";
        switch (mode) {
            case "off": return "关闭融合";
            case "fast": return "快速";
            case "balanced": return "平衡";
            case "complete": return "完整";
            case "smart":
            default: return "智能";
        }
    }

    private void showFusionModeDialog(Button fusionButton) {
        final String[] modes = {"off", "fast", "balanced", "complete", "smart"};
        final String[] labels = {
                "关闭融合 — 仅当前/单一源",
                "快速 — 顺序取首个可用源",
                "平衡 — 融合前 3 个源",
                "完整 — 融合全部源",
                "智能 — 先出画再后台全量合并（推荐）"
        };
        int checked = 4;
        for (int i = 0; i < modes.length; i++) {
            if (modes[i].equals(fusionMode)) {
                checked = i;
                break;
            }
        }
        new AlertDialog.Builder(this)
                .setTitle("融合模式")
                .setSingleChoiceItems(labels, checked, (d, which) -> {
                    fusionMode = modes[which];
                    storage.saveFusionMode(fusionMode);
                    if (fusionButton != null) {
                        fusionButton.setText("融合模式: " + fusionModeLabel(fusionMode));
                    }
                    d.dismiss();
                    showIndicator("已切换到" + fusionModeLabel(fusionMode) + "模式");
                    loading = false;
                    channels.clear();
                    if (adapter != null) adapter.setData(channels);
                    loadChannels(false);
                })
                .setNegativeButton("取消", null)
                .show();
    }

    /** 按融合模式决定要拉取的内置源数量 */
    private int fusionSourceLimit() {
        switch (fusionMode == null ? "smart" : fusionMode) {
            case "off":
            case "fast":
                return 1;
            case "balanced":
                return 3;
            case "complete":
            case "smart":
            default:
                return MULTI_SOURCE_URLS.length;
        }
    }

    /**
     * 从多个源加载并合并频道（受 fusionMode 控制，对齐 iOS）
     */
    /** 构建本轮要拉的逻辑源（未展开镜像）：用户源优先，再补预置源 */
    private List<String> buildFusionFetchUrls(String mode, int limit) {
        LinkedHashSet<String> ordered = new LinkedHashSet<>();
        if (activeSourceUrl != null && !activeSourceUrl.trim().isEmpty()) {
            ordered.add(activeSourceUrl.trim());
        }
        if (sourceUrls != null) {
            for (String u : sourceUrls) {
                if (u != null && !u.trim().isEmpty()) {
                    ordered.add(u.trim());
                }
            }
        }
        int built = ordered.isEmpty() ? 0 : 1;
        for (String sourceUrl : MULTI_SOURCE_URLS) {
            if (built >= limit) break;
            if (ordered.add(sourceUrl)) {
                built++;
            }
        }
        if (ordered.isEmpty()) {
            ordered.add(DEFAULT_SOURCE_URL);
        }
        // 截到 limit 个逻辑源
        List<String> list = new ArrayList<>();
        for (String u : ordered) {
            if (list.size() >= limit) break;
            list.add(u);
        }
        return list;
    }

    /** 拉取单一逻辑源（内部镜像竞速）并解析频道 */
    private List<Channel> fetchOneSource(String logicalUrl) {
        try {
            String body = httpGetWithMirrors(logicalUrl);
            if (body == null || body.isEmpty()) {
                return new ArrayList<>();
            }
            return M3UParser.parse(body);
        } catch (Exception e) {
            return new ArrayList<>();
        }
    }

    /**
     * 从多个源加载并合并频道（受 fusionMode 控制，对齐 iOS）
     */
    private void loadChannelsFromMultiSources() {
        final String mode = fusionMode == null ? "smart" : fusionMode;
        final int limit = Math.max(1, Math.min(fusionSourceLimit(), MULTI_SOURCE_URLS.length));
        loadGeneration++;
        final int gen = loadGeneration;

        if ("off".equals(mode)) {
            showIndicator("关闭融合：加载单一源...");
            status.setText("加载中...");
            netPool.execute(() -> {
                List<Channel> parsed = new ArrayList<>();
                String url = (activeSourceUrl != null && !activeSourceUrl.trim().isEmpty())
                        ? activeSourceUrl.trim()
                        : (sourceUrls.isEmpty() ? DEFAULT_SOURCE_URL : sourceUrls.get(0));
                if (url == null || url.isEmpty()) {
                    url = DEFAULT_SOURCE_URL;
                }
                parsed = fetchOneSource(url);
                if (parsed.isEmpty()) {
                    for (String u : MULTI_SOURCE_URLS) {
                        if (u.equals(url)) continue;
                        parsed = fetchOneSource(u);
                        if (!parsed.isEmpty()) break;
                    }
                }
                final List<Channel> result = parsed;
                mainHandler.post(() -> {
                    if (gen != loadGeneration) return;
                    applyLoadedChannels(result, result.isEmpty() ? 0 : 1, 1, false);
                });
            });
            return;
        }

        if ("fast".equals(mode)) {
            showIndicator("快速模式：加载可用源...");
            status.setText("加载中...");
            netPool.execute(() -> {
                List<Channel> raced = fetchChannels();
                mainHandler.post(() -> {
                    if (gen != loadGeneration) return;
                    applyLoadedChannels(raced, raced.isEmpty() ? 0 : 1, 1, false);
                });
            });
            return;
        }

        showIndicator("正在加载多个直播源...");
        status.setText("加载中，请稍候...");

        netPool.execute(() -> {
            List<Channel> allChannels = new ArrayList<>();
            // 按 key 聚合线路，禁止「首 URL 丢整台」
            java.util.Map<String, Channel> byKey = new java.util.LinkedHashMap<>();

            List<String> fetchUrls = buildFusionFetchUrls(mode, limit);
            int successCount = 0;
            int totalSources = Math.max(1, fetchUrls.size());
            boolean firstBatchPosted = false;
            int attempt = 0;

            for (String fullUrl : fetchUrls) {
                if (gen != loadGeneration) return;
                attempt++;
                final int index = attempt;
                mainHandler.post(() ->
                        showIndicator(String.format("加载源 %d · %s", index, fusionModeLabel(mode)))
                );

                List<Channel> sourceChannels = fetchOneSource(fullUrl);
                if (sourceChannels.isEmpty()) {
                    continue;
                }
                successCount++;
                for (Channel channel : sourceChannels) {
                    if (channel.getUrls().isEmpty()) continue;
                    String k = channel.key != null && !channel.key.isEmpty()
                            ? channel.key
                            : channel.name.trim().toLowerCase();
                    if (byKey.containsKey(k)) {
                        Channel existing = byKey.get(k);
                        for (String u : channel.getUrls()) {
                            if (isQualityUrl(u)) {
                                existing.addUrl(u);
                            }
                        }
                    } else {
                        Channel copy = new Channel(channel.name, channel.group, channel.key, null);
                        for (String u : channel.getUrls()) {
                            if (isQualityUrl(u)) {
                                copy.addUrl(u);
                            }
                        }
                        if (copy.getSourceCount() > 0) {
                            byKey.put(k, copy);
                        }
                    }
                }
                allChannels = new ArrayList<>(byKey.values());

                if ("smart".equals(mode) && !firstBatchPosted && !allChannels.isEmpty()) {
                    firstBatchPosted = true;
                    final List<Channel> firstBatch = mergeChannelsByName(new ArrayList<>(allChannels));
                    final int sc = successCount;
                    mainHandler.post(() -> {
                        if (gen != loadGeneration) return;
                        applyLoadedChannels(firstBatch, sc, totalSources, true);
                    });
                }
            }

            List<Channel> mergedChannels = mergeChannelsByName(new ArrayList<>(byKey.values()));
            final int finalSuccessCount = successCount;
            mainHandler.post(() -> {
                if (gen != loadGeneration) return;
                applyLoadedChannels(mergedChannels, finalSuccessCount, totalSources, false);
            });
        });
    }

    /**
     * @param softMerge true=首批/后台增量，已在播则尽量不打断
     */
    private void applyLoadedChannels(List<Channel> loaded, int successCount, int totalSources, boolean softMerge) {
        // softMerge=首批：保持 loading=true 让后台可继续；最终批 softMerge=false 时清掉
        if (!softMerge) {
            loading = false;
        }
        if (loaded == null || loaded.isEmpty()) {
            if (channels.isEmpty()) {
                status.setText("加载失败，请检查网络");
                showIndicator("所有源均加载失败");
            }
            return;
        }

        String prevKey = (!channels.isEmpty() && currentIndex >= 0 && currentIndex < channels.size())
                ? channels.get(currentIndex).key : null;
        String prevUrl = null;
        if (prevKey != null && currentSourceIndex >= 0
                && currentSourceIndex < channels.get(currentIndex).getSourceCount()) {
            prevUrl = channels.get(currentIndex).getUrls().get(currentSourceIndex);
        }
        // 已有列表或正在起播：软合并不重播，避免 smart 首批打断缓存播放
        boolean keepPlayback = currentPlaybackReachedReady
                || waitingForReady
                || (player != null && player.isPlaying())
                || (softMerge && !channels.isEmpty());
        boolean wasPlaying = keepPlayback;

        channels.clear();
        channels.addAll(applyChannelLineRules(loaded));
        reputation.applyToChannels(channels);
        adapter.setData(channels);
        if (!softMerge) {
            storage.saveChannels(channels);
        }

        int totalLines = 0;
        for (Channel c : channels) {
            totalLines += c.getSourceCount();
        }
        status.setText(String.format(
                "%s：%d 台 / %d 线（%d/%d 源）",
                fusionModeLabel(fusionMode),
                channels.size(), totalLines, successCount, totalSources
        ));
        if (!softMerge) {
            showIndicator(String.format("%d 台 · %d 线", channels.size(), totalLines));
        }

        if (prevKey != null) {
            for (int i = 0; i < channels.size(); i++) {
                if (prevKey.equals(channels.get(i).key)) {
                    currentIndex = i;
                    if (prevUrl != null) {
                        int li = channels.get(i).getUrls().indexOf(prevUrl);
                        currentSourceIndex = li >= 0 ? li : 0;
                    } else {
                        currentSourceIndex = Math.min(currentSourceIndex,
                                Math.max(0, channels.get(i).getSourceCount() - 1));
                    }
                    break;
                }
            }
        }
        if (prevKey == null) {
            restoreLastChannelPosition();
        } else if (currentIndex >= channels.size()) {
            currentIndex = 0;
            currentSourceIndex = 0;
        }
        if (!wasPlaying) {
            playCurrent(false, CHANNEL_SWITCH_TIMEOUT_MS);
        }
        if (!softMerge) {
            loading = false;
        }
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
        java.util.Map<String, Channel> mergedMap = new java.util.LinkedHashMap<>();

        for (Channel channel : channels) {
            String key = channel.key != null && !channel.key.isEmpty()
                    ? channel.key
                    : channel.name.trim().toLowerCase();

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
            android.view.WindowInsetsController controller = window.getInsetsController();
            if (controller != null) {
                controller.hide(android.view.WindowInsets.Type.statusBars() | android.view.WindowInsets.Type.navigationBars());
                controller.setSystemBarsBehavior(
                    android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
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
            android.view.WindowInsetsController controller = window.getInsetsController();
            if (controller != null) {
                controller.hide(android.view.WindowInsets.Type.statusBars() | android.view.WindowInsets.Type.navigationBars());
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
    protected void onResume() {
        super.onResume();
        applyImmersiveMode();
    }
}
