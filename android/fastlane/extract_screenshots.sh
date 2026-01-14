#!/bin/bash
# Script to extract screenshots from Android internal storage
# This is needed on Android 13+ where Screengrab can't access external storage

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Project root is two directories up from the script location
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PACKAGE="org.codeberg.theoden8.webspace"
TEMP_FILE="/data/local/tmp/screenshots.tar.gz"
OUTPUT_DIR="$PROJECT_ROOT/fastlane/metadata/android/en-US/images/phoneScreenshots"

# Find adb executable
ADB=""
if command -v adb &> /dev/null; then
    ADB="adb"
elif [ -n "$ANDROID_HOME" ] && [ -f "$ANDROID_HOME/platform-tools/adb" ]; then
    ADB="$ANDROID_HOME/platform-tools/adb"
elif [ -n "$ANDROID_SDK_ROOT" ] && [ -f "$ANDROID_SDK_ROOT/platform-tools/adb" ]; then
    ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
else
    echo "Error: adb not found. Please ensure:"
    echo "  1. Android SDK is installed"
    echo "  2. ANDROID_HOME or ANDROID_SDK_ROOT environment variable is set"
    echo "  3. Or add \$ANDROID_SDK/platform-tools to your PATH"
    exit 1
fi

echo "Using adb: $ADB"
echo "Extracting screenshots from internal storage..."

# Create tar archive in app's private storage (where run-as has permission)
echo "Creating archive in app storage..."
"$ADB" shell "run-as $PACKAGE tar -czf /data/data/$PACKAGE/screenshots.tar.gz -C app_screengrab/en_US/images/screenshots ." || {
    echo "Error: Failed to create archive. Make sure screenshots were captured."
    exit 1
}

# Copy the archive to a location accessible without run-as
echo "Copying archive to accessible location..."
"$ADB" shell "run-as $PACKAGE cat /data/data/$PACKAGE/screenshots.tar.gz" > /tmp/screenshots.tar.gz

# Extract to output directory
echo "Extracting to $OUTPUT_DIR..."
mkdir -p "$OUTPUT_DIR"
# Archive already contains just the screenshot files without directory structure
tar -xzf /tmp/screenshots.tar.gz -C "$OUTPUT_DIR"

# Clean up
echo "Cleaning up..."
"$ADB" shell "run-as $PACKAGE rm /data/data/$PACKAGE/screenshots.tar.gz" 2>/dev/null || true
rm /tmp/screenshots.tar.gz

echo ""
echo "✅ Screenshots extracted successfully to:"
echo "   $OUTPUT_DIR"
echo ""
ls -lh "$OUTPUT_DIR"
