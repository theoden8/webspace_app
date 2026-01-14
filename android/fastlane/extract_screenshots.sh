#!/bin/bash
# Script to extract screenshots from Android internal storage
# This is needed on Android 13+ where Screengrab can't access external storage

set -e

PACKAGE="org.codeberg.theoden8.webspace"
TEMP_DIR="/data/local/tmp/screenshots_temp"
OUTPUT_DIR="./android/fastlane/metadata/android/en-US/images/phoneScreenshots"

echo "Extracting screenshots from internal storage..."

# Create temp directory on device
adb shell "mkdir -p $TEMP_DIR"

# Copy screenshots from app's private storage to temp location
echo "Copying screenshots to accessible location..."
adb shell "run-as $PACKAGE tar -czf $TEMP_DIR/screenshots.tar.gz -C app_screengrab ." || {
    echo "Error: Failed to create archive. Make sure screenshots were captured."
    exit 1
}

# Pull the archive
echo "Pulling screenshots..."
adb pull "$TEMP_DIR/screenshots.tar.gz" /tmp/screenshots.tar.gz

# Extract to output directory
echo "Extracting to $OUTPUT_DIR..."
mkdir -p "$OUTPUT_DIR"
tar -xzf /tmp/screenshots.tar.gz -C "$OUTPUT_DIR"

# Clean up
echo "Cleaning up..."
adb shell "rm -rf $TEMP_DIR"
rm /tmp/screenshots.tar.gz

echo ""
echo "✅ Screenshots extracted successfully to:"
echo "   $OUTPUT_DIR"
echo ""
ls -lh "$OUTPUT_DIR"
