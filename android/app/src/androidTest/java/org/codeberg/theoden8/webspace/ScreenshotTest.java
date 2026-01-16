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
    private static final int SHORT_DELAY = 3000;
    private static final int MEDIUM_DELAY = 5000;
    private static final int LONG_DELAY = 8000;
    private static final int QUICK_DELAY = 100;
    private static final int APP_LOAD_DELAY = 10000;  // Extra time for Flutter to fully render
    private static final int DRAWER_OPEN_DELAY = 5000;  // Time for drawer animation and site icons to load
    private static final int ICON_LOAD_DELAY = 6000;  // Time for site icons to load after navigation
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

        // Wait briefly for webspaces list to render
        Log.d(TAG, "Waiting briefly for webspaces list...");
        Thread.sleep(SHORT_DELAY);

        // Log visible text on screen
        Log.d(TAG, "Visible elements:");
        logVisibleText();

        // Also dump ALL text-like elements
        Log.d(TAG, "Dumping all UI elements...");
        dumpAllElements();

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

            // Select "All" webspace (already selected by default, so no separate screenshot)
            allWebspace.click();
            Log.d(TAG, "Waiting for All webspace to load and site icons to render...");
            Thread.sleep(LONG_DELAY);
            Thread.sleep(ICON_LOAD_DELAY);  // Extra time for site icons to load

            if (isDrawerOpen()) {
                Log.d(TAG, "Closing drawer to capture all sites view");
                closeDrawer();
                Thread.sleep(SHORT_DELAY);
            }
        }

        // Screenshot 1: All sites view (main screen)
        Log.d(TAG, "Capturing all sites view");
        Screengrab.screenshot("01-all-sites");
        Thread.sleep(MEDIUM_DELAY);

        // Open drawer to see site list
        Log.d(TAG, "Opening drawer");
        boolean drawerOpened = openDrawer();
        Thread.sleep(QUICK_DELAY);
        if (!drawerOpened) {
            Log.w(TAG, "Drawer failed to open - skipping drawer screenshots");
        }

        // Screenshot 2: Drawer with sites list
        Log.d(TAG, "Capturing sites drawer");
        Screengrab.screenshot("02-sites-drawer");
        Thread.sleep(SHORT_DELAY);

        // Look for a site to select
        UiObject2 firstSite = null;
        String[] siteNames = {"DuckDuckGo", "Piped", "GitHub", "Reddit"};

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
            Log.d(TAG, "Waiting for site webview and icons to load...");
            Thread.sleep(LONG_DELAY);
            Thread.sleep(ICON_LOAD_DELAY);  // Extra time for webview and icons to load

            // Screenshot 3: Site webview
            Log.d(TAG, "Capturing site webview");
            Screengrab.screenshot("03-site-webview");
            Thread.sleep(MEDIUM_DELAY);

            // Open drawer again
            Log.d(TAG, "Opening drawer to show current site");
            openDrawer();
            Thread.sleep(QUICK_DELAY);

            // Screenshot 4: Drawer showing current site
            Screengrab.screenshot("04-drawer-with-site");
            Thread.sleep(SHORT_DELAY);

            // Close drawer
            closeDrawer();
            Thread.sleep(SHORT_DELAY);
        } else {
            Log.w(TAG, "No sites found in drawer");
            // Close drawer
            closeDrawer();
            Thread.sleep(SHORT_DELAY);
        }

        // Try to navigate to webspaces list via drawer buttons (no hamburger when drawer is open)
        Log.d(TAG, "Opening drawer to navigate to webspaces");
        openDrawer();
        Thread.sleep(QUICK_DELAY);

        UiObject2 webspacesButton = findElement("Back to Webspaces");
        if (webspacesButton == null) {
            webspacesButton = findElement("Webspaces");
        }
        if (webspacesButton == null) {
            webspacesButton = findElement("All");
        }

        if (webspacesButton != null) {
            Log.d(TAG, "Navigating to webspaces list");
            webspacesButton.click();
            Log.d(TAG, "Waiting briefly for webspaces list to refresh...");
            Thread.sleep(SHORT_DELAY);

            // Look for "Work" webspace - if found, capture it for screenshots 05-06
            UiObject2 workWebspace = findElement("Work");
            if (workWebspace != null) {
                Log.d(TAG, "Work webspace found - capturing screenshots");
                Log.d(TAG, "Selecting Work webspace");
                workWebspace.click();
                Log.d(TAG, "Waiting for Work webspace to load and site icons to render...");
                Thread.sleep(QUICK_DELAY);

                // Screenshot 5: Work webspace sites
                Screengrab.screenshot("05-work-webspace");
                Thread.sleep(MEDIUM_DELAY);
                Thread.sleep(LONG_DELAY);
                Thread.sleep(ICON_LOAD_DELAY);  // Extra time for site icons to load

                // Open drawer
                Log.d(TAG, "Opening drawer for Work webspace");
                openDrawer();
                Thread.sleep(QUICK_DELAY);

                // Screenshot 6: Work webspace drawer
                Screengrab.screenshot("06-work-sites-drawer");
                Thread.sleep(SHORT_DELAY);

                // Close drawer
                closeDrawer();
                Thread.sleep(SHORT_DELAY);

                // Navigate back to webspaces list (drawer already open on selection)
                Log.d(TAG, "Navigating back to webspaces list");
                if (!isDrawerOpen()) {
                    openDrawer();
                    Thread.sleep(QUICK_DELAY);
                }
                UiObject2 backToWebspaces = findElement("Back to Webspaces");
                if (backToWebspaces == null) {
                    backToWebspaces = findElement("Webspaces");
                }
                if (backToWebspaces == null) {
                    backToWebspaces = findElement("All");
                }
                if (backToWebspaces != null) {
                    backToWebspaces.click();
                    Log.d(TAG, "Waiting briefly for webspaces list to refresh...");
                    Thread.sleep(SHORT_DELAY);
                } else {
                    Log.w(TAG, "Could not find webspaces button, pressing back");
                    device.pressBack();
                    Thread.sleep(MEDIUM_DELAY);
                }
            } else {
                Log.w(TAG, "Work webspace not found - skipping Work screenshots");
            }

            // ALWAYS demonstrate workspace creation (regardless of whether Work was found)
            Log.d(TAG, "Starting workspace creation demonstration...");
            Log.d(TAG, "Looking for add workspace button...");
            UiObject2 addButton = findElement("Add Webspace");
            if (addButton == null) {
                addButton = findElement("Add");
            }
            if (addButton == null) {
                addButton = findElement("+");
            }
            if (addButton == null) {
                addButton = findElement("Create Webspace");
            }
            if (addButton == null) {
                addButton = findElement("New Webspace");
            }

            if (addButton != null) {
                Log.d(TAG, "Found add button, clicking...");
                addButton.click();
                Thread.sleep(LONG_DELAY);

                // Screenshot 7: Add workspace dialog
                Log.d(TAG, "Capturing add workspace dialog");
                Screengrab.screenshot("07-add-workspace-dialog");
                Thread.sleep(SHORT_DELAY);

                // Try to find and fill name field
                Log.d(TAG, "Looking for workspace name field...");
                UiObject2 nameField = findElement("Workspace name");
                if (nameField == null) {
                    nameField = findElement("Name");
                }
                if (nameField == null) {
                    // Try to find EditText
                    nameField = device.findObject(By.clazz("android.widget.EditText"));
                }

                if (nameField != null) {
                    Log.d(TAG, "Found name field, entering text...");
                    nameField.click();
                    Thread.sleep(SHORT_DELAY);
                    nameField.setText("Entertainment");
                    Thread.sleep(SHORT_DELAY);

                    // Hide keyboard
                    device.pressBack();
                    Thread.sleep(SHORT_DELAY);

                    // Screenshot 8: Workspace with name entered
                    Log.d(TAG, "Capturing workspace name entered");
                    Screengrab.screenshot("08-workspace-name-entered");
                    Thread.sleep(SHORT_DELAY);

                    // Try to find site selection area (might be checkboxes or list)
                    Log.d(TAG, "Looking for site selection elements...");
                    // Look for a few sites to select
                    UiObject2 redditCheck = findElement("Reddit");
                    if (redditCheck != null) {
                        Log.d(TAG, "Selecting Reddit...");
                        redditCheck.click();
                        Thread.sleep(SHORT_DELAY);
                    }

                    UiObject2 wikipediaCheck = findElement("Wikipedia");
                    if (wikipediaCheck != null) {
                        Log.d(TAG, "Selecting Wikipedia...");
                        wikipediaCheck.click();
                        Thread.sleep(SHORT_DELAY);
                    }

                    // Screenshot 9: Sites selected
                    Log.d(TAG, "Capturing sites selected");
                    Screengrab.screenshot("09-workspace-sites-selected");
                    Thread.sleep(SHORT_DELAY);

                    // Try to find and click save/create button
                    Log.d(TAG, "Looking for save button...");
                    UiObject2 saveButton = findElement("Save");
                    if (saveButton == null) {
                        saveButton = findElement("Create");
                    }
                    if (saveButton == null) {
                        saveButton = findElement("Done");
                    }
                    if (saveButton == null) {
                        saveButton = findElement("OK");
                    }

                    if (saveButton != null) {
                        Log.d(TAG, "Found save button, clicking...");
                        saveButton.click();
                        Log.d(TAG, "Waiting for new workspace to be created...");
                        Thread.sleep(LONG_DELAY);
                        Thread.sleep(SHORT_DELAY);

                        // Screenshot 10: New workspace in list
                        Log.d(TAG, "Capturing webspaces list with new workspace");
                        Screengrab.screenshot("10-new-workspace-created");
                        Thread.sleep(SHORT_DELAY);
                    } else {
                        Log.w(TAG, "Could not find save button");
                    }
                } else {
                    Log.w(TAG, "Could not find name field");
                }
            } else {
                Log.w(TAG, "Could not find add workspace button");
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
        Log.d(TAG, "Opening drawer via menu button...");
        UiObject2 menuButton = device.findObject(By.desc("Open navigation menu"));
        if (menuButton != null) {
            menuButton.click();
        } else {
            Log.w(TAG, "Menu button not found, falling back to swipe");
            swipeFromLeftEdge();
        }
        Thread.sleep(DRAWER_OPEN_DELAY);

        // Check if drawer is open by looking for drawer-specific elements
        // The drawer should show site names or navigation items
        Log.d(TAG, "Checking if drawer opened...");
        return isDrawerOpen();
    }

    private void closeDrawer() throws Exception {
        Log.d(TAG, "Closing drawer via back button...");
        device.pressBack();
        Thread.sleep(DRAWER_OPEN_DELAY);
    }

    private boolean isDrawerOpen() {
        UiObject2 drawerIndicator = findElement("DuckDuckGo");
        if (drawerIndicator == null) {
            drawerIndicator = findElement("Piped");
        }
        if (drawerIndicator == null) {
            drawerIndicator = findElement("GitHub");
        }
        if (drawerIndicator == null) {
            drawerIndicator = findElement("Reddit");
        }

        boolean isOpen = drawerIndicator != null;

        if (!isOpen) {
            Log.w(TAG, "Drawer verification failed - no site names found. Logging visible elements:");
            logVisibleText();
        } else {
            Log.d(TAG, "Drawer verified open - found expected elements");
        }

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
        String[] expectedTexts = {"All", "Work", "Privacy", "Social", "DuckDuckGo", "GitHub", "Reddit"};
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

    /**
     * Dump all UI elements with text or content descriptions for debugging
     */
    private void dumpAllElements() {
        try {
            Log.d(TAG, "=== FULL UI DUMP ===");

            // Find all TextViews
            List<UiObject2> textViews = device.findObjects(By.clazz("android.widget.TextView"));
            Log.d(TAG, "TextViews found: " + textViews.size());
            for (int i = 0; i < Math.min(textViews.size(), 50); i++) {
                UiObject2 element = textViews.get(i);
                String text = element.getText();
                if (text != null && !text.trim().isEmpty()) {
                    Log.d(TAG, "  TextView[" + i + "]: \"" + text + "\"");
                }
            }

            // Find all Buttons
            List<UiObject2> buttons = device.findObjects(By.clazz("android.widget.Button"));
            Log.d(TAG, "Buttons found: " + buttons.size());
            for (int i = 0; i < Math.min(buttons.size(), 20); i++) {
                UiObject2 element = buttons.get(i);
                String text = element.getText();
                if (text != null) {
                    Log.d(TAG, "  Button[" + i + "]: \"" + text + "\"");
                }
            }

            // Find all elements with content descriptions (Flutter often uses these)
            List<UiObject2> allElements = device.findObjects(By.clazz("android.view.View"));
            int descCount = 0;
            for (UiObject2 element : allElements) {
                String desc = element.getContentDescription();
                if (desc != null && !desc.trim().isEmpty()) {
                    Log.d(TAG, "  View[" + descCount + "] desc=\"" + desc + "\"");
                    descCount++;
                    if (descCount >= 50) break;
                }
            }
            Log.d(TAG, "Views with content descriptions: " + descCount);

            Log.d(TAG, "=== END UI DUMP ===");
        } catch (Exception e) {
            Log.e(TAG, "Error dumping UI elements: " + e.getMessage());
        }
    }
}
