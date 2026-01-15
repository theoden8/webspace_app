package org.codeberg.theoden8.webspace;

import android.os.Build;
import android.util.Log;

import androidx.test.ext.junit.rules.ActivityScenarioRule;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.filters.LargeTest;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.UiDevice;

import org.junit.ClassRule;
import org.junit.Rule;
import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.File;

import tools.fastlane.screengrab.Screengrab;
import tools.fastlane.screengrab.UiAutomatorScreenshotStrategy;
import tools.fastlane.screengrab.locale.LocaleTestRule;
import tools.fastlane.screengrab.file.FileWritingScreenshotCallback;

/**
 * Screenshot test for generating F-Droid and Play Store screenshots.
 *
 * To run this test and generate screenshots:
 * 1. From project root: fastlane android screenshots
 * 2. Or from android/: fastlane screenshots
 */
@RunWith(AndroidJUnit4.class)
@LargeTest
public class ScreenshotTest {

    @ClassRule
    public static final LocaleTestRule localeTestRule = new LocaleTestRule();

    @Rule
    public ActivityScenarioRule<MainActivity> activityRule =
            new ActivityScenarioRule<>(MainActivity.class);

    @Test
    public void takeScreenshots() throws Exception {
        Log.d("ScreenshotTest", "Starting screenshot test");

        // Get the device instance
        UiDevice device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation());

        // Wake up the device
        device.wakeUp();

        // Configure screenshot strategy with custom storage location
        // Try to use /sdcard path which Fastlane can access more easily
        try {
            File screenshotDir;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Android 10+ - use app-specific external storage
                File externalFilesDir = InstrumentationRegistry.getInstrumentation()
                        .getTargetContext().getExternalFilesDir(null);
                screenshotDir = new File(externalFilesDir, "screengrab");
            } else {
                // Pre-Android 10 - use legacy external storage
                screenshotDir = new File("/sdcard/" + InstrumentationRegistry.getInstrumentation()
                        .getTargetContext().getPackageName() + "/screengrab");
            }

            screenshotDir.mkdirs();
            Log.d("ScreenshotTest", "Screenshot directory: " + screenshotDir.getAbsolutePath());

            Screengrab.setDefaultScreenshotStrategy(
                new UiAutomatorScreenshotStrategy(
                    screenshotDir,
                    new FileWritingScreenshotCallback(screenshotDir)
                )
            );
        } catch (Exception e) {
            Log.e("ScreenshotTest", "Failed to set custom directory, using default", e);
            Screengrab.setDefaultScreenshotStrategy(new UiAutomatorScreenshotStrategy());
        }

        Log.d("ScreenshotTest", "Screenshot strategy configured");

        // Wait for app to fully load
        Thread.sleep(5000);
        Log.d("ScreenshotTest", "App should be loaded");

        // Screenshot 1: Main screen
        Log.d("ScreenshotTest", "Taking screenshot 01-main-screen");
        Screengrab.screenshot("01-main-screen");
        Log.d("ScreenshotTest", "Screenshot 01-main-screen captured");

        // Wait for any animations
        Thread.sleep(1000);

        // Screenshot 2: Additional screens as needed
        // Add more screenshots based on your app's features
        // Example:
        // UiObject button = device.findObject(new UiSelector().text("Button Text"));
        // if (button.exists()) {
        //     button.click();
        //     Thread.sleep(1000);
        //     Screengrab.screenshot("02-second-screen");
        // }

        // Screenshot 3: Add more as needed
        // Screengrab.screenshot("03-third-screen");

        Log.d("ScreenshotTest", "Screenshot test completed");
    }
}
