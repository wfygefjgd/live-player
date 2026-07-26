package org.tvplayer.app;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

public class StorageHelper {
    private static final String PREF = "tvplayer";
    private static final String KEY_CACHE = "channels_cache";
    private static final String KEY_FAV = "favorites";
    private static final String KEY_HIDDEN = "hidden";
    private static final String KEY_CUSTOM_SOURCE_URL = "custom_source_url";
    private static final String KEY_SOURCE_URLS = "source_urls";
    private static final String KEY_SELECTED_SOURCE_URL = "selected_source_url";
    private static final String KEY_HIDDEN_LINES = "hidden_lines";
    private static final String KEY_FUSION_MODE = "fusion_mode";
    private static final String KEY_LAST_CHANNEL = "last_channel_key";
    private static final String KEY_LAST_SOURCE_INDEX = "last_source_index";

    private final SharedPreferences prefs;

    public StorageHelper(Context context) {
        prefs = context.getSharedPreferences(PREF, Context.MODE_PRIVATE);
    }

    public void saveChannels(List<Channel> channels) {
        try {
            JSONArray arr = new JSONArray();
            for (Channel c : channels) {
                JSONObject o = new JSONObject();
                o.put("name", c.name);
                o.put("group", c.group);
                o.put("key", c.key);
                JSONArray urls = new JSONArray();
                for (String url : c.getUrls()) {
                    urls.put(url);
                }
                o.put("urls", urls);
                arr.put(o);
            }
            prefs.edit().putString(KEY_CACHE, arr.toString()).apply();
        } catch (Exception ignored) {
        }
    }

    public List<Channel> loadChannels() {
        List<Channel> list = new ArrayList<>();
        try {
            String raw = prefs.getString(KEY_CACHE, null);
            if (raw == null || raw.isEmpty()) {
                return list;
            }
            JSONArray arr = new JSONArray(raw);
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.getJSONObject(i);
                JSONArray urlsArr = o.optJSONArray("urls");
                List<String> urls = new ArrayList<>();
                if (urlsArr != null) {
                    for (int j = 0; j < urlsArr.length(); j++) {
                        urls.add(urlsArr.optString(j, ""));
                    }
                }
                if (urls.isEmpty()) {
                    String legacyUrl = o.optString("url", "");
                    if (!legacyUrl.isEmpty()) {
                        urls.add(legacyUrl);
                    }
                }
                list.add(new Channel(
                        o.optString("name", "未知"),
                        o.optString("group", "未分组"),
                        o.optString("key", M3UParser.normalizeName(o.optString("name", "未知"))),
                        urls
                ));
            }
        } catch (Exception ignored) {
        }
        return list;
    }

    public Set<String> loadFavorites() {
        return new HashSet<>(prefs.getStringSet(KEY_FAV, new HashSet<String>()));
    }

    public void saveFavorites(Set<String> urls) {
        prefs.edit().putStringSet(KEY_FAV, new HashSet<>(urls)).apply();
    }

    public Set<String> loadHidden() {
        return new HashSet<>(prefs.getStringSet(KEY_HIDDEN, new HashSet<String>()));
    }

    public void saveHidden(Set<String> urls) {
        prefs.edit().putStringSet(KEY_HIDDEN, new HashSet<>(urls)).apply();
    }

    public void toggleFavorite(String url) {
        Set<String> fav = loadFavorites();
        if (fav.contains(url)) {
            fav.remove(url);
        } else {
            fav.add(url);
        }
        saveFavorites(fav);
    }

    public boolean isFavorite(String url) {
        return loadFavorites().contains(url);
    }

    public void toggleFavorite(Channel channel) {
        if (channel == null) {
            return;
        }
        toggleFavorite(channel.getStorageKey());
    }

    public boolean isFavorite(Channel channel) {
        if (channel == null) {
            return false;
        }
        Set<String> fav = loadFavorites();
        if (fav.contains(channel.getStorageKey())) {
            return true;
        }
        for (String url : channel.getUrls()) {
            if (fav.contains(url)) {
                return true;
            }
        }
        return false;
    }

    public boolean isHidden(String url) {
        return loadHidden().contains(url);
    }

    public boolean isHidden(Channel channel) {
        if (channel == null) {
            return false;
        }
        Set<String> hidden = loadHidden();
        if (hidden.contains(channel.getStorageKey())) {
            return true;
        }
        for (String url : channel.getUrls()) {
            if (hidden.contains(url)) {
                return true;
            }
        }
        return false;
    }

    public void hideChannel(String url) {
        Set<String> hidden = loadHidden();
        hidden.add(url);
        saveHidden(hidden);
    }

    public void hideChannel(Channel channel) {
        if (channel == null) {
            return;
        }
        Set<String> hidden = loadHidden();
        hidden.add(channel.getStorageKey());
        for (String url : channel.getUrls()) {
            hidden.add(url);
        }
        saveHidden(hidden);
    }

    public void unhideAll() {
        saveHidden(new HashSet<>());
    }

    public void saveCustomSourceUrl(String url) {
        prefs.edit().putString(KEY_CUSTOM_SOURCE_URL, url != null ? url.trim() : "").apply();
    }

    public String loadCustomSourceUrl() {
        return prefs.getString(KEY_CUSTOM_SOURCE_URL, "");
    }

    public void saveSourceUrls(List<String> urls) {
        try {
            JSONArray arr = new JSONArray();
            if (urls != null) {
                LinkedHashSet<String> seen = new LinkedHashSet<>();
                for (String url : urls) {
                    if (url == null) {
                        continue;
                    }
                    String clean = url.trim();
                    if (!clean.isEmpty() && seen.add(clean)) {
                        arr.put(clean);
                    }
                }
            }
            prefs.edit().putString(KEY_SOURCE_URLS, arr.toString()).apply();
        } catch (Exception ignored) {
        }
    }

    public List<String> loadSourceUrls() {
        List<String> urls = new ArrayList<>();
        try {
            String raw = prefs.getString(KEY_SOURCE_URLS, "");
            if (raw != null && !raw.isEmpty()) {
                JSONArray arr = new JSONArray(raw);
                for (int i = 0; i < arr.length(); i++) {
                    String url = arr.optString(i, "").trim();
                    if (!url.isEmpty() && !urls.contains(url)) {
                        urls.add(url);
                    }
                }
            }
        } catch (Exception ignored) {
        }
        return urls;
    }

    public void saveSelectedSourceUrl(String url) {
        prefs.edit().putString(KEY_SELECTED_SOURCE_URL, url != null ? url.trim() : "").apply();
    }

    public String loadSelectedSourceUrl() {
        String selected = prefs.getString(KEY_SELECTED_SOURCE_URL, "");
        if (selected != null && !selected.trim().isEmpty()) {
            return selected.trim();
        }
        return loadCustomSourceUrl();
    }

    public Set<String> loadHiddenLines() {
        return new HashSet<>(prefs.getStringSet(KEY_HIDDEN_LINES, new HashSet<String>()));
    }

    public void saveHiddenLines(Set<String> urls) {
        prefs.edit().putStringSet(KEY_HIDDEN_LINES, new HashSet<>(urls)).apply();
    }

    public void hideLine(String url) {
        if (url == null || url.trim().isEmpty()) {
            return;
        }
        Set<String> hidden = loadHiddenLines();
        hidden.add(url.trim());
        saveHiddenLines(hidden);
    }

    public boolean isLineHidden(String url) {
        if (url == null || url.trim().isEmpty()) {
            return false;
        }
        return loadHiddenLines().contains(url.trim());
    }

    /** off / fast / balanced / complete / smart */
    public void saveFusionMode(String mode) {
        String m = mode == null ? "smart" : mode.trim().toLowerCase();
        prefs.edit().putString(KEY_FUSION_MODE, m).apply();
    }

    public String loadFusionMode() {
        String m = prefs.getString(KEY_FUSION_MODE, "smart");
        if (m == null || m.trim().isEmpty()) {
            return "smart";
        }
        return m.trim().toLowerCase();
    }

    public void saveLastChannel(String key, int sourceIndex) {
        prefs.edit()
                .putString(KEY_LAST_CHANNEL, key != null ? key : "")
                .putInt(KEY_LAST_SOURCE_INDEX, Math.max(0, sourceIndex))
                .apply();
    }

    public String loadLastChannelKey() {
        String k = prefs.getString(KEY_LAST_CHANNEL, "");
        return k != null ? k : "";
    }

    public int loadLastSourceIndex() {
        return prefs.getInt(KEY_LAST_SOURCE_INDEX, 0);
    }
}
