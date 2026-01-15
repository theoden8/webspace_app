package org.codeberg.theoden8.webspace;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * Helper class to seed test data for screenshot generation.
 * Creates realistic webspace and site configurations.
 */
public class TestDataHelper {
    private static final String TAG = "TestDataHelper";
    private static final String PREFS_NAME = "FlutterSharedPreferences";
    private static final String KEY_PREFIX = "flutter.";

    // Flutter's shared_preferences plugin uses this prefix for List<String> values
    private static final String LIST_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu";

    /**
     * Seeds the app with realistic test data for screenshots.
     * Creates multiple sites organized into webspaces.
     */
    public static void seedTestData(Context context) throws JSONException {
        Log.d(TAG, "========================================");
        Log.d(TAG, "STARTING DATA SEEDING");
        Log.d(TAG, "========================================");

        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        Log.d(TAG, "SharedPreferences name: " + PREFS_NAME);
        Log.d(TAG, "Key prefix: " + KEY_PREFIX);

        SharedPreferences.Editor editor = prefs.edit();

        // Create sample sites
        Log.d(TAG, "Creating sample sites...");
        List<String> sites = createSampleSites();
        Log.d(TAG, "Created " + sites.size() + " sites");
        for (int i = 0; i < sites.size(); i++) {
            Log.d(TAG, "Site " + i + ": " + sites.get(i));
        }

        // Create sample webspaces
        Log.d(TAG, "Creating sample webspaces...");
        List<String> webspaces = createSampleWebspaces();
        Log.d(TAG, "Created " + webspaces.size() + " webspaces");
        for (int i = 0; i < webspaces.size(); i++) {
            Log.d(TAG, "Webspace " + i + ": " + webspaces.get(i));
        }

        // Encode lists for Flutter's shared_preferences format
        // Flutter stores List<String> as: prefix + JSON array string
        Log.d(TAG, "Encoding lists for Flutter shared_preferences format...");

        JSONArray sitesArray = new JSONArray(sites);
        JSONArray webspacesArray = new JSONArray(webspaces);

        String sitesEncoded = LIST_PREFIX + sitesArray.toString();
        String webspacesEncoded = LIST_PREFIX + webspacesArray.toString();

        Log.d(TAG, "Encoded sites length: " + sitesEncoded.length());
        Log.d(TAG, "Encoded webspaces length: " + webspacesEncoded.length());
        Log.d(TAG, "Sites preview: " + sitesEncoded.substring(0, Math.min(100, sitesEncoded.length())) + "...");
        Log.d(TAG, "Webspaces preview: " + webspacesEncoded.substring(0, Math.min(100, webspacesEncoded.length())) + "...");

        // Save to SharedPreferences
        Log.d(TAG, "Writing to SharedPreferences...");
        Log.d(TAG, "Key for sites: " + KEY_PREFIX + "webViewModels");
        Log.d(TAG, "Key for webspaces: " + KEY_PREFIX + "webspaces");

        editor.putString(KEY_PREFIX + "webViewModels", sitesEncoded);
        editor.putString(KEY_PREFIX + "webspaces", webspacesEncoded);
        editor.putString(KEY_PREFIX + "selectedWebspaceId", "__all_webspace__");
        editor.putInt(KEY_PREFIX + "currentIndex", 10000);
        editor.putInt(KEY_PREFIX + "themeMode", 0);
        editor.putBoolean(KEY_PREFIX + "showUrlBar", false);

        boolean commitResult = editor.commit();
        Log.d(TAG, "Commit result: " + commitResult);

        // Verify the data was written
        Log.d(TAG, "========================================");
        Log.d(TAG, "VERIFYING DATA PERSISTENCE");
        Log.d(TAG, "========================================");
        verifyData(context);
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
     * Verifies that data was written correctly to SharedPreferences.
     */
    public static void verifyData(Context context) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);

        // List all keys in SharedPreferences
        Log.d(TAG, "All keys in SharedPreferences:");
        for (String key : prefs.getAll().keySet()) {
            Object value = prefs.getAll().get(key);
            String valueType = value != null ? value.getClass().getSimpleName() : "null";
            Log.d(TAG, "  Key: " + key + " (type: " + valueType + ")");

            if (value instanceof Set) {
                Set<?> set = (Set<?>) value;
                Log.d(TAG, "    Set size: " + set.size());
                int i = 0;
                for (Object item : set) {
                    if (i < 3) { // Log first 3 items
                        Log.d(TAG, "    Item " + i + ": " + item);
                    }
                    i++;
                }
                if (set.size() > 3) {
                    Log.d(TAG, "    ... and " + (set.size() - 3) + " more items");
                }
            } else {
                Log.d(TAG, "    Value: " + value);
            }
        }

        // Check specific keys
        Log.d(TAG, "Checking specific keys:");

        // Flutter stores List<String> as encoded strings with prefix
        String sitesEncoded = prefs.getString(KEY_PREFIX + "webViewModels", null);
        String webspacesEncoded = prefs.getString(KEY_PREFIX + "webspaces", null);
        String selectedId = prefs.getString(KEY_PREFIX + "selectedWebspaceId", null);
        int currentIndex = prefs.getInt(KEY_PREFIX + "currentIndex", -1);
        int themeMode = prefs.getInt(KEY_PREFIX + "themeMode", -1);
        boolean showUrlBar = prefs.getBoolean(KEY_PREFIX + "showUrlBar", false);

        Log.d(TAG, "selectedWebspaceId: " + selectedId);
        Log.d(TAG, "currentIndex: " + currentIndex);
        Log.d(TAG, "themeMode: " + themeMode);
        Log.d(TAG, "showUrlBar: " + showUrlBar);

        // Decode the encoded lists
        int sitesCount = 0;
        int webspacesCount = 0;

        if (sitesEncoded != null && sitesEncoded.startsWith(LIST_PREFIX)) {
            try {
                String sitesJson = sitesEncoded.substring(LIST_PREFIX.length());
                JSONArray sitesArray = new JSONArray(sitesJson);
                sitesCount = sitesArray.length();
                Log.d(TAG, "webViewModels: " + sitesCount + " items (decoded from encoded string)");
                // Log first item as example
                if (sitesCount > 0) {
                    Log.d(TAG, "  First site: " + sitesArray.getString(0).substring(0, Math.min(100, sitesArray.getString(0).length())));
                }
            } catch (JSONException e) {
                Log.e(TAG, "ERROR: Failed to decode sites: " + e.getMessage());
            }
        } else {
            Log.e(TAG, "ERROR: webViewModels is " + (sitesEncoded == null ? "NULL" : "not in expected format"));
            if (sitesEncoded != null) {
                Log.e(TAG, "  Value: " + sitesEncoded.substring(0, Math.min(100, sitesEncoded.length())));
            }
        }

        if (webspacesEncoded != null && webspacesEncoded.startsWith(LIST_PREFIX)) {
            try {
                String webspacesJson = webspacesEncoded.substring(LIST_PREFIX.length());
                JSONArray webspacesArray = new JSONArray(webspacesJson);
                webspacesCount = webspacesArray.length();
                Log.d(TAG, "webspaces: " + webspacesCount + " items (decoded from encoded string)");
                // Log first item as example
                if (webspacesCount > 0) {
                    Log.d(TAG, "  First webspace: " + webspacesArray.getString(0));
                }
            } catch (JSONException e) {
                Log.e(TAG, "ERROR: Failed to decode webspaces: " + e.getMessage());
            }
        } else {
            Log.e(TAG, "ERROR: webspaces is " + (webspacesEncoded == null ? "NULL" : "not in expected format"));
            if (webspacesEncoded != null) {
                Log.e(TAG, "  Value: " + webspacesEncoded.substring(0, Math.min(100, webspacesEncoded.length())));
            }
        }

        if (sitesCount == 0) {
            Log.e(TAG, "ERROR: No sites found in SharedPreferences!");
        }
        if (webspacesCount == 0) {
            Log.e(TAG, "ERROR: No webspaces found in SharedPreferences!");
        }

        Log.d(TAG, "========================================");
    }

    /**
     * Clears all test data from SharedPreferences.
     */
    public static void clearTestData(Context context) {
        Log.d(TAG, "========================================");
        Log.d(TAG, "CLEARING TEST DATA");
        Log.d(TAG, "========================================");

        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);

        // Log what we're about to clear
        Log.d(TAG, "Keys to remove:");
        Log.d(TAG, "  - " + KEY_PREFIX + "webViewModels");
        Log.d(TAG, "  - " + KEY_PREFIX + "webspaces");
        Log.d(TAG, "  - " + KEY_PREFIX + "selectedWebspaceId");
        Log.d(TAG, "  - " + KEY_PREFIX + "currentIndex");
        Log.d(TAG, "  - " + KEY_PREFIX + "themeMode");
        Log.d(TAG, "  - " + KEY_PREFIX + "showUrlBar");

        SharedPreferences.Editor editor = prefs.edit();
        editor.remove(KEY_PREFIX + "webViewModels");
        editor.remove(KEY_PREFIX + "webspaces");
        editor.remove(KEY_PREFIX + "selectedWebspaceId");
        editor.remove(KEY_PREFIX + "currentIndex");
        editor.remove(KEY_PREFIX + "themeMode");
        editor.remove(KEY_PREFIX + "showUrlBar");

        boolean commitResult = editor.commit();
        Log.d(TAG, "Clear commit result: " + commitResult);
        Log.d(TAG, "Test data cleared");
        Log.d(TAG, "========================================");
    }
}
