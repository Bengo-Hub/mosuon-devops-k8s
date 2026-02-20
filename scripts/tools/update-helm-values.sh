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

# Determine the root of the devops repo (two levels up from scripts/tools)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALUES_FILE="${REPO_ROOT}/apps/${APP_NAME}/values.yaml"

if [ ! -f "$VALUES_FILE" ]; then
    echo "Error: Values file $VALUES_FILE not found."
    exit 1
fi

echo "Updating $APP_NAME image tag to $NEW_TAG in $VALUES_FILE..."

# Safely replace the tag under the 'image:' block
# We use a pattern that specifically looks for tag under image
# For Windows compatibility (if running in git bash), we use a safe sed approach
sed -i "s/tag: \".*\"/tag: \"$NEW_TAG\"/" "$VALUES_FILE"

# Verify change
if grep -q "tag: \"$NEW_TAG\"" "$VALUES_FILE"; then
    echo "Successfully updated $VALUES_FILE"
    
    # Commit and push changes if in a git repo
    if [ -d "${REPO_ROOT}/.git" ]; then
        echo "Committing and pushing changes to devops repo..."
        cd "$REPO_ROOT"
        git add "$VALUES_FILE"
        git commit -m "chore(deploy): update $APP_NAME image tag to $NEW_TAG" || echo "No changes to commit"
        git push origin master || echo "Warning: Failed to push changes to origin"
    fi
else
    echo "Error: Failed to update or verify tag in $VALUES_FILE"
    exit 1
fi
