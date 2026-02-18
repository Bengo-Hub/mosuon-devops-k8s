<#
.SYNOPSIS
  Push selected secrets from KubeSecrets/devENV.yml into GitHub repository secrets using `gh`.

.DESCRIPTION
  - Reads keys from `KubeSecrets/devENV.yml` (data: section).
  - Maps: KUBECONFIG_B64 -> KUBE_CONFIG (stores base64 string),
          SSH_PRIVATE_KEY_B64 -> SSH_PRIVATE_KEY (decoded),
          VPS_IP -> SSH_HOST (decoded),
          other data keys -> same secret names (decoded).
  - If SSH_PRIVATE_KEY_B64 is empty but a local private key exists at ~/.ssh/id_ed25519,
    the script will set SSH_PRIVATE_KEY from the local private key (confirm required).

.PARAMETER Repo
  GitHub repo to write secrets to (default: Bengo-Hub/mosuon-devops-k8s)

.EXAMPLE
  .\push-devENV-to-gh-secrets.ps1
#>
param(
  [string]$Repo = 'Bengo-Hub/mosuon-devops-k8s',
  [string]$DevEnvPath = 'KubeSecrets/devENV.yml'
)

Set-StrictMode -Version Latest
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'gh CLI is required and not found in PATH' }
if (-not (gh auth status 2>$null)) { throw 'gh CLI is not authenticated. Run `gh auth login` first.' }
if (-not (Test-Path $DevEnvPath)) { throw "devENV file not found: $DevEnvPath" }

$content = Get-Content -Raw -Path $DevEnvPath
# Extract data: section lines matching KEY: VALUE
$dataLines = $content -split "\r?\n" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -match '^[ \t]*[A-Z0-9_]+:\s*"?.*'? } 

# Parse key: value pairs under data:
$map = @{}
foreach ($line in $dataLines) {
  if ($line -match '^[ \t]*([A-Z0-9_]+):\s*"?(.*?)"?$') {
    $k = $matches[1]
    $v = $matches[2]
    $map[$k] = $v
  }
}

function gh-set-secret([string]$name, [string]$value) {
  Write-Host "Setting GitHub secret: $name" -ForegroundColor Cyan
  # gh secret set reads plaintext from stdin when --body - is used
  $value | gh secret set $name --repo $Repo --body - 2>$null
  if ($LASTEXITCODE -ne 0) { Write-Host "Failed to set $name" -ForegroundColor Red; return $false }
  return $true
}

$summary = @()

# KUBE_CONFIG (expects base64 string) — copy as-is from KUBECONFIG_B64 if present
if ($map.ContainsKey('KUBECONFIG_B64') -and $map['KUBECONFIG_B64'].Trim() -ne '') {
  gh-set-secret 'KUBE_CONFIG' $map['KUBECONFIG_B64'] | Out-Null
  $summary += 'KUBE_CONFIG'
} else {
  Write-Host 'KUBECONFIG_B64 not present or empty in devENV.yml; skipping KUBE_CONFIG' -ForegroundColor Yellow
}

# SSH_PRIVATE_KEY: prefer SSH_PRIVATE_KEY_B64 (decode), else use local id_ed25519
if ($map.ContainsKey('SSH_PRIVATE_KEY_B64') -and $map['SSH_PRIVATE_KEY_B64'].Trim() -ne '') {
  $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($map['SSH_PRIVATE_KEY_B64']))
  gh-set-secret 'SSH_PRIVATE_KEY' $decoded | Out-Null; $summary += 'SSH_PRIVATE_KEY'
} else {
  $localKey = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
  if (Test-Path $localKey) {
    Write-Host "Local private key found at $localKey. Setting SSH_PRIVATE_KEY from local key." -ForegroundColor Green
    $pk = Get-Content -Raw -Path $localKey
    gh-set-secret 'SSH_PRIVATE_KEY' $pk | Out-Null; $summary += 'SSH_PRIVATE_KEY (from local)'
  } else { Write-Host 'No SSH_PRIVATE_KEY_B64 in devENV.yml and no local key found; skipping SSH_PRIVATE_KEY' -ForegroundColor Yellow }
}

# SSH_HOST from VPS_IP (base64 decode)
if ($map.ContainsKey('VPS_IP') -and $map['VPS_IP'].Trim() -ne '') {
  try { $sshHost = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($map['VPS_IP'])) } catch { $sshHost = $map['VPS_IP'] }
  gh-set-secret 'SSH_HOST' $sshHost | Out-Null; $summary += 'SSH_HOST'
}

# Generic: set any other data keys present in devENV.yml (decoded)
$skip = @('KUBECONFIG_B64','SSH_PRIVATE_KEY_B64','VPS_IP')
foreach ($k in $map.Keys) {
  if ($skip -contains $k) { continue }
  $v = $map[$k]
  if ($v -eq '') { continue }
  # decode if appears base64 (simple heuristic: only A-Za-z0-9+/= and length > 12)
  if ($v -match '^[A-Za-z0-9+/=]+$' -and $v.Length -ge 8) {
    try { $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($v)); $final = $decoded } catch { $final = $v }
  } else { $final = $v }
  gh-set-secret $k $final | Out-Null; $summary += $k
}

Write-Host "\nSummary: set the following secrets in $Repo:" -ForegroundColor Green
$summary | ForEach-Object { Write-Host "  - $_" }
