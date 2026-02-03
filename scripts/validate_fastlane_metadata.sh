#!/usr/bin/env bash

set -e

METADATA_DIR="fastlane/metadata/android/en-US"
EXIT_CODE=0

echo "Validating Fastlane metadata..."
echo

# Validate short_description.txt
SHORT_DESC_FILE="$METADATA_DIR/short_description.txt"
if [ -f "$SHORT_DESC_FILE" ]; then
    SHORT_DESC=$(cat "$SHORT_DESC_FILE")
    SHORT_DESC_LEN=$(echo -n "$SHORT_DESC" | wc -c)

    echo "Checking short_description.txt..."
    echo "  Length: $SHORT_DESC_LEN characters (max 80)"

    if [ "$SHORT_DESC_LEN" -ge 80 ]; then
        echo "  ERROR: short_description.txt is $SHORT_DESC_LEN characters (must be less than 80)"
        EXIT_CODE=1
    else
        echo "  Length OK"
    fi

    # Check for trailing dot
    if [[ "$SHORT_DESC" =~ \.$ ]]; then
        echo "  ERROR: short_description.txt ends with a dot (trailing dot not allowed)"
        EXIT_CODE=1
    else
        echo "  No trailing dot"
    fi
    echo
else
    echo "ERROR: $SHORT_DESC_FILE not found"
    EXIT_CODE=1
fi

# Validate full_description.txt
FULL_DESC_FILE="$METADATA_DIR/full_description.txt"
if [ -f "$FULL_DESC_FILE" ]; then
    FULL_DESC_LEN=$(wc -c < "$FULL_DESC_FILE")

    echo "Checking full_description.txt..."
    echo "  Length: $FULL_DESC_LEN characters (max 500)"

    if [ "$FULL_DESC_LEN" -gt 500 ]; then
        echo "  ERROR: full_description.txt is $FULL_DESC_LEN characters (must be 500 or less)"
        EXIT_CODE=1
    else
        echo "  Length OK"
    fi
    echo
else
    echo "ERROR: $FULL_DESC_FILE not found"
    EXIT_CODE=1
fi

# Validate changelog files
CHANGELOGS_DIR="$METADATA_DIR/changelogs"
if [ -d "$CHANGELOGS_DIR" ]; then
    echo "Checking changelogs..."
    CHANGELOG_ERROR=0

    for changelog in "$CHANGELOGS_DIR"/*.txt; do
        if [ -f "$changelog" ]; then
            CHANGELOG_LEN=$(wc -c < "$changelog")
            CHANGELOG_NAME=$(basename "$changelog")

            if [ "$CHANGELOG_LEN" -gt 500 ]; then
                echo "  ERROR: $CHANGELOG_NAME is $CHANGELOG_LEN characters (max 500)"
                CHANGELOG_ERROR=1
                EXIT_CODE=1
            else
                echo "  $CHANGELOG_NAME: $CHANGELOG_LEN characters"
            fi
        fi
    done

    if [ "$CHANGELOG_ERROR" -eq 0 ]; then
        echo "  All changelogs OK"
    fi
    echo
fi

if [ "$EXIT_CODE" -eq 0 ]; then
    echo "All fastlane metadata validation checks passed!"
else
    echo "Fastlane metadata validation failed!"
fi

exit $EXIT_CODE
