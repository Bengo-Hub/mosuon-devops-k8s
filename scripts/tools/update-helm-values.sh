#!/bin/bash
set -euo pipefail

# Centralized script to aggressively update Helm application image tags
# Usage: ./scripts/tools/update-helm-values.sh <app-name> <new-tag>

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <app-name> <new-tag>"
    echo "Example: $0 game-stats-api abc123def"
    exit 1
fi

APP_NAME=$1
NEW_TAG=$2
VALUES_FILE="apps/${APP_NAME}/values.yaml"

if [ ! -f "$VALUES_FILE" ]; then
    echo "Error: Values file $VALUES_FILE not found."
    exit 1
fi

echo "Updating $APP_NAME image tag to $NEW_TAG in $VALUES_FILE..."

# Safely replace the tag under the 'image:' block
sed -i "s/tag: \".*\"/tag: \"$NEW_TAG\"/" "$VALUES_FILE"

# Verify change
if grep -q "tag: \"$NEW_TAG\"" "$VALUES_FILE"; then
    echo "Successfully updated $VALUES_FILE"
else
    echo "Warning: Failed to update or verify tag in $VALUES_FILE"
    exit 1
fi
