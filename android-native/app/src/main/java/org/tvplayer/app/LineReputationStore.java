package org.tvplayer.app;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 线路信誉（与 iOS LineReputationStore 对齐）：
 * 播放成功/失败写入记忆；下次排序时偏好好线、跳过黑名单。
 */
public class LineReputationStore {
    private static final String PREF = "tvplayer_line_rep";
    private static final String KEY_ENTRIES = "entries_v1";
    private static final String KEY_PREFERRED = "preferred_v1";
    private static final long BLACKLIST_MS = 24L * 3600L * 1000L;
    private static final int SUCCESS_WEIGHT = 3;

    private final SharedPreferences prefs;
    private final Map<String, Entry> entries = new HashMap<>();
    private final Map<String, String> preferredByChannel = new HashMap<>();

    public LineReputationStore(Context context) {
        prefs = context.getApplicationContext().getSharedPreferences(PREF, Context.MODE_PRIVATE);
        load();
    }

    public boolean isBlacklisted(String url) {
        Entry e = entries.get(norm(url));
        if (e == null || e.blacklistedUntil <= 0) {
            return false;
        }
        return e.blacklistedUntil > System.currentTimeMillis();
    }

    public String preferredURL(String channelKey) {
        if (channelKey == null) {
            return null;
        }
        return preferredByChannel.get(channelKey);
    }

    public int score(String url) {
        String u = norm(url);
        if (isBlacklisted(u)) {
            return Integer.MAX_VALUE - 1;
        }
        Entry e = entries.get(u);
        if (e == null) {
            return 500_000;
        }
        if (e.successCount == 0 && e.failCount == 0) {
            return 500_000;
        }
        int base = e.failCount * 10_000 - e.successCount * SUCCESS_WEIGHT * 1_000;
        long now = System.currentTimeMillis();
        if (e.lastSuccessAt > 0 && now - e.lastSuccessAt < 7L * 86400_000L) {
            base -= 2_000;
        }
        if (e.lastFailAt > 0 && now - e.lastFailAt < 86400_000L) {
            base += 5_000;
        }
        return Math.max(0, base);
    }

    public void markSuccess(String url, String channelKey) {
        String u = norm(url);
        if (u.isEmpty()) {
            return;
        }
        Entry e = entries.get(u);
        if (e == null) {
            e = new Entry(u);
        }
        e.successCount++;
        e.lastSuccessAt = System.currentTimeMillis();
        e.blacklistedUntil = 0;
        entries.put(u, e);
        if (channelKey != null && !channelKey.isEmpty()) {
            preferredByChannel.put(channelKey, u);
        }
        save();
    }

    public void markFailure(String url, String channelKey, boolean hard) {
        String u = norm(url);
        if (u.isEmpty()) {
            return;
        }
        Entry e = entries.get(u);
        if (e == null) {
            e = new Entry(u);
        }
        e.failCount++;
        e.lastFailAt = System.currentTimeMillis();
        if (hard) {
            e.blacklistedUntil = System.currentTimeMillis() + BLACKLIST_MS;
        }
        entries.put(u, e);
        if (channelKey != null && u.equals(preferredByChannel.get(channelKey))) {
            preferredByChannel.remove(channelKey);
        }
        save();
    }

    public List<String> orderedURLs(List<String> urls, String channelKey) {
        if (urls == null || urls.isEmpty()) {
            return new ArrayList<>();
        }
        final String pref = preferredURL(channelKey);
        Set<String> seen = new HashSet<>();
        List<String> unique = new ArrayList<>();
        for (String url : urls) {
            String n = norm(url);
            if (n.isEmpty() || !seen.add(n)) {
                continue;
            }
            unique.add(n);
        }
        Collections.sort(unique, new Comparator<String>() {
            @Override
            public int compare(String a, String b) {
                if (pref != null) {
                    if (a.equals(pref) && !b.equals(pref)) {
                        return -1;
                    }
                    if (b.equals(pref) && !a.equals(pref)) {
                        return 1;
                    }
                }
                boolean ba = isBlacklisted(a);
                boolean bb = isBlacklisted(b);
                if (ba != bb) {
                    return ba ? 1 : -1;
                }
                return Integer.compare(score(a), score(b));
            }
        });
        return unique;
    }

    public List<String> filterPlayable(List<String> urls) {
        if (urls == null) {
            return new ArrayList<>();
        }
        List<String> alive = new ArrayList<>();
        for (String u : urls) {
            if (!isBlacklisted(u)) {
                alive.add(u);
            }
        }
        return alive.isEmpty() ? new ArrayList<>(urls) : alive;
    }

    public void applyToChannels(List<Channel> channels) {
        if (channels == null) {
            return;
        }
        for (int i = 0; i < channels.size(); i++) {
            Channel ch = channels.get(i);
            List<String> ordered = orderedURLs(ch.getUrls(), ch.key);
            Channel nc = new Channel(ch.name, ch.group, ch.key, ordered);
            channels.set(i, nc);
        }
    }

    private String norm(String url) {
        return url == null ? "" : url.trim();
    }

    private void load() {
        try {
            String raw = prefs.getString(KEY_ENTRIES, "");
            if (raw != null && !raw.isEmpty()) {
                JSONArray arr = new JSONArray(raw);
                long now = System.currentTimeMillis();
                for (int i = 0; i < arr.length(); i++) {
                    JSONObject o = arr.getJSONObject(i);
                    Entry e = new Entry(o.optString("url", ""));
                    e.successCount = o.optInt("successCount", 0);
                    e.failCount = o.optInt("failCount", 0);
                    e.lastSuccessAt = o.optLong("lastSuccessAt", 0);
                    e.lastFailAt = o.optLong("lastFailAt", 0);
                    e.blacklistedUntil = o.optLong("blacklistedUntil", 0);
                    if (e.blacklistedUntil > 0 && e.blacklistedUntil <= now) {
                        e.blacklistedUntil = 0;
                    }
                    if (!e.url.isEmpty()) {
                        entries.put(e.url, e);
                    }
                }
            }
            String prefRaw = prefs.getString(KEY_PREFERRED, "");
            if (prefRaw != null && !prefRaw.isEmpty()) {
                JSONObject o = new JSONObject(prefRaw);
                JSONArray names = o.names();
                if (names != null) {
                    for (int i = 0; i < names.length(); i++) {
                        String k = names.getString(i);
                        preferredByChannel.put(k, o.optString(k, ""));
                    }
                }
            }
        } catch (Exception ignored) {
        }
    }

    private void save() {
        try {
            JSONArray arr = new JSONArray();
            for (Entry e : entries.values()) {
                JSONObject o = new JSONObject();
                o.put("url", e.url);
                o.put("successCount", e.successCount);
                o.put("failCount", e.failCount);
                o.put("lastSuccessAt", e.lastSuccessAt);
                o.put("lastFailAt", e.lastFailAt);
                o.put("blacklistedUntil", e.blacklistedUntil);
                arr.put(o);
            }
            JSONObject pref = new JSONObject();
            for (Map.Entry<String, String> en : preferredByChannel.entrySet()) {
                pref.put(en.getKey(), en.getValue());
            }
            prefs.edit()
                    .putString(KEY_ENTRIES, arr.toString())
                    .putString(KEY_PREFERRED, pref.toString())
                    .apply();
        } catch (Exception ignored) {
        }
    }

    private static class Entry {
        final String url;
        int successCount;
        int failCount;
        long lastSuccessAt;
        long lastFailAt;
        long blacklistedUntil;

        Entry(String url) {
            this.url = url;
        }
    }
}
