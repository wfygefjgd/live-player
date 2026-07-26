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

    // 多源配置：6个优质源自动拼接
    private static final String[] MULTI_SOURCE_URLS = {
            "best-fan/iptv-sources/master/cn_all_status.m3u8",
            "fanmingming/live/main/tv/m3u/ipv6.m3u",
            "YueChan/Live/main/IPTV.m3u",
            "Supprise0901/TVBox_live/main/live.txt",
            "vbskycn/iptv/master/tv/tv.m3u",
            "YanG-1989/m3u/main/Gather.m3u"
    };

    // 镜像加速前缀
    private static final String[] MIRROR_PREFIXES = {
            "https://ghfast.top/raw.githubusercontent.com/",
            "https://raw.gitmirror.com/",
            "https://raw.kkgithub.com/",
            "https://gcore.jsdelivr.net/gh/"
    };

    private static final long CHANNEL_OSD_MS = 2500L;
    private static final long CHANNEL_SWITCH_TIMEOUT_MS = 5000L;      // 5秒起播：给弱网出画机会
    private static final long STALL_TIMEOUT_MS = 4500L;               // 4.5秒持续卡顿才切
    private static final long FAST_FAIL_TIMEOUT_MS = 3500L;           // 自动换线后稍短超时
    private static final long NETWORK_WAIT_RETRY_MS = 500L;
    private static final long FLOAT_BUTTONS_TIMEOUT_MS = 2500L;
    private static final long SILENT_AUDIO_CHECK_MS = 5000L;          // 出画后再检测无声
    private static final long READY_PROTECT_MS = 2500L;               // 刚就绪保护期，避免误切
    private static final int AUTO_RECOVER_MAX_CHANNELS = 25;

    private PlayerView playerView;
    private ExoPlayer player;
    private View leftPanel;
    private Button btnTogglePanel;
    private Button btnLock;
    private TextView status;
    private TextView channelLabel;
    private TextView indicator;
    private RecyclerView channelList;

    private final List<Channel> channels = new ArrayList<>();
    private final List<String> sourceUrls = new ArrayList<>();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ExecutorService netPool = Executors.newFixedThreadPool(2);

    private ChannelAdapter adapter;
    private AudioManager audioManager;
    private StorageHelper storage;
    private GestureDetector gestureDetector;
    private Runnable hideIndicatorRunnable;
    private Runnable hideChannelLabelRunnable;
    private Runnable stallRunnable;
    private Runnable silentAudioRunnable;
    private Runnable hideFloatingButtonsRunnable;

    private int currentIndex = 0;
    private int currentSourceIndex = 0;
    private boolean panelVisible = false;
    private boolean locked = false;
    private boolean loading = false;
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
        btnTogglePanel = findViewById(R.id.btn_toggle_panel);
        btnLock = findViewById(R.id.btn_lock);
        status = findViewById(R.id.status);
        channelLabel = findViewById(R.id.channel_label);
        indicator = findViewById(R.id.indicator);
        channelList = findViewById(R.id.channel_list);

        playerView.setUseController(false);
        playerView.setKeepContentOnPlayerReset(true);
        channelLabel.setVisibility(View.GONE);
        status.setVisibility(View.VISIBLE);
        setFloatingButtonsVisible(true);
        leftPanel.setVisibility(View.GONE);
        btnTogglePanel.setText("▶");
    }

    private void setupPlayer() {
        player = new ExoPlayer.Builder(this).build();
        playerView.setPlayer(player);
        player.addListener(new Player.Listener() {
            @Override
            public void onPlaybackStateChanged(int state) {
                if (state == Player.STATE_READY) {
                    // 仅在真正可播时确认就绪；避免假 READY
                    boolean reallyPlaying = player != null
                            && (player.isPlaying() || player.getPlayWhenReady());
                    waitingForReady = false;
                    autoSwitchingSource = false;
                    currentPlaybackReachedReady = true;
                    readyAtMs = System.currentTimeMillis();
                    consecutiveBufferEvents = 0;
                    autoRecoverChannelHops = 0;
                    cancelStallCheck();
                    if (reallyPlaying) {
                        scheduleSilentAudioCheck();
                        scheduleHideFloatingButtons();
                        // 真实起播成功 → 延迟写入信誉（与 iOS 一致）
                        scheduleRememberPreferredLine();
                    } else {
                        // READY 但未真正播放：保留卡顿检测兜底
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
        adapter.setOnChannelClick(position -> {
            if (locked) {
                return;
            }
            currentIndex = position;
            currentSourceIndex = 0;
            resetTriedLines();
            autoRecoverChannelHops = 0;
            playCurrent(true);
        });
    }

    private void setupButtons() {
        btnTogglePanel.setOnClickListener(v -> {
            if (!locked) {
                togglePanel();
            }
        });
        btnTogglePanel.setOnLongClickListener(v -> {
            if (!locked) {
                showSourceInputDialog();
            }
            return true;
        });
        btnLock.setOnClickListener(v -> toggleLock());
        btnLock.setOnLongClickListener(v -> {
            if (!channels.isEmpty()) {
                confirmDeleteCurrentLine();
            }
            return true;
        });
    }

    private void setupGestures() {
        gestureDetector = new GestureDetector(this, new GestureDetector.SimpleOnGestureListener() {
            private static final int SWIPE_MIN = 80;
            private static final int SWIPE_VEL = 100;

            @Override
            public boolean onDown(MotionEvent e) {
                return true;
            }

            @Override
            public boolean onFling(MotionEvent e1, MotionEvent e2, float velocityX, float velocityY) {
                if (locked || e1 == null || e2 == null) {
                    return false;
                }
                float dx = e2.getX() - e1.getX();
                float dy = e2.getY() - e1.getY();
                if (Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > SWIPE_MIN && Math.abs(velocityX) > SWIPE_VEL) {
                    if (dx > 0) {
                        switchSource(-1, true);
                    } else {
                        switchSource(1, true);
                    }
                    return true;
                }
                return false;
            }

            @Override
            public boolean onScroll(MotionEvent e1, MotionEvent e2, float distanceX, float distanceY) {
                if (locked || e1 == null || e2 == null) {
                    return false;
                }
                float dx = Math.abs(e2.getX() - e1.getX());
                float dy = e1.getY() - e2.getY();
                if (dx > Math.abs(dy) || Math.abs(dy) < 8) {
                    return false;
                }
                int width = playerView.getWidth() > 0 ? playerView.getWidth() : getResources().getDisplayMetrics().widthPixels;
                if (e1.getX() < width * 0.35f) {
                    adjustBrightness(dy > 0 ? 0.03f : -0.03f);
                    return true;
                }
                if (e1.getX() > width * 0.65f) {
                    adjustVolume(dy > 0 ? 1 : -1);
                    return true;
                }
                return false;
            }

            @Override
            public boolean onSingleTapConfirmed(MotionEvent e) {
                if (locked) {
                    showFloatingButtonsTemporarily();
                    return true;
                }
                showFloatingButtonsTemporarily();
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
            public void onLongPress(MotionEvent e) {
                if (locked) {
                    showFloatingButtonsTemporarily();
                    return;
                }
                // 长按打开/关闭左侧频道栏（与 iOS 对齐）
                if (!panelVisible) {
                    togglePanel();
                }
                showFloatingButtonsTemporarily();
            }
        });

        View.OnTouchListener touchListener = (v, event) -> {
            if (panelVisible && isTouchOnPanel(event)) {
                return false;
            }
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
        panelVisible = !panelVisible;
        leftPanel.setVisibility(panelVisible ? View.VISIBLE : View.GONE);
        // 面板打开时抬到最前，避免被 PlayerView 或其它层遮挡
        if (panelVisible && leftPanel != null) {
            leftPanel.bringToFront();
            if (btnTogglePanel != null) {
                btnTogglePanel.bringToFront();
            }
            if (btnLock != null) {
                btnLock.bringToFront();
            }
        }
        btnTogglePanel.setText(panelVisible ? "◀" : "▶");
        showFloatingButtonsTemporarily();
    }

    private void toggleLock() {
        locked = !locked;
        btnLock.setText(locked ? "🔒" : "🔓");
        if (locked) {
            leftPanel.setVisibility(View.GONE);
            setFloatingButtonsVisible(true);
            btnTogglePanel.setVisibility(View.GONE);
        } else {
            leftPanel.setVisibility(panelVisible ? View.VISIBLE : View.GONE);
            showFloatingButtonsTemporarily();
        }
    }

    private void setFloatingButtonsVisible(boolean visible) {
        float alpha = visible ? 1f : 0f;
        int visibility = visible ? View.VISIBLE : View.GONE;
        btnLock.setAlpha(alpha);
        btnLock.setVisibility(visibility);
        btnTogglePanel.setAlpha(alpha);
        btnTogglePanel.setVisibility(locked ? View.GONE : visibility);
    }

    private void showFloatingButtonsTemporarily() {
        cancelHideFloatingButtons();
        setFloatingButtonsVisible(true);
        scheduleHideFloatingButtons();
    }

    private void scheduleHideFloatingButtons() {
        cancelHideFloatingButtons();
        if (player == null || player.getPlaybackState() != Player.STATE_READY) {
            return;
        }
        hideFloatingButtonsRunnable = () -> setFloatingButtonsVisible(false);
        mainHandler.postDelayed(hideFloatingButtonsRunnable, FLOAT_BUTTONS_TIMEOUT_MS);
    }

    private void cancelHideFloatingButtons() {
        if (hideFloatingButtonsRunnable != null) {
            mainHandler.removeCallbacks(hideFloatingButtonsRunnable);
            hideFloatingButtonsRunnable = null;
        }
    }

    private void confirmDeleteCurrentLine() {
        if (channels.isEmpty() || currentIndex < 0 || currentIndex >= channels.size()) {
            return;
        }
        Channel channel = channels.get(currentIndex);
        if (channel.getSourceCount() == 0 || currentSourceIndex < 0 || currentSourceIndex >= channel.getSourceCount()) {
            return;
        }
        String lineLabel = channel.name + " 线路 " + (currentSourceIndex + 1);
        new AlertDialog.Builder(this)
                .setTitle("删除当前线路")
                .setMessage("确认删除 " + lineLabel + " 并自动跳到下一线路吗？")
                .setPositiveButton("删除", (dialog, which) -> deleteCurrentLineAndJump())
                .setNegativeButton("取消", null)
                .show();
    }

    private void deleteCurrentLineAndJump() {
        if (channels.isEmpty() || currentIndex < 0 || currentIndex >= channels.size()) {
            return;
        }
        Channel channel = channels.get(currentIndex);
        List<String> urls = channel.getUrls();
        if (urls.isEmpty() || currentSourceIndex < 0 || currentSourceIndex >= urls.size()) {
            return;
        }
        String currentUrl = urls.get(currentSourceIndex);
        storage.hideLine(currentUrl);

        int nextIndex = urls.size() <= 1 ? -1 : currentSourceIndex;
        channels.clear();
        channels.addAll(applyChannelLineRules(fetchChannels()));
        adapter.setData(channels);

        if (channels.isEmpty()) {
            showIndicator("线路已删除");
            return;
        }

        if (currentIndex >= channels.size()) {
            currentIndex = channels.size() - 1;
        }
        Channel updated = channels.get(currentIndex);
        if (updated.getSourceCount() <= 0) {
            playNextChannel(true);
            return;
        }
        if (nextIndex < 0) {
            currentSourceIndex = 0;
        } else if (nextIndex >= updated.getSourceCount()) {
            currentSourceIndex = 0;
        } else {
            currentSourceIndex = nextIndex;
        }
        showIndicator("已删除当前线路");
        playCurrent(true, STALL_TIMEOUT_MS);
    }

    private void loadChannels() {
        if (loading) {
            return;
        }
        loading = true;
        waitingForReady = false;
        cancelStallCheck();

        // ① 缓存立刻出画（信誉排序跳过已知坏线）
        // ② 后台静默刷新多源，不打断已稳定播放
        List<Channel> cached = storage.loadChannels();
        final boolean hasCache = cached != null && !cached.isEmpty();
        if (hasCache) {
            channels.clear();
            channels.addAll(cached);
            reputation.applyToChannels(channels);
            adapter.setData(channels);
            status.setText(String.format("已加载 %d 个频道（缓存）", channels.size()));
            playCurrent(false, CHANNEL_SWITCH_TIMEOUT_MS);
        }

        // 后台刷新多源
        loadChannelsFromMultiSources();
    }

    private List<Channel> fetchChannels() {
        for (String url : buildSourceCandidates()) {
            try {
                String body = httpGet(url);
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

    private List<String> buildSourceCandidates() {
        List<String> urls = new ArrayList<>();
        if (!activeSourceUrl.isEmpty()) {
            urls.add(activeSourceUrl);
        }
        // 如果activeSourceUrl为空或加载失败，尝试所有镜像源
        for (String sourceUrl : MULTI_SOURCE_URLS) {
            for (String prefix : MIRROR_PREFIXES) {
                String fullUrl = prefix + sourceUrl;
                if (!urls.contains(fullUrl)) {
                    urls.add(fullUrl);
                }
            }
        }
        return urls;
    }

    private void showSourceInputDialog() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(16);
        root.setPadding(pad, pad, pad, pad);

        EditText input = new EditText(this);
        input.setSingleLine(true);
        input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        input.setHint("输入新的 m3u 或 m3u8 地址");
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
        actions.addView(addButton, new LinearLayout.LayoutParams(
                0,
                LinearLayout.LayoutParams.WRAP_CONTENT,
                1f));

        Button deleteButton = new Button(this);
        deleteButton.setText("删除");
        actions.addView(deleteButton, new LinearLayout.LayoutParams(
                0,
                LinearLayout.LayoutParams.WRAP_CONTENT,
                1f));

        ListView listView = new ListView(this);
        LinearLayout.LayoutParams listParams = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(260));
        root.addView(listView, listParams);

        List<String> dialogSources = new ArrayList<>(sourceUrls);
        ArrayAdapter<String> adapter = new ArrayAdapter<>(this, android.R.layout.simple_list_item_single_choice, dialogSources);
        listView.setChoiceMode(ListView.CHOICE_MODE_SINGLE);
        listView.setAdapter(adapter);
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

        addButton.setOnClickListener(v -> {
            String url = input.getText().toString().trim();
            if (url.isEmpty()) {
                showIndicator("源地址不能为空");
                return;
            }
            if (!dialogSources.contains(url)) {
                dialogSources.add(url);
                sourceUrls.clear();
                sourceUrls.addAll(dialogSources);
                persistSourceState();
                adapter.notifyDataSetChanged();
            }
            int idx = dialogSources.indexOf(url);
            if (idx >= 0) {
                selectedIndex[0] = idx;
                listView.setItemChecked(idx, true);
            }
            input.setText("");
            selectSource(url);
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
                adapter.notifyDataSetChanged();
                dialog.dismiss();
                reloadActiveSource();
                return;
            }
            persistSourceState();
            adapter.notifyDataSetChanged();
            selectedIndex[0] = dialogSources.indexOf(activeSourceUrl);
            listView.clearChoices();
            if (selectedIndex[0] >= 0) {
                listView.setItemChecked(selectedIndex[0], true);
            }
        });

        listView.setOnItemClickListener((parent, view, position, id) -> {
            selectedIndex[0] = position;
            String selectedUrl = dialogSources.get(position);
            selectSource(selectedUrl);
            dialog.dismiss();
        });

        dialog.show();
        input.requestFocus();
        input.post(() -> {
            InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
            if (imm != null) {
                imm.showSoftInput(input, InputMethodManager.SHOW_IMPLICIT);
            }
        });
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
        if (player != null) {
            player.stop();
            player.clearMediaItems();
        }
        status.setText("正在切换源...");
        setFloatingButtonsVisible(true);
        loadChannels();
    }

    private void restoreSourceState() {
        LinkedHashSet<String> urls = new LinkedHashSet<>();
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
            activeSourceUrl = "";
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
        conn.setConnectTimeout(8000);
        conn.setReadTimeout(10000);
        conn.setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android 10)");
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
            switchToNextPlayableSource("当前线路无声音", true, true);
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
            if (panelVisible && !locked && showOsd) {
                mainHandler.postDelayed(() -> {
                    if (panelVisible && !locked) {
                        togglePanel();
                    }
                }, 300);
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
        if (channels.isEmpty() || locked) {
            return;
        }
        currentIndex = (currentIndex + 1) % channels.size();
        currentSourceIndex = 0;
        resetTriedLines();
        autoRecoverChannelHops = 0;
        playCurrent(showOsd, CHANNEL_SWITCH_TIMEOUT_MS);
    }

    private void playPreviousChannel(boolean showOsd) {
        if (channels.isEmpty() || locked) {
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
        if (locked) {
            showIndicator(hint + " · 已锁定，无法自动换台");
            return;
        }
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
        return player != null && player.getCurrentTracks().isTypeSelected(C.TRACK_TYPE_AUDIO);
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

    private boolean shouldSkipChannelLine(String key, int index, String url) {
        if ("cctv10".equals(key)) {
            return index == 0;
        }
        if ("cctv14".equals(key)) {
            return index == 0;
        }
        if ("cctv13".equals(key)) {
            return index >= 0 && index <= 2;
        }
        if ("北京".equals(key)) {
            return index == 0;
        }
        if ("湖南".equals(key)) {
            return index >= 0 && index <= 1;
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

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (locked && keyCode != KeyEvent.KEYCODE_DPAD_CENTER && keyCode != KeyEvent.KEYCODE_ENTER) {
            return super.onKeyDown(keyCode, event);
        }
        if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT) {
            switchSource(-1, true);
            return true;
        }
        if (keyCode == KeyEvent.KEYCODE_DPAD_RIGHT) {
            switchSource(1, true);
            return true;
        }
        if (keyCode == KeyEvent.KEYCODE_DPAD_UP) {
            playPreviousChannel(true);
            return true;
        }
        if (keyCode == KeyEvent.KEYCODE_DPAD_DOWN) {
            playNextChannel(true);
            return true;
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
        cancelHideFloatingButtons();
        if (player != null) {
            player.setPlayWhenReady(false);
        }
        super.onStop();
    }

    @Override
    protected void onDestroy() {
        cancelStallCheck();
        cancelSilentAudioCheck();
        cancelHideFloatingButtons();
        if (hideIndicatorRunnable != null) {
            mainHandler.removeCallbacks(hideIndicatorRunnable);
        }
        if (hideChannelLabelRunnable != null) {
            mainHandler.removeCallbacks(hideChannelLabelRunnable);
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

    /**
     * 从多个源加载并合并频道
     */
    private void loadChannelsFromMultiSources() {
        showIndicator("正在加载多个直播源...");
        status.setText("加载中，请稍候...");

        netPool.execute(() -> {
            List<Channel> allChannels = new ArrayList<>();
            LinkedHashSet<String> seenUrls = new LinkedHashSet<>();

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

                            StringBuilder sb = new StringBuilder();
                            String line;
                            while ((line = reader.readLine()) != null) {
                                sb.append(line).append("\n");
                            }

                            List<Channel> sourceChannels = M3UParser.parse(sb.toString());

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
                loading = false;
                if (mergedChannels.isEmpty()) {
                    status.setText("加载失败，请检查网络");
                    showIndicator("所有源均加载失败");
                } else {
                    String prevKey = (!channels.isEmpty() && currentIndex >= 0 && currentIndex < channels.size())
                            ? channels.get(currentIndex).key : null;
                    String prevUrl = null;
                    if (prevKey != null && currentSourceIndex >= 0
                            && currentSourceIndex < channels.get(currentIndex).getSourceCount()) {
                        prevUrl = channels.get(currentIndex).getUrls().get(currentSourceIndex);
                    }
                    boolean wasPlaying = currentPlaybackReachedReady
                            && player != null && player.isPlaying();

                    channels.clear();
                    channels.addAll(applyChannelLineRules(mergedChannels));
                    reputation.applyToChannels(channels);
                    adapter.setData(channels);
                    storage.saveChannels(channels);

                    status.setText(String.format(
                        "加载成功：%d 个频道（来自 %d/%d 个源）",
                        channels.size(), finalSuccessCount, totalSources
                    ));

                    // 软合并：尽量回到刚才的台/线
                    if (prevKey != null) {
                        for (int i = 0; i < channels.size(); i++) {
                            if (prevKey.equals(channels.get(i).key)) {
                                currentIndex = i;
                                if (prevUrl != null) {
                                    int li = channels.get(i).getUrls().indexOf(prevUrl);
                                    currentSourceIndex = li >= 0 ? li : 0;
                                } else {
                                    currentSourceIndex = 0;
                                }
                                break;
                            }
                        }
                    }
                    if (currentIndex >= channels.size()) {
                        currentIndex = 0;
                        currentSourceIndex = 0;
                    }
                    // 已在稳定播放则不重播；否则开播
                    if (!wasPlaying) {
                        playCurrent(false, CHANNEL_SWITCH_TIMEOUT_MS);
                    }
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
        java.util.Map<String, Channel> mergedMap = new java.util.LinkedHashMap<>();

        for (Channel channel : channels) {
            String key = channel.name.trim().toLowerCase();

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
