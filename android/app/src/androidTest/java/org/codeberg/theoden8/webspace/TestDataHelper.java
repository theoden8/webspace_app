package org.codeberg.theoden8.webspace;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * Helper class to seed test data for screenshot generation.
 * Creates realistic webspace and site configurations.
 */
public class TestDataHelper {
    private static final String TAG = "TestDataHelper";
    private static final String PREFS_NAME = "FlutterSharedPreferences";
    private static final String KEY_PREFIX = "flutter.";

    /**
     * Seeds the app with realistic test data for screenshots.
     * Creates multiple sites organized into webspaces.
     */
    public static void seedTestData(Context context) throws JSONException {
        Log.d(TAG, "Seeding test data");

        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        SharedPreferences.Editor editor = prefs.edit();

        // Create sample sites
        List<String> sites = createSampleSites();

        // Create sample webspaces
        List<String> webspaces = createSampleWebspaces();

        // Convert lists to Sets (Flutter's shared_preferences uses StringSet on Android)
        Set<String> sitesSet = new HashSet<>(sites);
        Set<String> webspacesSet = new HashSet<>(webspaces);

        // Save to SharedPreferences
        // Flutter's shared_preferences plugin stores List<String> as StringSet on Android
        editor.putStringSet(KEY_PREFIX + "webViewModels", sitesSet);
        editor.putStringSet(KEY_PREFIX + "webspaces", webspacesSet);
        editor.putString(KEY_PREFIX + "selectedWebspaceId", "__all_webspace__");
        editor.putInt(KEY_PREFIX + "currentIndex", 10000); // No site selected initially
        editor.putInt(KEY_PREFIX + "themeMode", 0); // Light theme
        editor.putBoolean(KEY_PREFIX + "showUrlBar", false);

        editor.commit(); // Use commit() for synchronous write to ensure data is persisted before test runs
        Log.d(TAG, "Test data seeded successfully");
        Log.d(TAG, "Sites count: " + sitesSet.size());
        Log.d(TAG, "Webspaces count: " + webspacesSet.size());

        // Log first site as example
        if (!sites.isEmpty()) {
            Log.d(TAG, "Example site: " + sites.get(0));
        }
        if (!webspaces.isEmpty()) {
            Log.d(TAG, "Example webspace: " + webspaces.get(0));
        }
    }

    /**
     * Creates a list of sample sites that look natural for a store listing.
     * These represent common use cases for the app.
     */
    private static List<String> createSampleSites() throws JSONException {
        List<String> sites = new ArrayList<>();

        // Site 1: Personal Blog
        sites.add(createSite(
            "My Blog",
            "https://example.com/blog",
            "My Blog"
        ));

        // Site 2: Home Server Dashboard
        sites.add(createSite(
            "Home Dashboard",
            "http://homeserver.local:8080",
            "Home Dashboard"
        ));

        // Site 3: Photo Gallery
        sites.add(createSite(
            "Photo Gallery",
            "https://photos.example.com",
            "Photo Gallery"
        ));

        // Site 4: Task Manager
        sites.add(createSite(
            "Tasks",
            "https://tasks.example.com",
            "Tasks"
        ));

        // Site 5: Wiki
        sites.add(createSite(
            "Personal Wiki",
            "http://192.168.1.100:3000",
            "Personal Wiki"
        ));

        // Site 6: Media Server
        sites.add(createSite(
            "Media Server",
            "http://192.168.1.101:8096",
            "Media Server"
        ));

        // Site 7: RSS Reader
        sites.add(createSite(
            "News Feed",
            "https://reader.example.com",
            "News Feed"
        ));

        // Site 8: Notes App
        sites.add(createSite(
            "Notes",
            "https://notes.example.com",
            "Notes"
        ));

        return sites;
    }

    /**
     * Creates sample webspaces to organize the sites.
     */
    private static List<String> createSampleWebspaces() throws JSONException {
        List<String> webspaces = new ArrayList<>();

        // "All" webspace (special) - note the app uses __all_webspace__ as the ID
        webspaces.add(createWebspace(
            "__all_webspace__",
            "All",
            new int[]{} // Empty - "All" doesn't store indices
        ));

        // "Work" webspace
        webspaces.add(createWebspace(
            generateId(),
            "Work",
            new int[]{0, 3, 7} // Blog, Tasks, Notes
        ));

        // "Home Server" webspace
        webspaces.add(createWebspace(
            generateId(),
            "Home Server",
            new int[]{1, 4, 5} // Dashboard, Wiki, Media Server
        ));

        // "Personal" webspace
        webspaces.add(createWebspace(
            generateId(),
            "Personal",
            new int[]{2, 6, 7} // Photos, News, Notes
        ));

        return webspaces;
    }

    /**
     * Creates a JSON string representing a site/webview model.
     */
    private static String createSite(String name, String url, String pageTitle) throws JSONException {
        JSONObject site = new JSONObject();
        site.put("initUrl", url);
        site.put("currentUrl", url);
        site.put("name", name);
        site.put("pageTitle", pageTitle);
        site.put("cookies", new JSONArray());

        // Add proxy settings (DEFAULT type)
        JSONObject proxySettings = new JSONObject();
        proxySettings.put("type", "DEFAULT");
        site.put("proxySettings", proxySettings);

        // Add other WebViewModel fields
        site.put("javascriptEnabled", true);
        site.put("userAgent", "");
        site.put("thirdPartyCookiesEnabled", false);

        return site.toString();
    }

    /**
     * Creates a JSON string representing a webspace.
     */
    private static String createWebspace(String id, String name, int[] siteIndices) throws JSONException {
        JSONObject webspace = new JSONObject();
        webspace.put("id", id);
        webspace.put("name", name);

        JSONArray indices = new JSONArray();
        for (int index : siteIndices) {
            indices.put(index);
        }
        webspace.put("siteIndices", indices);

        return webspace.toString();
    }

    /**
     * Generates a unique ID for a webspace.
     */
    private static String generateId() {
        return "webspace_" + UUID.randomUUID().toString().substring(0, 8);
    }

    /**
     * Clears all test data from SharedPreferences.
     */
    public static void clearTestData(Context context) {
        Log.d(TAG, "Clearing test data");
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        SharedPreferences.Editor editor = prefs.edit();

        editor.remove(KEY_PREFIX + "webViewModels");
        editor.remove(KEY_PREFIX + "webspaces");
        editor.remove(KEY_PREFIX + "selectedWebspaceId");
        editor.remove(KEY_PREFIX + "currentIndex");
        editor.remove(KEY_PREFIX + "themeMode");
        editor.remove(KEY_PREFIX + "showUrlBar");

        editor.apply();
        Log.d(TAG, "Test data cleared");
    }
}
