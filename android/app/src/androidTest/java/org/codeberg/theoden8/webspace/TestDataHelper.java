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

        // Save to SharedPreferences with Flutter's key prefix
        editor.putString("flutter.webViewModels", new JSONArray(sites).toString());
        editor.putString("flutter.webspaces", new JSONArray(webspaces).toString());
        editor.putString("flutter.selectedWebspaceId", "webspace_all");
        editor.putInt("flutter.currentIndex", 10000); // No site selected initially
        editor.putInt("flutter.themeMode", 0); // Light theme
        editor.putBoolean("flutter.showUrlBar", false);

        editor.apply();
        Log.d(TAG, "Test data seeded successfully");
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

        // "All" webspace (special)
        webspaces.add(createWebspace(
            "webspace_all",
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

        editor.remove("flutter.webViewModels");
        editor.remove("flutter.webspaces");
        editor.remove("flutter.selectedWebspaceId");
        editor.remove("flutter.currentIndex");
        editor.remove("flutter.themeMode");
        editor.remove("flutter.showUrlBar");

        editor.apply();
        Log.d(TAG, "Test data cleared");
    }
}
