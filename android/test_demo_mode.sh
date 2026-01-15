#!/bin/bash
# Test if DEMO_MODE flag is working

echo "=== Testing DEMO_MODE Flag ==="
echo ""

# Force stop app
echo "1. Force stopping app..."
adb shell am force-stop org.codeberg.theoden8.webspace
sleep 1

# Clear app data
echo "2. Clearing app data..."
adb shell pm clear org.codeberg.theoden8.webspace
sleep 1

# Clear logcat
echo "3. Clearing logcat..."
adb logcat -c

# Launch app with DEMO_MODE flag
echo "4. Launching app with DEMO_MODE=true..."
adb shell am start -n org.codeberg.theoden8.webspace/.MainActivity --ez DEMO_MODE true
sleep 3

# Check logcat for demo data seeding
echo ""
echo "5. Checking logcat for demo data seeding..."
echo "=== Looking for DEMO_MODE flag ==="
adb logcat -d | grep -i "DEMO_MODE"
echo ""
echo "=== Looking for demo data seeding ==="
adb logcat -d | grep -i "SEEDING DEMO DATA\|seedDemoData\|Demo data"
echo ""
echo "=== Looking for Flutter method channel ==="
adb logcat -d | grep -i "app.channel\|getDemoMode"
echo ""
echo "=== All Flutter logs (last 50 lines) ==="
adb logcat -d | grep -E "flutter|Flutter" | tail -50
echo ""

# Check if data was saved
echo "6. Checking if SharedPreferences were written..."
adb shell "run-as org.codeberg.theoden8.webspace ls -la /data/data/org.codeberg.theoden8.webspace/shared_prefs/" 2>/dev/null || echo "Cannot access app data (may need root)"
echo ""

echo "7. Checking SharedPreferences content..."
adb shell "run-as org.codeberg.theoden8.webspace cat /data/data/org.codeberg.theoden8.webspace/shared_prefs/FlutterSharedPreferences.xml" 2>/dev/null | head -30 || echo "Cannot access SharedPreferences (may need root)"
echo ""

echo "=== Test Complete ==="
echo "If you see 'SEEDING DEMO DATA' above, the flag is working."
echo "If not, check the Flutter logs for errors in the method channel."
echo ""
echo "If SharedPreferences contain 'webViewModels' and 'webspaces', demo data was seeded successfully."
