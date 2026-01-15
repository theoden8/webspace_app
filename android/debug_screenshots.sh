#!/bin/bash
# Debug script for screenshot tests

echo "=== Screenshot Test Debugging ==="
echo ""

# Check if device is connected
echo "1. Checking for connected devices..."
adb devices
echo ""

# Check if app is installed
echo "2. Checking if app is installed..."
adb shell pm list packages | grep webspace || echo "App not found"
echo ""

# Clear logcat and run a simple test
echo "3. Clearing logcat..."
adb logcat -c

echo ""
echo "4. Now run: cd android && bundle exec fastlane screenshots"
echo ""
echo "5. After it fails, run this script with 'check' argument to see logs:"
echo "   ./debug_screenshots.sh check"
echo ""

if [ "$1" == "check" ]; then
    echo "=== Checking logcat for errors ==="
    echo ""

    echo "--- Looking for ScreenshotTest logs ---"
    adb logcat -d | grep "ScreenshotTest" | tail -50
    echo ""

    echo "--- Looking for DEMO_MODE logs ---"
    adb logcat -d | grep -i "demo" | tail -30
    echo ""

    echo "--- Looking for test failures ---"
    adb logcat -d | grep -E "FAILED|ERROR|Exception" | grep -i test | tail -30
    echo ""

    echo "--- Looking for Flutter engine logs ---"
    adb logcat -d | grep "flutter" | tail -30
    echo ""

    echo "=== App state check ==="
    echo "Current activity:"
    adb shell dumpsys window windows | grep -E "mCurrentFocus|mFocusedApp"
    echo ""
fi
