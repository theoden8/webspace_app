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
 * This test creates a comprehensive tour of the app's features.
 *
 * To run this test and generate screenshots:
 * 1. From project root: fastlane android screenshots
 * 2. Or from android/: fastlane screenshots
 */
@RunWith(AndroidJUnit4.class)
@LargeTest
public class ScreenshotTest {

    private static final String TAG = "ScreenshotTest";
    private static final int SHORT_DELAY = 1500;
    private static final int MEDIUM_DELAY = 2500;
    private static final int LONG_DELAY = 4000;
    private static final String PACKAGE_NAME = "org.codeberg.theoden8.webspace";

    @ClassRule
    public static final LocaleTestRule localeTestRule = new LocaleTestRule();

    private UiDevice device;

    @Before
    public void setUp() throws Exception {
        Log.d(TAG, "Setting up screenshot test");

        // Get the device instance
        device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation());

        // Wake up the device
        device.wakeUp();

        // Configure screenshot strategy
        Screengrab.setDefaultScreenshotStrategy(new UiAutomatorScreenshotStrategy());

        // Clear existing data and seed test data BEFORE launching the activity
        Context context = ApplicationProvider.getApplicationContext();
        TestDataHelper.clearTestData(context);
        Thread.sleep(500);
        TestDataHelper.seedTestData(context);
        Thread.sleep(500);

        Log.d(TAG, "Test data seeded, now launching activity");

        // Launch the app
        Intent intent = context.getPackageManager().getLaunchIntentForPackage(PACKAGE_NAME);
        if (intent != null) {
            intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK);
            context.startActivity(intent);
        }

        // Wait for app to fully load
        device.wait(Until.hasObject(By.pkg(PACKAGE_NAME).depth(0)), 10000);
        Thread.sleep(LONG_DELAY);

        Log.d(TAG, "========================================");
        Log.d(TAG, "APP LAUNCHED - VERIFYING DATA AGAIN");
        Log.d(TAG, "========================================");
        TestDataHelper.verifyData(context);

        Log.d(TAG, "Setup complete");
    }

    @Test
    public void takeScreenshots() throws Exception {
        Log.d(TAG, "========================================");
        Log.d(TAG, "STARTING SCREENSHOT TOUR");
        Log.d(TAG, "========================================");

        // Log visible text on screen
        Log.d(TAG, "Searching for text elements on screen...");
        logVisibleText();

        // Screenshot 1: Main screen with webspaces or sites
        Log.d(TAG, "Capturing main screen");
        Screengrab.screenshot("01-main-screen");
        Thread.sleep(MEDIUM_DELAY);

        // Look for webspace items (Work, Home Server, Personal)
        Log.d(TAG, "Looking for 'Work' webspace...");
        UiObject2 workWebspace = device.wait(Until.findObject(By.text("Work")), 5000);

        if (workWebspace != null) {
            Log.d(TAG, "Found webspaces, taking webspaces list screenshot");

            // Screenshot 2: Webspaces list view
            Screengrab.screenshot("02-webspaces-list");
            Thread.sleep(SHORT_DELAY);

            // Select "Work" webspace
            Log.d(TAG, "Selecting Work webspace");
            workWebspace.click();
            Thread.sleep(LONG_DELAY);

            // Drawer should open automatically with sites
            Log.d(TAG, "Drawer should be open with sites");

            // Screenshot 3: Sites list in drawer
            Screengrab.screenshot("03-sites-drawer");
            Thread.sleep(SHORT_DELAY);

            // Try to click on first site
            UiObject2 firstSite = device.findObject(By.text("My Blog"));
            if (firstSite == null) {
                firstSite = device.findObject(By.text("Tasks"));
            }

            if (firstSite != null) {
                Log.d(TAG, "Selecting site: " + firstSite.getText());
                firstSite.click();
                Thread.sleep(LONG_DELAY);

                // Screenshot 4: Site view (webview or loading)
                Log.d(TAG, "Capturing site view");
                Screengrab.screenshot("04-site-view");
                Thread.sleep(MEDIUM_DELAY);

                // Try to open drawer again
                Log.d(TAG, "Opening drawer again");
                swipeFromLeftEdge();
                Thread.sleep(MEDIUM_DELAY);

                // Screenshot 5: Drawer with current site highlighted
                Screengrab.screenshot("05-sites-list");
                Thread.sleep(SHORT_DELAY);

                // Try to navigate back to webspaces
                UiObject2 backButton = device.findObject(By.text("Back to Webspaces"));
                if (backButton == null) {
                    backButton = device.findObject(By.text("Webspaces"));
                }

                if (backButton != null) {
                    Log.d(TAG, "Going back to webspaces");
                    backButton.click();
                    Thread.sleep(MEDIUM_DELAY);

                    // Screenshot 6: Webspaces overview
                    Screengrab.screenshot("06-webspaces-overview");
                    Thread.sleep(SHORT_DELAY);
                }
            }
        } else {
            Log.d(TAG, "No webspaces found, app might be showing sites directly");

            // Take screenshot of whatever is showing
            Screengrab.screenshot("02-app-view");

            // Try to open drawer to see if there are sites
            swipeFromLeftEdge();
            Thread.sleep(MEDIUM_DELAY);

            Screengrab.screenshot("03-drawer-view");
        }

        // Try to find and click FAB to show add site screen
        Log.d(TAG, "Looking for FAB to add site");
        UiObject2 fab = findFab();

        if (fab != null) {
            Log.d(TAG, "Found FAB, clicking to add site");
            fab.click();
            Thread.sleep(MEDIUM_DELAY);

            // Screenshot 7: Add site screen
            Screengrab.screenshot("07-add-site");
            Thread.sleep(SHORT_DELAY);

            // Close the dialog
            device.pressBack();
            Thread.sleep(SHORT_DELAY);
        } else {
            Log.d(TAG, "FAB not found");
        }

        Log.d(TAG, "Screenshot tour completed");
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

        // Try by clickable ImageView
        fab = device.findObject(By.clazz("android.widget.ImageView").clickable(true));
        if (fab != null && fab.getContentDescription() != null) return fab;

        // Try finding floating action button specifically
        fab = device.findObject(By.res(PACKAGE_NAME, "fab"));
        if (fab != null) return fab;

        // Try finding any FAB-like button at the bottom right
        fab = device.findObject(By.clazz("android.widget.Button").clickable(true));
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
        for (int i = 0; i < Math.min(textViews.size(), 20); i++) {
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
            Log.d(TAG, "  Button " + i + ": text='" + text + "', desc='" + desc + "'");
        }

        // Check for specific expected text
        String[] expectedTexts = {"Work", "Home Server", "Personal", "All", "My Blog", "Tasks", "Notes"};
        for (String expectedText : expectedTexts) {
            UiObject2 obj = device.findObject(By.text(expectedText));
            Log.d(TAG, "  Looking for '" + expectedText + "': " + (obj != null ? "FOUND" : "NOT FOUND"));
        }
    }
}
