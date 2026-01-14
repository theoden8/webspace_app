package org.codeberg.theoden8.webspace;

import androidx.test.ext.junit.rules.ActivityScenarioRule;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.filters.LargeTest;

import org.junit.ClassRule;
import org.junit.Rule;
import org.junit.Test;
import org.junit.runner.RunWith;

import tools.fastlane.screengrab.Screengrab;
import tools.fastlane.screengrab.UiAutomatorScreenshotStrategy;
import tools.fastlane.screengrab.locale.LocaleTestRule;

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
    public void takeScreenshots() throws InterruptedException {
        // Configure screenshot strategy
        Screengrab.setDefaultScreenshotStrategy(new UiAutomatorScreenshotStrategy());

        // Wait for app to fully load
        Thread.sleep(3000);

        // Screenshot 1: Main screen
        Screengrab.screenshot("01-main-screen");

        // Wait for any animations
        Thread.sleep(1000);

        // Screenshot 2: Additional screens as needed
        // Add more screenshots based on your app's features
        // Example:
        // UiDevice device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation());
        // UiObject button = device.findObject(new UiSelector().text("Button Text"));
        // if (button.exists()) {
        //     button.click();
        //     Thread.sleep(1000);
        //     Screengrab.screenshot("02-second-screen");
        // }

        // Screenshot 3: Add more as needed
        // Screengrab.screenshot("03-third-screen");
    }
}
