package org.codeberg.theoden8.webspace;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.util.Log;

import androidx.test.core.app.ApplicationProvider;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.filters.LargeTest;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.By;
import androidx.test.uiautomator.UiDevice;
import androidx.test.uiautomator.UiObject2;
import androidx.test.uiautomator.Until;

import org.json.JSONObject;
import org.junit.Before;
import org.junit.ClassRule;
import org.junit.Test;
import org.junit.runner.RunWith;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

import tools.fastlane.screengrab.Screengrab;
import tools.fastlane.screengrab.UiAutomatorScreenshotStrategy;
import tools.fastlane.screengrab.locale.LocaleTestRule;

/**
 * Screenshot test for generating F-Droid and Play Store screenshots.
 *
 * This test automatically seeds demo data by directly writing to SharedPreferences
 * before taking screenshots, so no manual data seeding is required.
 *
 * To run this test and generate screenshots:
 * 1. From project root: fastlane android screenshots
 * 2. Or from android/: fastlane screenshots
 */
@RunWith(AndroidJUnit4.class)
@LargeTest
public class ScreenshotTest {

    private static final String TAG = "ScreenshotTest";
    private static final int SHORT_DELAY = 800;
    private static final int MEDIUM_DELAY = 1500;
    private static final int LONG_DELAY = 2500;
    private static final String PACKAGE_NAME = "org.codeberg.theoden8.webspace";

    @ClassRule
    public static final LocaleTestRule localeTestRule = new LocaleTestRule();

    private UiDevice device;

    @Before
    public void setUp() throws Exception {
        Log.d(TAG, "========================================");
        Log.d(TAG, "Setting up screenshot test");
        Log.d(TAG, "========================================");

        // Get the device instance
        device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation());

        // Wake up the device
        device.wakeUp();

        // Configure screenshot strategy
        Screengrab.setDefaultScreenshotStrategy(new UiAutomatorScreenshotStrategy());

        Log.d(TAG, "Force stopping app to ensure clean state...");

        // Force stop the app to ensure clean state
        try {
            device.executeShellCommand("am force-stop " + PACKAGE_NAME);
            Thread.sleep(1000);
        } catch (Exception e) {
            Log.w(TAG, "Failed to force-stop app: " + e.getMessage());
        }

        Log.d(TAG, "Seeding demo data...");

        // Seed demo data by writing directly to SharedPreferences
        seedDemoData();

        Log.d(TAG, "Demo data seeded, waiting for persistence...");
        Thread.sleep(1000); // Give time for data to be written to disk

        Log.d(TAG, "Launching app...");

        // Launch the app (after data is seeded)
        Context context = ApplicationProvider.getApplicationContext();
        Intent intent = context.getPackageManager().getLaunchIntentForPackage(PACKAGE_NAME);
        if (intent != null) {
            intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK | Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(intent);
        }

        // Wait for app to fully load
        device.wait(Until.hasObject(By.pkg(PACKAGE_NAME).depth(0)), 10000);
        Thread.sleep(LONG_DELAY);

        Log.d(TAG, "Setup complete");
    }

    /**
     * Seeds demo data by directly writing to SharedPreferences
     */
    private void seedDemoData() throws Exception {
        Log.d(TAG, "Writing demo data to SharedPreferences...");

        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        SharedPreferences prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE);
        SharedPreferences.Editor editor = prefs.edit();

        // Clear existing data
        editor.remove("flutter.webViewModels");
        editor.remove("flutter.webspaces");
        editor.remove("flutter.selectedWebspaceId");
        editor.remove("flutter.currentIndex");

        // Create demo sites as JSON strings
        List<String> sites = new ArrayList<>();
        sites.add(createSiteJson("https://example.com/blog", "My Blog"));
        sites.add(createSiteJson("https://tasks.example.com", "Tasks"));
        sites.add(createSiteJson("https://notes.example.com", "Notes"));
        sites.add(createSiteJson("http://homeserver.local:8080", "Home Dashboard"));
        sites.add(createSiteJson("http://192.168.1.100:3000", "Personal Wiki"));
        sites.add(createSiteJson("http://192.168.1.101:8096", "Media Server"));

        // Create demo webspaces as JSON strings
        List<String> webspaces = new ArrayList<>();
        webspaces.add(createWebspaceJson("all", "All", new int[]{})); // "All" shows all sites
        webspaces.add(createWebspaceJson("webspace_work", "Work", new int[]{0, 1, 2}));
        webspaces.add(createWebspaceJson("webspace_homeserver", "Home Server", new int[]{3, 4, 5}));

        // Write sites list (Flutter uses StringSet on Android)
        Set<String> sitesSet = new HashSet<>(sites);
        editor.putStringSet("flutter.webViewModels", sitesSet);

        // Write webspaces list
        Set<String> webspacesSet = new HashSet<>(webspaces);
        editor.putStringSet("flutter.webspaces", webspacesSet);

        // Write selected webspace (use "all")
        editor.putString("flutter.selectedWebspaceId", "all");

        // Write current index (10000 means no site selected)
        editor.putLong("flutter.currentIndex", 10000);

        // Write theme mode (0 = light)
        editor.putLong("flutter.themeMode", 0);

        // Write URL bar visibility (false)
        editor.putBoolean("flutter.showUrlBar", false);

        // Commit changes synchronously
        boolean success = editor.commit();

        Log.d(TAG, "Demo data write " + (success ? "SUCCEEDED" : "FAILED"));
        Log.d(TAG, "Wrote " + sites.size() + " sites, " + webspaces.size() + " webspaces");

        // Verify data was written
        Set<String> savedSites = prefs.getStringSet("flutter.webViewModels", null);
        Set<String> savedWebspaces = prefs.getStringSet("flutter.webspaces", null);
        String savedWebspaceId = prefs.getString("flutter.selectedWebspaceId", null);

        Log.d(TAG, "Verification:");
        Log.d(TAG, "  Sites: " + (savedSites != null ? "SET (" + savedSites.size() + " items)" : "NULL"));
        Log.d(TAG, "  Webspaces: " + (savedWebspaces != null ? "SET (" + savedWebspaces.size() + " items)" : "NULL"));
        Log.d(TAG, "  Selected: " + savedWebspaceId);

        if (savedSites != null && !savedSites.isEmpty()) {
            String firstSite = savedSites.iterator().next();
            Log.d(TAG, "  First site preview: " + firstSite.substring(0, Math.min(100, firstSite.length())));
        }
    }

    private String createSiteJson(String url, String name) throws Exception {
        JSONObject site = new JSONObject();
        site.put("initUrl", url);
        site.put("name", name);
        site.put("currentUrl", url);
        site.put("pageTitle", name);
        site.put("cookies", new org.json.JSONArray());
        return site.toString();
    }

    private String createWebspaceJson(String id, String name, int[] siteIndices) throws Exception {
        JSONObject webspace = new JSONObject();
        webspace.put("id", id);
        webspace.put("name", name);
        org.json.JSONArray indices = new org.json.JSONArray();
        for (int index : siteIndices) {
            indices.put(index);
        }
        webspace.put("siteIndices", indices);
        return webspace.toString();
    }

    @Test
    public void takeScreenshots() throws Exception {
        Log.d(TAG, "========================================");
        Log.d(TAG, "STARTING SCREENSHOT TOUR");
        Log.d(TAG, "========================================");

        // Wait for data to load
        Thread.sleep(MEDIUM_DELAY);

        // Log visible text on screen
        Log.d(TAG, "Visible elements:");
        logVisibleText();

        // Check if we're on webspaces list or sites view
        UiObject2 allWebspace = device.findObject(By.text("All"));
        boolean onWebspacesList = allWebspace != null;

        if (onWebspacesList) {
            Log.d(TAG, "On webspaces list screen");

            // Screenshot 1: Webspaces list
            Log.d(TAG, "Capturing webspaces list");
            Screengrab.screenshot("01-webspaces-list");
            Thread.sleep(SHORT_DELAY);

            // Select "All" webspace
            allWebspace.click();
            Thread.sleep(LONG_DELAY);
        }

        // Screenshot 2: All sites view (main screen)
        Log.d(TAG, "Capturing all sites view");
        Screengrab.screenshot("02-all-sites");
        Thread.sleep(MEDIUM_DELAY);

        // Open drawer to see site list
        Log.d(TAG, "Opening drawer");
        swipeFromLeftEdge();
        Thread.sleep(MEDIUM_DELAY);

        // Screenshot 3: Drawer with sites list
        Log.d(TAG, "Capturing sites drawer");
        Screengrab.screenshot("03-sites-drawer");
        Thread.sleep(SHORT_DELAY);

        // Look for a site to select
        List<UiObject2> textViews = device.findObjects(By.clazz("android.widget.TextView"));
        UiObject2 firstSite = null;
        String[] siteNames = {"My Blog", "Tasks", "Notes", "Home Dashboard"};

        for (String siteName : siteNames) {
            firstSite = device.findObject(By.text(siteName));
            if (firstSite != null) {
                Log.d(TAG, "Found site: " + siteName);
                break;
            }
        }

        if (firstSite != null) {
            String siteName = firstSite.getText();
            Log.d(TAG, "Selecting site: " + siteName);
            firstSite.click();
            Thread.sleep(LONG_DELAY);

            // Screenshot 4: Site webview
            Log.d(TAG, "Capturing site webview");
            Screengrab.screenshot("04-site-webview");
            Thread.sleep(MEDIUM_DELAY);

            // Open drawer again
            swipeFromLeftEdge();
            Thread.sleep(MEDIUM_DELAY);

            // Screenshot 5: Drawer showing current site
            Screengrab.screenshot("05-drawer-with-site");
            Thread.sleep(SHORT_DELAY);

            // Close drawer
            device.pressBack();
            Thread.sleep(SHORT_DELAY);
        } else {
            Log.w(TAG, "No sites found in drawer");
            // Close drawer
            device.pressBack();
            Thread.sleep(SHORT_DELAY);
        }

        // Try to navigate to webspaces list
        swipeFromLeftEdge();
        Thread.sleep(MEDIUM_DELAY);

        UiObject2 webspacesButton = device.findObject(By.text("Back to Webspaces"));
        if (webspacesButton == null) {
            webspacesButton = device.findObject(By.text("Webspaces"));
        }

        if (webspacesButton != null) {
            Log.d(TAG, "Navigating to webspaces list");
            webspacesButton.click();
            Thread.sleep(MEDIUM_DELAY);

            // Screenshot 6: Webspaces list view
            Screengrab.screenshot("06-webspaces-overview");
            Thread.sleep(SHORT_DELAY);

            // Look for "Work" webspace
            UiObject2 workWebspace = device.findObject(By.text("Work"));
            if (workWebspace != null) {
                Log.d(TAG, "Selecting Work webspace");
                workWebspace.click();
                Thread.sleep(LONG_DELAY);

                // Screenshot 7: Work webspace sites
                Screengrab.screenshot("07-work-webspace");
                Thread.sleep(MEDIUM_DELAY);

                // Open drawer
                swipeFromLeftEdge();
                Thread.sleep(MEDIUM_DELAY);

                // Screenshot 8: Work webspace drawer
                Screengrab.screenshot("08-work-sites-drawer");
                Thread.sleep(SHORT_DELAY);
            }
        } else {
            Log.w(TAG, "Could not find webspaces button");
            device.pressBack();
            Thread.sleep(SHORT_DELAY);
        }

        Log.d(TAG, "========================================");
        Log.d(TAG, "Screenshot tour completed");
        Log.d(TAG, "========================================");
    }

    /**
     * Swipe from left edge to open drawer
     */
    private void swipeFromLeftEdge() {
        int width = device.getDisplayWidth();
        int height = device.getDisplayHeight();
        device.swipe(0, height / 2, width / 3, height / 2, 20);
    }

    /**
     * Log visible text elements on screen for debugging
     */
    private void logVisibleText() {
        // Find all TextViews
        List<UiObject2> textViews = device.findObjects(By.clazz("android.widget.TextView"));
        Log.d(TAG, "Found " + textViews.size() + " TextViews");
        for (int i = 0; i < Math.min(textViews.size(), 15); i++) {
            UiObject2 tv = textViews.get(i);
            String text = tv.getText();
            if (text != null && !text.trim().isEmpty()) {
                Log.d(TAG, "  TextView " + i + ": '" + text + "'");
            }
        }

        // Check for expected elements
        String[] expectedTexts = {"All", "Work", "Home Server", "My Blog", "Tasks", "Notes"};
        for (String expectedText : expectedTexts) {
            UiObject2 obj = device.findObject(By.text(expectedText));
            Log.d(TAG, "  Looking for '" + expectedText + "': " + (obj != null ? "FOUND" : "NOT FOUND"));
        }
    }
}
