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

import org.junit.Before;
import org.junit.ClassRule;
import org.junit.Test;
import org.junit.runner.RunWith;

import java.util.List;

import tools.fastlane.screengrab.Screengrab;
import tools.fastlane.screengrab.UiAutomatorScreenshotStrategy;
import tools.fastlane.screengrab.locale.LocaleTestRule;

/**
 * Screenshot test for generating F-Droid and Play Store screenshots.
 *
 * This test launches the app with DEMO_MODE=true intent extra, which triggers
 * Flutter to seed demo data automatically on startup using lib/demo_data.dart.
 *
 * To run this test and generate screenshots:
 * 1. From project root: fastlane android screenshots
 * 2. Or from android/: fastlane screenshots
 */
@RunWith(AndroidJUnit4.class)
@LargeTest
public class ScreenshotTest {

    private static final String TAG = "ScreenshotTest";
    private static final int SHORT_DELAY = 2000;
    private static final int MEDIUM_DELAY = 3000;
    private static final int LONG_DELAY = 5000;
    private static final int APP_LOAD_DELAY = 8000;  // Extra time for Flutter to fully render
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

        // Note: We don't need to force-stop because screengrab with reinstall_app:true
        // already uninstalls and reinstalls the app for a clean state

        Log.d(TAG, "Launching app with DEMO_MODE flag...");

        // Launch the app with DEMO_MODE=true flag
        // Flutter will seed the demo data on startup when it detects this flag
        Context context = ApplicationProvider.getApplicationContext();
        Intent intent = context.getPackageManager().getLaunchIntentForPackage(PACKAGE_NAME);
        if (intent != null) {
            intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK | Intent.FLAG_ACTIVITY_NEW_TASK);
            intent.putExtra("DEMO_MODE", true);
            context.startActivity(intent);
        }

        // Wait for app to fully load and seed demo data
        device.wait(Until.hasObject(By.pkg(PACKAGE_NAME).depth(0)), 10000);
        Log.d(TAG, "App launched, waiting for Flutter to initialize and seed data...");
        Thread.sleep(APP_LOAD_DELAY);

        Log.d(TAG, "Setup complete - Flutter should have seeded demo data on startup");
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
        // Try multiple ways to find the "All" webspace (Flutter uses different accessibility systems)
        UiObject2 allWebspace = device.findObject(By.text("All"));
        if (allWebspace == null) {
            allWebspace = device.findObject(By.textContains("All"));
        }
        if (allWebspace == null) {
            allWebspace = device.findObject(By.desc("All"));
        }
        boolean onWebspacesList = allWebspace != null;
        Log.d(TAG, "On webspaces list: " + onWebspacesList);

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
        boolean drawerOpened = openDrawer();
        if (!drawerOpened) {
            Log.w(TAG, "Drawer failed to open - skipping drawer screenshots");
        }

        // Screenshot 3: Drawer with sites list
        Log.d(TAG, "Capturing sites drawer");
        Screengrab.screenshot("03-sites-drawer");
        Thread.sleep(SHORT_DELAY);

        // Look for a site to select
        UiObject2 firstSite = null;
        String[] siteNames = {"My Blog", "Tasks", "Notes", "Home Dashboard"};

        for (String siteName : siteNames) {
            firstSite = findElement(siteName);
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
            Log.d(TAG, "Opening drawer to show current site");
            openDrawer();

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
        Log.d(TAG, "Opening drawer to navigate to webspaces");
        openDrawer();

        UiObject2 webspacesButton = findElement("Back to Webspaces");
        if (webspacesButton == null) {
            webspacesButton = findElement("Webspaces");
        }

        if (webspacesButton != null) {
            Log.d(TAG, "Navigating to webspaces list");
            webspacesButton.click();
            Thread.sleep(MEDIUM_DELAY);

            // Screenshot 6: Webspaces list view
            Screengrab.screenshot("06-webspaces-overview");
            Thread.sleep(SHORT_DELAY);

            // Look for "Work" webspace
            UiObject2 workWebspace = findElement("Work");
            if (workWebspace != null) {
                Log.d(TAG, "Selecting Work webspace");
                workWebspace.click();
                Thread.sleep(LONG_DELAY);

                // Screenshot 7: Work webspace sites
                Screengrab.screenshot("07-work-webspace");
                Thread.sleep(MEDIUM_DELAY);

                // Open drawer
                Log.d(TAG, "Opening drawer for Work webspace");
                openDrawer();

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
     * Open the navigation drawer, returning true if successful
     */
    private boolean openDrawer() throws Exception {
        // First try to find and click the hamburger menu button
        // Flutter apps typically have this as a clickable element
        Log.d(TAG, "Looking for hamburger menu button...");

        // Try various descriptions Flutter might use
        String[] menuDescriptions = {
            "Open navigation menu",
            "Open drawer",
            "Navigation menu",
            "Menu",
            "Open navigation drawer"
        };

        UiObject2 menuButton = null;
        for (String desc : menuDescriptions) {
            menuButton = device.findObject(By.desc(desc));
            if (menuButton != null) {
                Log.d(TAG, "Found menu button with description: " + desc);
                break;
            }
        }

        if (menuButton != null) {
            Log.d(TAG, "Clicking menu button...");
            menuButton.click();
            Thread.sleep(MEDIUM_DELAY);
        } else {
            // Fallback to swipe gesture
            Log.d(TAG, "Menu button not found, trying swipe gesture...");
            swipeFromLeftEdge();
            Thread.sleep(MEDIUM_DELAY);
        }

        // Check if drawer is open by looking for drawer-specific elements
        // The drawer should show site names or navigation items
        UiObject2 drawerIndicator = findElement("My Blog");
        if (drawerIndicator == null) {
            drawerIndicator = findElement("Tasks");
        }
        if (drawerIndicator == null) {
            drawerIndicator = findElement("Notes");
        }

        boolean isOpen = drawerIndicator != null;
        Log.d(TAG, "Drawer open: " + isOpen);
        return isOpen;
    }

    /**
     * Find a UI element by text using multiple search strategies for Flutter compatibility
     */
    private UiObject2 findElement(String text) {
        UiObject2 obj = device.findObject(By.text(text));
        if (obj == null) {
            obj = device.findObject(By.textContains(text));
        }
        if (obj == null) {
            obj = device.findObject(By.desc(text));
        }
        if (obj == null) {
            obj = device.findObject(By.descContains(text));
        }
        return obj;
    }

    /**
     * Log visible text elements on screen for debugging
     */
    private void logVisibleText() {
        // Find all TextViews (native Android)
        List<UiObject2> textViews = device.findObjects(By.clazz("android.widget.TextView"));
        Log.d(TAG, "Found " + textViews.size() + " native TextViews");
        for (int i = 0; i < Math.min(textViews.size(), 10); i++) {
            UiObject2 tv = textViews.get(i);
            String text = tv.getText();
            if (text != null && !text.trim().isEmpty()) {
                Log.d(TAG, "  TextView " + i + ": '" + text + "'");
            }
        }

        // Try to find Flutter view
        UiObject2 flutterView = device.findObject(By.clazz("io.flutter.embedding.android.FlutterView"));
        if (flutterView != null) {
            Log.d(TAG, "Found FlutterView - Flutter is rendering");
            Log.d(TAG, "  ContentDescription: " + flutterView.getContentDescription());
        } else {
            Log.w(TAG, "FlutterView not found - Flutter may not be rendered yet");
        }

        // Check for expected elements using multiple search methods
        String[] expectedTexts = {"All", "Work", "Home Server", "My Blog", "Tasks", "Notes"};
        for (String expectedText : expectedTexts) {
            UiObject2 obj = device.findObject(By.text(expectedText));
            if (obj == null) {
                obj = device.findObject(By.textContains(expectedText));
            }
            if (obj == null) {
                obj = device.findObject(By.desc(expectedText));
            }
            if (obj == null) {
                obj = device.findObject(By.descContains(expectedText));
            }
            Log.d(TAG, "  Looking for '" + expectedText + "': " + (obj != null ? "FOUND" : "NOT FOUND"));
        }
    }
}
