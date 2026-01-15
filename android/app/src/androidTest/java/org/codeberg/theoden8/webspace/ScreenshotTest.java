package org.codeberg.theoden8.webspace;

import android.content.Context;
import android.util.Log;

import androidx.test.core.app.ApplicationProvider;
import androidx.test.ext.junit.rules.ActivityScenarioRule;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.filters.LargeTest;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.By;
import androidx.test.uiautomator.UiDevice;
import androidx.test.uiautomator.UiObject;
import androidx.test.uiautomator.UiObject2;
import androidx.test.uiautomator.UiSelector;
import androidx.test.uiautomator.Until;

import org.junit.Before;
import org.junit.ClassRule;
import org.junit.Rule;
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
    private static final int SHORT_DELAY = 1000;
    private static final int MEDIUM_DELAY = 2000;
    private static final int LONG_DELAY = 3000;

    @ClassRule
    public static final LocaleTestRule localeTestRule = new LocaleTestRule();

    @Rule
    public ActivityScenarioRule<MainActivity> activityRule =
            new ActivityScenarioRule<>(MainActivity.class);

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

        // Seed test data
        Context context = ApplicationProvider.getApplicationContext();
        TestDataHelper.seedTestData(context);

        Log.d(TAG, "Setup complete");
    }

    @Test
    public void takeScreenshots() throws Exception {
        Log.d(TAG, "Starting screenshot tour");

        // Wait for app to fully load
        Thread.sleep(LONG_DELAY);

        // Screenshot 1: Webspaces list view
        Log.d(TAG, "Capturing webspaces list");
        Screengrab.screenshot("01-webspaces-list");
        Thread.sleep(SHORT_DELAY);

        // Select "Work" webspace to show sites
        Log.d(TAG, "Selecting Work webspace");
        UiObject2 workWebspace = device.wait(Until.findObject(By.text("Work")), 5000);
        if (workWebspace != null) {
            workWebspace.click();
            Thread.sleep(MEDIUM_DELAY);

            // Screenshot 2: Sites list in drawer (after selecting workspace)
            Log.d(TAG, "Opening drawer to show sites");
            // The drawer should open automatically after selecting a webspace
            // Wait for the drawer to open and sites to load
            Thread.sleep(MEDIUM_DELAY);
            Screengrab.screenshot("02-sites-drawer");
            Thread.sleep(SHORT_DELAY);

            // Select first site to show webview
            Log.d(TAG, "Selecting first site");
            UiObject2 firstSite = device.wait(Until.findObject(By.text("My Blog")), 5000);
            if (firstSite != null) {
                firstSite.click();
                Thread.sleep(LONG_DELAY);

                // Screenshot 3: Site webview
                Log.d(TAG, "Capturing site view");
                Screengrab.screenshot("03-site-webview");
                Thread.sleep(SHORT_DELAY);

                // Open menu to show options
                Log.d(TAG, "Opening menu");
                UiObject2 menuButton = device.wait(Until.findObject(By.desc("More options")), 5000);
                if (menuButton == null) {
                    // Try alternative selector
                    menuButton = device.wait(Until.findObject(By.clazz("android.widget.ImageView").desc("More options")), 3000);
                }
                if (menuButton != null) {
                    menuButton.click();
                    Thread.sleep(SHORT_DELAY);

                    // Screenshot 4: Menu options
                    Log.d(TAG, "Capturing menu options");
                    Screengrab.screenshot("04-site-menu");
                    Thread.sleep(SHORT_DELAY);

                    // Close menu by pressing back
                    device.pressBack();
                    Thread.sleep(SHORT_DELAY);
                }

                // Open drawer again
                Log.d(TAG, "Opening drawer again");
                UiObject2 drawerButton = device.wait(Until.findObject(By.desc("Open navigation drawer")), 5000);
                if (drawerButton == null) {
                    // Try swiping from left edge
                    device.swipe(0, device.getDisplayHeight() / 2, device.getDisplayWidth() / 3, device.getDisplayHeight() / 2, 10);
                } else {
                    drawerButton.click();
                }
                Thread.sleep(MEDIUM_DELAY);

                // Screenshot 5: Drawer with sites
                Log.d(TAG, "Capturing drawer with sites");
                Screengrab.screenshot("05-sites-list-drawer");
                Thread.sleep(SHORT_DELAY);

                // Navigate back to webspaces list
                Log.d(TAG, "Navigating back to webspaces");
                UiObject2 backToWebspaces = device.wait(Until.findObject(By.text("Back to Webspaces")), 5000);
                if (backToWebspaces != null) {
                    backToWebspaces.click();
                    Thread.sleep(MEDIUM_DELAY);

                    // Screenshot 6: Webspaces list again (showing organization)
                    Log.d(TAG, "Capturing webspaces overview");
                    Screengrab.screenshot("06-webspaces-overview");
                    Thread.sleep(SHORT_DELAY);
                }
            }
        }

        // Try to show Add Site screen
        Log.d(TAG, "Opening Add Site screen");
        UiObject2 fab = device.wait(Until.findObject(By.clazz("android.widget.ImageView").desc("Floating action button")), 5000);
        if (fab == null) {
            // Try finding FAB by class
            fab = device.wait(Until.findObject(By.clazz("android.widget.Button")), 3000);
        }
        if (fab != null) {
            fab.click();
            Thread.sleep(MEDIUM_DELAY);

            // Screenshot 7: Add Site screen
            Log.d(TAG, "Capturing Add Site screen");
            Screengrab.screenshot("07-add-site-screen");
            Thread.sleep(SHORT_DELAY);

            // Close the dialog/screen
            device.pressBack();
            Thread.sleep(SHORT_DELAY);
        }

        // Try to show a webspace detail
        Log.d(TAG, "Opening webspace detail");
        UiObject2 homeServerWebspace = device.wait(Until.findObject(By.text("Home Server")), 5000);
        if (homeServerWebspace != null) {
            // Long press or find edit button
            homeServerWebspace.click();
            Thread.sleep(MEDIUM_DELAY);

            // Look for edit icon in the list
            UiObject editIcon = device.findObject(new UiSelector().descriptionContains("Edit"));
            if (editIcon.exists()) {
                editIcon.click();
                Thread.sleep(MEDIUM_DELAY);

                // Screenshot 8: Webspace detail screen
                Log.d(TAG, "Capturing webspace detail");
                Screengrab.screenshot("08-webspace-detail");
                Thread.sleep(SHORT_DELAY);
            }
        }

        Log.d(TAG, "Screenshot tour completed successfully");
    }
}
