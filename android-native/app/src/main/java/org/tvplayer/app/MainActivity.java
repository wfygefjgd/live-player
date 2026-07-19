package org.tvplayer.app;

import android.content.Context;
import android.content.pm.ActivityInfo;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.GestureDetector;
import android.view.MotionEvent;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

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
import java.util.List;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class MainActivity extends AppCompatActivity {

    private static final String[][] SOURCES = {
            {"best-fan", "https://raw.githubusercontent.com/best-fan/iptv-sources/main/cn_all.m3u8"},
            {"TVBox", "https://ghfast.top/raw.githubusercontent.com/Supprise0901/TVBox_live/main/live.txt"},
            {"vbskycn", "https://raw.githubusercontent.com/vbskycn/iptv/master/tv/tv.m3u"},
            {"fanmingming", "https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u"},
    };

    private static final String[] MIRRORS = {
            "https://ghfast.top/raw.githubusercontent.com/",
            "https://raw.gitmirror.com/",
            "https://raw.kkgithub.com/",
    };

    private PlayerView playerView;
    private ExoPlayer player;
    private View leftPanel;
    private Button btnTogglePanel;
    private Button btnLock;
    private Button btnRefresh;
    private Button btnSource;
    private Button btnFav;
    private EditText search;
    private TextView status;
    private TextView channelLabel;
    private TextView indicator;
    private RecyclerView channelList;

    private ChannelAdapter adapter;
    private StorageHelper storage;
    private AudioManager audioManager;

    private final List<Channel> allChannels = new ArrayList<>();
    private final List<Channel> filtered = new ArrayList<>();
    private int currentIndex = 0;
    private int sourceIndex = 0;
    private boolean panelVisible = true;
    private boolean locked = false;
    private boolean showFavOnly = false;
    private boolean loading = false;
    private String currentUrl = null;

    private float brightness = 0.5f;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ExecutorService netPool = Executors.newFixedThreadPool(2);
    private GestureDetector gestureDetector;
    private Runnable hideIndicatorRunnable;

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
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

        storage = new StorageHelper(this);
        audioManager = (AudioManager) getSystemService(Context.AUDIO_SERVICE);

        bindViews();
        setupPlayer();
        setupList();
        setupGestures();
        setupButtons();
        loadBrightness();
        loadCacheOrRefresh();
    }

    private void bindViews() {
        playerView = findViewById(R.id.player_view);
        leftPanel = findViewById(R.id.left_panel);
        btnTogglePanel = findViewById(R.id.btn_toggle_panel);
        btnLock = findViewById(R.id.btn_lock);
        btnRefresh = findViewById(R.id.btn_refresh);
        btnSource = findViewById(R.id.btn_source);
        btnFav = findViewById(R.id.btn_fav);
        search = findViewById(R.id.search);
        status = findViewById(R.id.status);
        channelLabel = findViewById(R.id.channel_label);
        indicator = findViewById(R.id.indicator);
        channelList = findViewById(R.id.channel_list);

        playerView.setUseController(false);
        playerView.setKeepContentOnPlayerReset(true);
    }

    private void setupPlayer() {
        player = new ExoPlayer.Builder(this).build();
        playerView.setPlayer(player);
        player.addListener(new Player.Listener() {
            @Override
            public void onPlaybackStateChanged(int state) {
                // no-op
            }

            @Override
            public void onPlayerError(com.google.android.exoplayer2.PlaybackException error) {
                runOnUiThread(() -> Toast.makeText(MainActivity.this,
                        "播放出错: " + error.getLocalizedMessage(), Toast.LENGTH_SHORT).show());
            }
        });
    }

    private void setupList() {
        adapter = new ChannelAdapter();
        adapter.setStorage(storage);
        channelList.setLayoutManager(new LinearLayoutManager(this));
        channelList.setAdapter(adapter);
        adapter.setOnChannelClick(pos -> {
            if (locked) return;
            currentIndex = pos;
            playCurrent();
        });
        adapter.setOnChannelLongClick(pos -> {
            if (locked) return;
            Channel ch = adapter.getItem(pos);
            if (ch == null) return;
            storage.toggleFavorite(ch.url);
            adapter.notifyItemChanged(pos);
            Toast.makeText(this,
                    storage.isFavorite(ch.url) ? "已收藏" : "已取消收藏",
                    Toast.LENGTH_SHORT).show();
        });
        search.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int a, int b, int c) {}
            @Override public void onTextChanged(CharSequence s, int a, int b, int c) {
                applyFilter();
            }
            @Override public void afterTextChanged(Editable s) {}
        });
    }

    private void setupButtons() {
        btnTogglePanel.setOnClickListener(v -> {
            if (locked) return;
            togglePanel();
        });
        btnLock.setOnClickListener(v -> toggleLock());
        btnRefresh.setOnClickListener(v -> {
            if (locked) return;
            refreshFromNetwork(true);
        });
        btnSource.setOnClickListener(v -> {
            if (locked) return;
            switchSource();
        });
        btnFav.setOnClickListener(v -> {
            if (locked) return;
            showFavOnly = !showFavOnly;
            btnFav.setText(showFavOnly ? getString(R.string.all) : getString(R.string.favorites));
            applyFilter();
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
                if (locked || e1 == null || e2 == null) return false;
                float dx = e2.getX() - e1.getX();
                float dy = e2.getY() - e1.getY();
                if (Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > SWIPE_MIN && Math.abs(velocityX) > SWIPE_VEL) {
                    if (dx > 0) {
                        prevChannel();
                    } else {
                        nextChannel();
                    }
                    return true;
                }
                return false;
            }

            @Override
            public boolean onScroll(MotionEvent e1, MotionEvent e2, float distanceX, float distanceY) {
                if (locked || e1 == null || e2 == null) return false;
                float dx = Math.abs(e2.getX() - e1.getX());
                float dy = e1.getY() - e2.getY(); // up = positive
                if (dx > Math.abs(dy)) return false;
                if (Math.abs(dy) < 8) return false;

                float x = e1.getX();
                int w = playerView.getWidth();
                if (w <= 0) w = getResources().getDisplayMetrics().widthPixels;

                if (x < w * 0.35f) {
                    // left side: brightness
                    adjustBrightness(dy > 0 ? 0.03f : -0.03f);
                    return true;
                } else if (x > w * 0.65f) {
                    // right side: volume
                    adjustVolume(dy > 0 ? 1 : -1);
                    return true;
                }
                return false;
            }

            @Override
            public boolean onSingleTapConfirmed(MotionEvent e) {
                if (locked) return true;
                if (player != null) {
                    if (player.isPlaying()) {
                        player.pause();
                    } else {
                        player.play();
                    }
                }
                return true;
            }
        });

        View.OnTouchListener touchListener = (v, event) -> {
            if (panelVisible && isTouchOnPanel(event)) {
                return false;
            }
            // always allow lock button / toggle button
            return gestureDetector.onTouchEvent(event);
        };
        playerView.setOnTouchListener(touchListener);
        findViewById(R.id.root).setOnTouchListener(touchListener);
    }

    private boolean isTouchOnPanel(MotionEvent event) {
        if (leftPanel.getVisibility() != View.VISIBLE) return false;
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
        if (audioManager == null) return;
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

    private void togglePanel() {
        panelVisible = !panelVisible;
        leftPanel.setVisibility(panelVisible ? View.VISIBLE : View.GONE);
        btnTogglePanel.setText(panelVisible ? "◀" : "▶");
    }

    private void toggleLock() {
        locked = !locked;
        btnLock.setText(locked ? "🔒" : "🔓");
        if (locked) {
            leftPanel.setVisibility(View.GONE);
            btnTogglePanel.setVisibility(View.GONE);
        } else {
            btnTogglePanel.setVisibility(View.VISIBLE);
            leftPanel.setVisibility(panelVisible ? View.VISIBLE : View.GONE);
        }
    }

    private void loadCacheOrRefresh() {
        List<Channel> cached = storage.loadChannels();
        if (!cached.isEmpty()) {
            allChannels.clear();
            allChannels.addAll(cached);
            applyFilter();
            status.setText(allChannels.size() + " 个频道 (缓存)");
            if (!filtered.isEmpty()) {
                currentIndex = 0;
                playCurrent();
            }
        } else {
            refreshFromNetwork(true);
        }
    }

    private void refreshFromNetwork(boolean allSources) {
        if (loading) return;
        loading = true;
        status.setText(getString(R.string.loading));
        netPool.execute(() -> {
            List<Channel> loaded = new ArrayList<>();
            Set<String> seen = new HashSet<>();
            if (allSources) {
                for (String[] src : SOURCES) {
                    List<Channel> part = fetchOneSource(src[1]);
                    for (Channel c : part) {
                        if (seen.add(c.url)) {
                            loaded.add(c);
                        }
                    }
                }
            } else {
                String url = SOURCES[sourceIndex][1];
                List<Channel> part = fetchOneSource(url);
                for (Channel c : part) {
                    if (seen.add(c.url)) {
                        loaded.add(c);
                    }
                }
            }
            mainHandler.post(() -> {
                loading = false;
                if (!loaded.isEmpty()) {
                    allChannels.clear();
                    allChannels.addAll(loaded);
                    storage.saveChannels(allChannels);
                    applyFilter();
                    status.setText(allChannels.size() + " 个频道");
                    if (!filtered.isEmpty()) {
                        currentIndex = 0;
                        playCurrent();
                    }
                } else {
                    status.setText(getString(R.string.load_failed));
                }
            });
        });
    }

    private void switchSource() {
        sourceIndex = (sourceIndex + 1) % SOURCES.length;
        status.setText("切换 " + SOURCES[sourceIndex][0] + "...");
        refreshFromNetwork(false);
    }

    private List<Channel> fetchOneSource(String url) {
        List<String> candidates = new ArrayList<>();
        candidates.add(url);
        if (url.contains("raw.githubusercontent.com")) {
            for (String prefix : MIRRORS) {
                candidates.add(url.replace("https://raw.githubusercontent.com/", prefix));
            }
        }
        for (String u : candidates) {
            try {
                String body = httpGet(u);
                if (body != null && !body.isEmpty()) {
                    List<Channel> list = M3UParser.parse(body);
                    if (!list.isEmpty()) {
                        return list;
                    }
                }
            } catch (Exception ignored) {
            }
        }
        return new ArrayList<>();
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

    private void applyFilter() {
        String kw = search.getText() != null ? search.getText().toString().trim().toLowerCase() : "";
        filtered.clear();
        for (Channel ch : allChannels) {
            if (storage.isHidden(ch.url)) continue;
            if (showFavOnly && !storage.isFavorite(ch.url)) continue;
            if (!kw.isEmpty() && !ch.name.toLowerCase().contains(kw)) continue;
            filtered.add(ch);
        }
        adapter.setData(filtered);
        if (currentIndex >= filtered.size()) {
            currentIndex = 0;
        }
        adapter.setSelected(currentIndex);
    }

    private void nextChannel() {
        if (filtered.isEmpty()) return;
        currentIndex = (currentIndex + 1) % filtered.size();
        playCurrent();
    }

    private void prevChannel() {
        if (filtered.isEmpty()) return;
        currentIndex = (currentIndex - 1 + filtered.size()) % filtered.size();
        playCurrent();
    }

    private void playCurrent() {
        if (filtered.isEmpty() || currentIndex < 0 || currentIndex >= filtered.size()) {
            return;
        }
        Channel ch = filtered.get(currentIndex);
        adapter.setSelected(currentIndex);
        channelLabel.setText((currentIndex + 1) + "/" + filtered.size() + " " + ch.name);
        channelList.scrollToPosition(currentIndex);

        if (ch.url.equals(currentUrl)) {
            return;
        }
        currentUrl = ch.url;
        try {
            MediaItem item = MediaItem.fromUri(Uri.parse(ch.url));
            player.setMediaItem(item);
            player.prepare();
            player.play();
        } catch (Exception e) {
            Toast.makeText(this, "播放失败: " + ch.name, Toast.LENGTH_SHORT).show();
        }
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
        if (player != null) {
            player.setPlayWhenReady(false);
        }
        super.onStop();
    }

    @Override
    protected void onDestroy() {
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
}
