#!/usr/bin/env bash
# =============================================================================
# Centralized Helm Values Update Script
# =============================================================================
# Purpose: Update image tag in ArgoCD Application values files and commit to Git
#
# Usage:
#   # Source and use function
#   source ~/mosuon-devops-k8s/scripts/helm/update-values.sh
#   update_helm_values "game-stats-api" "abc12345" "docker.io/codevertex/game-stats-api"
#
#   # Or run directly with environment variables
#   APP_NAME=game-stats-api IMAGE_TAG=abc12345 ./update-values.sh
#
#   # Or CLI mode
#   ./update-values.sh --app game-stats-api --tag abc12345 --repo docker.io/codevertex/game-stats-api
# =============================================================================

set -euo pipefail

# =============================================================================
# LOGGING
# =============================================================================
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Aliases for compatibility
info() { log_info "$1"; }
success() { log_success "$1"; }
warn() { log_warning "$1"; }
error() { log_error "$1"; }

# =============================================================================
# CONFIGURATION
# =============================================================================
DEVOPS_REPO=${DEVOPS_REPO:-"Bengo-Hub/mosuon-devops-k8s"}
DEVOPS_DIR=${DEVOPS_DIR:-"$HOME/mosuon-devops-k8s"}
GIT_EMAIL=${GIT_EMAIL:-"dev@ultimatestats.co.ke"}
GIT_USER=${GIT_USER:-"Mosuon Bot"}

# =============================================================================
# RESOLVE TOKEN
# =============================================================================
resolve_token() {
    local token=""
    if [[ -n "${GH_PAT:-}" ]]; then
        token="${GH_PAT}"
    elif [[ -n "${GIT_TOKEN:-}" ]]; then
        token="${GIT_TOKEN}"
    elif [[ -n "${GIT_SECRET:-}" ]]; then
        token="${GIT_SECRET}"
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
        token="${GITHUB_TOKEN}"
    fi
    echo "$token"
}

# =============================================================================
# MAIN FUNCTION (can be sourced)
# =============================================================================
update_helm_values() {
    local app_name="${1:-${APP_NAME:-}}"
    local image_tag="${2:-${IMAGE_TAG:-}}"
    local image_repo="${3:-${IMAGE_REPO:-}}"
    
    # Validate required parameters
    if [[ -z "$app_name" ]]; then
        log_error "APP_NAME is required"
        return 1
    fi
    
    if [[ -z "$image_tag" ]]; then
        log_error "IMAGE_TAG is required"
        return 1
    fi
    
    local values_file_path="${VALUES_FILE_PATH:-apps/${app_name}/values.yaml}"
    
    log_info "Updating Helm values for ${app_name}"
    log_info "Image tag: ${image_tag}"
    log_info "Values file: ${values_file_path}"
    
    # Clone or update devops repo
    if [[ ! -d "$DEVOPS_DIR" ]]; then
        local token
        token=$(resolve_token)
        local clone_url="https://github.com/${DEVOPS_REPO}.git"
        [[ -n $token ]] && clone_url="https://x-access-token:${token}@github.com/${DEVOPS_REPO}.git"
        
        log_info "Cloning devops repo..."
        git clone "$clone_url" "$DEVOPS_DIR" || { 
            log_error "Failed to clone devops repo"
            return 1
        }
    fi
    
    cd "$DEVOPS_DIR"
    
    # Ensure we have the latest
    local token
    token=$(resolve_token)
    if [[ -n "$token" ]]; then
        git remote set-url origin "https://x-access-token:${token}@github.com/${DEVOPS_REPO}.git"
    fi
    
    git fetch origin main 2>/dev/null || true
    git checkout main 2>/dev/null || true
    git pull origin main 2>/dev/null || log_warning "Failed to pull latest changes"
    
    # Update image tag in values.yaml
    local values_file="${DEVOPS_DIR}/${values_file_path}"
    if [[ ! -f "$values_file" ]]; then
        log_error "Values file not found: $values_file"
        return 1
    fi
    
    log_info "Updating image tag in ${values_file}"
    
    # Update tag
    yq eval ".image.tag = \"${image_tag}\"" -i "$values_file"
    
    # Update repository if provided
    if [[ -n "$image_repo" ]]; then
        yq eval ".image.repository = \"${image_repo}\"" -i "$values_file"
    fi
    
    # Commit and push
    git config user.email "$GIT_EMAIL"
    git config user.name "$GIT_USER"
    git add "$values_file"
    
    if git diff --staged --quiet; then
        log_info "No changes to commit"
        return 0
    fi
    
    git commit -m "chore(${app_name}): update image tag to ${image_tag}"
    
    git push origin main || { 
        log_error "Failed to push changes"
        return 1
    }
    
    log_success "Helm values updated successfully"
    log_success "ArgoCD will auto-sync deployment"
    return 0
}

# =============================================================================
# CLI MODE
# =============================================================================
# Parse command line arguments if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Parse CLI arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --app)
                APP_NAME="$2"
                shift 2
                ;;
            --tag)
                IMAGE_TAG="$2"
                shift 2
                ;;
            --repo)
                IMAGE_REPO="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [--app NAME] [--tag TAG] [--repo REPOSITORY]"
                echo ""
                echo "Options:"
                echo "  --app   Application name (required)"
                echo "  --tag   Docker image tag (required)"
                echo "  --repo  Docker image repository (optional)"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Run with environment variables or CLI args
    update_helm_values "${APP_NAME:-}" "${IMAGE_TAG:-}" "${IMAGE_REPO:-}"
fi
