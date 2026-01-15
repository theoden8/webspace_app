package org.codeberg.theoden8.webspace;

import android.content.Context;
import android.content.Intent;
import android.util.Log;

import androidx.test.core.app.ApplicationProvider;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.filters.LargeTest;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.By;
import androidx.test.uiautomator.UiDevice;
import androidx.test.uiautomator.UiObject2;
import androidx.test.uiautomator.Until;

import java.util.List;

import org.junit.Before;
import org.junit.ClassRule;
import org.junit.Test;
import org.junit.runner.RunWith;

import tools.fastlane.screengrab.Screengrab;
import tools.fastlane.screengrab.UiAutomatorScreenshotStrategy;
import tools.fastlane.screengrab.locale.LocaleTestRule;

/**
 * Screenshot test for generating F-Droid and Play Store screenshots.
 * This test creates a comprehensive tour of the app's features by adding sites via UI.
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

    // Test data: sites to add
    private static final String[][] SITES = {
        {"My Blog", "https://example.com/blog"},
        {"Tasks", "https://tasks.example.com"},
        {"Notes", "https://notes.example.com"},
        {"Home Dashboard", "http://homeserver.local:8080"},
        {"Personal Wiki", "http://192.168.1.100:3000"},
        {"Media Server", "http://192.168.1.101:8096"},
    };

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

        // Clear existing data
        Context context = ApplicationProvider.getApplicationContext();
        TestDataHelper.clearTestData(context);
        Thread.sleep(500);

        Log.d(TAG, "Launching app...");

        // Launch the app
        Intent intent = context.getPackageManager().getLaunchIntentForPackage(PACKAGE_NAME);
        if (intent != null) {
            intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK);
            context.startActivity(intent);
        }

        // Wait for app to fully load
        device.wait(Until.hasObject(By.pkg(PACKAGE_NAME).depth(0)), 10000);
        Thread.sleep(LONG_DELAY);

        Log.d(TAG, "App launched, adding test sites...");

        // Add sites through UI
        addSitesViaUI();

        Log.d(TAG, "Setup complete - test sites added");
    }

    /**
     * Add sites by interacting with the UI
     */
    private void addSitesViaUI() throws InterruptedException {
        for (int i = 0; i < SITES.length; i++) {
            String name = SITES[i][0];
            String url = SITES[i][1];

            Log.d(TAG, "Adding site " + (i + 1) + "/" + SITES.length + ": " + name);

            // Find and click FAB
            UiObject2 fab = findFab();
            if (fab == null) {
                Log.e(TAG, "FAB not found, cannot add site: " + name);
                continue;
            }

            fab.click();
            Thread.sleep(MEDIUM_DELAY);

            // Find URL input field
            UiObject2 urlField = device.findObject(By.clazz("android.widget.EditText"));
            if (urlField == null) {
                Log.e(TAG, "URL field not found, cannot add site: " + name);
                device.pressBack();
                Thread.sleep(SHORT_DELAY);
                continue;
            }

            // Enter URL
            urlField.setText(url);
            Thread.sleep(SHORT_DELAY);

            // Find and click Add/Save button
            UiObject2 addButton = device.findObject(By.text("Add"));
            if (addButton == null) {
                addButton = device.findObject(By.text("Save"));
            }
            if (addButton == null) {
                addButton = device.findObject(By.desc("Add"));
            }

            if (addButton != null) {
                addButton.click();
                Thread.sleep(MEDIUM_DELAY);
                Log.d(TAG, "Successfully added: " + name);
            } else {
                Log.e(TAG, "Add button not found, canceling");
                device.pressBack();
                Thread.sleep(SHORT_DELAY);
            }
        }

        Log.d(TAG, "Finished adding " + SITES.length + " sites");
    }

    @Test
    public void takeScreenshots() throws Exception {
        Log.d(TAG, "========================================");
        Log.d(TAG, "STARTING SCREENSHOT TOUR");
        Log.d(TAG, "========================================");

        // Wait a bit to ensure all sites are loaded
        Thread.sleep(MEDIUM_DELAY);

        // Log visible text on screen
        Log.d(TAG, "Visible elements:");
        logVisibleText();

        // Screenshot 1: Main screen showing "All" webspace with sites
        Log.d(TAG, "Capturing main screen with All webspace");
        Screengrab.screenshot("01-all-sites");
        Thread.sleep(MEDIUM_DELAY);

        // Open drawer to see site list
        Log.d(TAG, "Opening drawer");
        swipeFromLeftEdge();
        Thread.sleep(MEDIUM_DELAY);

        // Screenshot 2: Drawer with sites list
        Log.d(TAG, "Capturing sites drawer");
        Screengrab.screenshot("02-sites-drawer");
        Thread.sleep(SHORT_DELAY);

        // Select first site
        UiObject2 firstSite = device.findObject(By.text(SITES[0][0]));
        if (firstSite != null) {
            Log.d(TAG, "Selecting first site: " + SITES[0][0]);
            firstSite.click();
            Thread.sleep(LONG_DELAY);

            // Screenshot 3: Site webview
            Log.d(TAG, "Capturing site webview");
            Screengrab.screenshot("03-site-webview");
            Thread.sleep(MEDIUM_DELAY);

            // Open drawer again
            swipeFromLeftEdge();
            Thread.sleep(MEDIUM_DELAY);

            // Screenshot 4: Drawer showing current site
            Screengrab.screenshot("04-drawer-with-site");
            Thread.sleep(SHORT_DELAY);

            // Click "Back to Webspaces" or just close drawer
            device.pressBack();
            Thread.sleep(SHORT_DELAY);
        }

        // Try to show webspaces list by opening drawer
        swipeFromLeftEdge();
        Thread.sleep(MEDIUM_DELAY);

        // Look for "Webspaces" button or similar
        UiObject2 webspacesButton = device.findObject(By.text("Back to Webspaces"));
        if (webspacesButton == null) {
            webspacesButton = device.findObject(By.text("Webspaces"));
        }

        if (webspacesButton != null) {
            Log.d(TAG, "Navigating to webspaces list");
            webspacesButton.click();
            Thread.sleep(MEDIUM_DELAY);

            // Screenshot 5: Webspaces list (shows "All" and any others)
            Screengrab.screenshot("05-webspaces-list");
            Thread.sleep(SHORT_DELAY);

            // Try to create a webspace
            UiObject2 createWebspaceFab = findFab();
            if (createWebspaceFab != null) {
                Log.d(TAG, "Opening create webspace dialog");
                createWebspaceFab.click();
                Thread.sleep(MEDIUM_DELAY);

                // Screenshot 6: Create webspace dialog
                Screengrab.screenshot("06-create-webspace");
                Thread.sleep(SHORT_DELAY);

                device.pressBack();
                Thread.sleep(SHORT_DELAY);
            }

            // Go back to "All" webspace
            UiObject2 allWebspace = device.findObject(By.text("All"));
            if (allWebspace != null) {
                allWebspace.click();
                Thread.sleep(MEDIUM_DELAY);
            }
        }

        // Final screenshot: Back to main view
        Thread.sleep(SHORT_DELAY);
        Screengrab.screenshot("07-main-view");

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
     * Try multiple ways to find the FAB button
     */
    private UiObject2 findFab() {
        // Try by content description
        UiObject2 fab = device.findObject(By.desc("Add"));
        if (fab != null) return fab;

        // Try by text
        fab = device.findObject(By.text("+"));
        if (fab != null) return fab;

        // Try finding floating action button by class and clickable
        fab = device.findObject(By.clazz("android.widget.Button").clickable(true));
        if (fab != null) return fab;

        // Try any clickable view with "add" description
        fab = device.findObject(By.descContains("add"));
        if (fab != null) return fab;

        return null;
    }

    /**
     * Log visible text elements on screen for debugging
     */
    private void logVisibleText() {
        Log.d(TAG, "Visible text elements:");

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

        // Find all Buttons
        List<UiObject2> buttons = device.findObjects(By.clazz("android.widget.Button"));
        Log.d(TAG, "Found " + buttons.size() + " Buttons");
        for (int i = 0; i < Math.min(buttons.size(), 10); i++) {
            UiObject2 btn = buttons.get(i);
            String text = btn.getText();
            String desc = btn.getContentDescription();
            if ((text != null && !text.isEmpty()) || (desc != null && !desc.isEmpty())) {
                Log.d(TAG, "  Button " + i + ": text='" + text + "', desc='" + desc + "'");
            }
        }

        // Check for FAB
        UiObject2 fab = findFab();
        Log.d(TAG, "FAB found: " + (fab != null));
    }
}
