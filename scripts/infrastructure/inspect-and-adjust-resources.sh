#!/usr/bin/env bash
set -euo pipefail

# Inspect cluster node allocatable resources and recommend/patch
# game-stats API/UI resource values in their Helm values.yaml files.
# Usage: ./inspect-and-adjust-resources.sh [--apply]

APPLY=false
for arg in "$@"; do
  case $arg in
    --apply) APPLY=true; shift ;;
    --help|-h) echo "Usage: $0 [--apply]"; exit 0 ;;
  esac
done

KUBECONFIG_ARG=${KUBECONFIG:-"$HOME/.kube/mosuon-config"}
VALUES_API="$(dirname "$0")/../../apps/game-stats-api/values.yaml"
VALUES_UI="$(dirname "$0")/../../apps/game-stats-ui/values.yaml"

if ! kubectl --kubeconfig="$KUBECONFIG_ARG" get nodes >/dev/null 2>&1; then
  echo "ERROR: kubectl cannot reach cluster. Ensure KUBECONFIG is set or pass KUBECONFIG env." >&2
  exit 1
fi

NODE_JSON=$(kubectl --kubeconfig="$KUBECONFIG_ARG" get node -o json | jq '.items[0].status.allocatable')
MEM_ALLOCATABLE=$(echo "$NODE_JSON" | jq -r '.memory')
CPU_ALLOCATABLE=$(echo "$NODE_JSON" | jq -r '.cpu')

# Convert memory to Mi
convert_mem_to_mi() {
  local v="$1"
  if [[ "$v" =~ Ki$ ]]; then
    echo $(( ${v%Ki} / 1024 ))
  elif [[ "$v" =~ Mi$ ]]; then
    echo ${v%Mi}
  elif [[ "$v" =~ Gi$ ]]; then
    echo $(( ${v%Gi} * 1024 ))
  else
    # raw number (assume Ki)
    echo $(( ${v%Ki} / 1024 ))
  fi
}

MEM_MI=$(convert_mem_to_mi "$MEM_ALLOCATABLE")
CPU_M=$(echo "$CPU_ALLOCATABLE" | awk -F. '{print $1*1000 + ($2 ? $2 : 0)}')

# Reserve 30% for system + other services (user requirement: leave room for 2 lightweight services)
RESERVE_PERCENT=30
RESERVE_MEM_MI=$(( MEM_MI * RESERVE_PERCENT / 100 ))
AVAILABLE_MEM_MI=$(( MEM_MI - RESERVE_MEM_MI ))

# Allocation strategy (fraction of available_for_apps)
API_MEM_SHARE_PERCENT=50   # API gets larger share
UI_MEM_SHARE_PERCENT=25    # UI gets moderate share
# remainder ~25% left for other services + buffer

API_REQ_MI=$(( AVAILABLE_MEM_MI * API_MEM_SHARE_PERCENT / 100 ))
API_LIMIT_MI=$(( API_REQ_MI * 3 ))
UI_REQ_MI=$(( AVAILABLE_MEM_MI * UI_MEM_SHARE_PERCENT / 100 ))
UI_LIMIT_MI=$(( UI_REQ_MI * 3 ))

# Minimum floor values (do not reduce below current values in values.yaml)
MIN_API_REQ=256
MIN_API_LIMIT=768
MIN_UI_REQ=128
MIN_UI_LIMIT=512

if (( API_REQ_MI < MIN_API_REQ )); then API_REQ_MI=$MIN_API_REQ; fi
if (( API_LIMIT_MI < MIN_API_LIMIT )); then API_LIMIT_MI=$MIN_API_LIMIT; fi
if (( UI_REQ_MI < MIN_UI_REQ )); then UI_REQ_MI=$MIN_UI_REQ; fi
if (( UI_LIMIT_MI < MIN_UI_LIMIT )); then UI_LIMIT_MI=$MIN_UI_LIMIT; fi

printf "\nCluster allocatable (node[0]): %s Mi memory, %s mCPU\n" "$MEM_MI" "$CPU_M"
printf "Reserved for system/other: %s Mi (%s%%)\n" "$RESERVE_MEM_MI" "$RESERVE_PERCENT"
printf "Available for apps: %s Mi\n\n" "$AVAILABLE_MEM_MI"

printf "Recommended game-stats-api resources:\n  requests.memory: %sMi\n  limits.memory:   %sMi\n\n" "$API_REQ_MI" "$API_LIMIT_MI"
printf "Recommended game-stats-ui resources:\n  requests.memory: %sMi\n  limits.memory:   %sMi\n\n" "$UI_REQ_MI" "$UI_LIMIT_MI"

if [ "$APPLY" = true ]; then
  echo "Applying recommendations to values.yaml files..."
  if command -v yq >/dev/null 2>&1; then
    # Update API
    yq -i ".resources.requests.memory = \"${API_REQ_MI}Mi\" | .resources.limits.memory = \"${API_LIMIT_MI}Mi\"" "$VALUES_API"
    # Update UI
    yq -i ".resources.requests.memory = \"${UI_REQ_MI}Mi\" | .resources.limits.memory = \"${UI_LIMIT_MI}Mi\"" "$VALUES_UI"
    echo "✅ values.yaml files updated (via yq)"
  else
    # Fallback: sed replacement (simple, looks for the first occurrences)
    sed -i "0,/^  requests:/s//  requests:\n    memory: \"${API_REQ_MI}Mi\"/" "$VALUES_API" || true
    sed -i "0,/^  limits:/s//  limits:\n    memory: \"${API_LIMIT_MI}Mi\"/" "$VALUES_API" || true

    sed -i "0,/^  requests:/s//  requests:\n    memory: \"${UI_REQ_MI}Mi\"/" "$VALUES_UI" || true
    sed -i "0,/^  limits:/s//  limits:\n    memory: \"${UI_LIMIT_MI}Mi\"/" "$VALUES_UI" || true
    echo "⚠️  Updated values.yaml using sed fallback — install 'yq' for safer edits"
  fi
  echo "Done. Please review and commit changes to Git." 
else
  echo "Run with --apply to write these recommendations into the Helm values.yaml files."
fi

exit 0
