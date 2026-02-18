<#
.SYNOPSIS
  Generate or use existing SSH key, upload public key to VPS, add known_hosts and SSH config entry.

.PARAMETER VpsHost
  VPS host or IP (default: 207.180.237.35)
.PARAMETER VpsUser
  Remote SSH user (default: root)
.PARAMETER KeyPath
  Local private key path (default: $HOME/.ssh/id_ed25519)
.PARAMETER Alias
  SSH config alias to create (default: mosuon-prod)

.EXAMPLE
  .\setup-ssh-access.ps1
  .\setup-ssh-access.ps1 -KeyPath "$env:USERPROFILE\.ssh\id_ed25519" -VpsHost 207.180.237.35
#>
param(
  [string]$VpsHost = '207.180.237.35',
  [string]$VpsUser = 'root',
  [string]$KeyPath = "$env:USERPROFILE\.ssh\id_ed25519",
  [string]$Alias = 'mosuon-prod'
)

Set-StrictMode -Version Latest

function Ensure-Dir([string]$p) {
  if (-not (Test-Path -Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
}

# Ensure .ssh exists
$sshDir = Join-Path $env:USERPROFILE '.ssh'
Ensure-Dir $sshDir

# Expand key paths
$privateKey = (Resolve-Path -LiteralPath $KeyPath -ErrorAction SilentlyContinue) -or $KeyPath
$publicKey = "$KeyPath.pub"

if (-not (Test-Path -Path $publicKey)) {
  Write-Host "Public key not found at $publicKey. Generating new ed25519 keypair..." -ForegroundColor Yellow
  $comment = "$env:USERNAME@$env:COMPUTERNAME"
  $argString = "-t ed25519 -f `"$KeyPath`" -N '' -C `"$comment`""
  Write-Host "Running: ssh-keygen $argString"
  $p = Start-Process -FilePath ssh-keygen -ArgumentList $argString -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue
  if ($p -and $p.ExitCode -eq 0) {
    Write-Host "SSH key generated: $KeyPath" -ForegroundColor Green
  } else {
    # Fallback to cmd invocation
    Write-Host "Primary method failed — trying fallback generation via cmd /c" -ForegroundColor Yellow
    $cmd = "ssh-keygen -t ed25519 -f \"$KeyPath\" -N \"\" -C \"$comment\""
    cmd /c $cmd
    if (-not (Test-Path "$publicKey")) { throw 'ssh-keygen fallback failed (no public key written)' }
    Write-Host "SSH key generated (fallback): $KeyPath" -ForegroundColor Green
  }
}

# Read public key
$pub = Get-Content -Raw -Path $publicKey
if (-not $pub) { throw 'Failed to read public key' }

# Upload public key to VPS (appends to authorized_keys)
Write-Host "Uploading public key to $VpsUser@$VpsHost (you may be prompted for the VPS password)..." -ForegroundColor Cyan
$sshCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
# Use OpenSSH's ssh with stdin public key
$pub | ssh $VpsUser@$VpsHost $sshCmd
if ($LASTEXITCODE -ne 0) { throw 'Failed to upload public key to VPS' }
Write-Host "Public key uploaded to VPS" -ForegroundColor Green

# Add host to known_hosts (ssh-keyscan preferred)
$knownHosts = Join-Path $sshDir 'known_hosts'
if (Get-Command ssh-keyscan -ErrorAction SilentlyContinue) {
  ssh-keyscan -H $VpsHost 2>$null | Out-File -Append -Encoding ascii $knownHosts
  Write-Host "Added $VpsHost to $knownHosts (ssh-keyscan)" -ForegroundColor Green
} else {
  # Fallback: do a one-shot connection to accept-new host key
  Write-Host "ssh-keyscan not available; adding host key via ssh (Accept-new)" -ForegroundColor Yellow
  try {
    & ssh -o StrictHostKeyChecking=accept-new $VpsUser@$VpsHost exit 2>$null
    Write-Host "Host key registered (if connection succeeded)" -ForegroundColor Green
  } catch {
    Write-Host "ssh accept-new fallback failed (this is harmless if host key already present)" -ForegroundColor Yellow
  }
}

# Append SSH config entry if missing
$configFile = Join-Path $sshDir 'config'
$configEntry = @"
Host $Alias
  HostName $VpsHost
  User $VpsUser
  IdentityFile $KeyPath
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ServerAliveInterval 60
  ServerAliveCountMax 3
"@
$existing = ''
if (Test-Path $configFile) { $existing = Get-Content -Raw -Path $configFile }
if ($existing -notmatch "Host\s+$Alias") {
  Add-Content -Path $configFile -Value $configEntry
  Write-Host "Added SSH config entry for alias '$Alias' -> $VpsHost" -ForegroundColor Green
} else {
  Write-Host "SSH config already contains an entry for '$Alias'" -ForegroundColor Yellow
}

# Ensure ssh-agent is running and add private key
try {
  if ((Get-Service -Name ssh-agent -ErrorAction SilentlyContinue).Status -ne 'Running') { Start-Service ssh-agent }
  ssh-add $privateKey | Out-Null
  Write-Host "Private key added to ssh-agent" -ForegroundColor Green
} catch {
  Write-Host "Could not add key to ssh-agent. You may need to run 'ssh-add $privateKey' manually." -ForegroundColor Yellow
}

Write-Host "SSH setup complete. Test with: ssh $Alias or ssh $VpsUser@$VpsHost" -ForegroundColor Cyan
