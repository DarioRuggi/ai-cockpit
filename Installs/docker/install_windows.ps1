# =============================================================================
# AI Cockpit - Windows one-click installer (PowerShell, run as Administrator).
#
# Automates the Windows/WSL2 side of the Setup Guide's manual section -
# NOT a one-click full installer. What it actually does:
#   1. Enable/install WSL2 + Ubuntu-24.04
#   2. Create the Linux user UNATTENDED (skips WSL's normal interactive
#      first-run username/password wizard - generates a random password,
#      shows it to you once at the end)
#   3. Install VS Code (if missing) + the Remote-WSL extension, so editing
#      project files with native Windows tooling works out of the box
#   4. Print the exact next steps to run install_cockpit.sh yourself inside
#      WSL - this script does NOT download the bundle or invoke it for you
#
# Run from an elevated PowerShell:  .\install_windows.ps1
# =============================================================================

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
$DistroName = "Ubuntu-24.04"
$LinuxUser  = "cockpit"

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# Launched by double-click / "Run with PowerShell" the console closes the moment the
# script ends, taking every message with it. That launch path passes -File on the
# command line; an interactive `.\install_windows.ps1` does not - so pause only then.
$script:PauseOnExit = (([Environment]::GetCommandLineArgs() -join ' ') -match '-File')
function Finish($code) {
    if ($script:PauseOnExit) { Read-Host "`nPress Enter to close this window" | Out-Null }
    exit $code
}

# wsl.exe writes UTF-16 to a pipe. Captured through PowerShell 5.1 the text arrives
# with a NUL after every character, so `-match "Ubuntu-24.04"` never matches and a
# perfectly good install looked unregistered (seen on Windows 11 25H2). Strip them.
function WslList { ((wsl --list --quiet 2>$null) -join "`n") -replace "`0", "" }
# Any unhandled error (ErrorActionPreference=Stop) still gets a readable exit.
trap { Write-Host "`nERROR: $_" -ForegroundColor Red; Finish 1 }

# -- 0. Windows build check --------------------------------------------------
# WSL2 needs Windows 10 1903+ (build 18362). Fail loud here instead of letting
# `wsl --install` fail confusingly three steps later on unsupported machines.
Step "Checking Windows version"
$buildNumber = [System.Environment]::OSVersion.Version.Build
if ($buildNumber -lt 18362) {
    Write-Host "Unsupported Windows version - build $buildNumber (need 18362+, Windows 10 1903 or later)." -ForegroundColor Red
    Write-Host "Update Windows via Windows Update, then re-run this installer." -ForegroundColor Yellow
    Finish 1
}

# -- 1. WSL2 + Ubuntu ---------------------------------------------------------
Step "Checking WSL2"
# A never-initialized WSL install throws instead of returning empty/false -
# `wsl --list` on a machine where the feature was never turned on at all is
# exactly the case this script exists to handle, so it can't be allowed to
# crash the whole script here.
try {
    $wslInstalled = (WslList) -match $DistroName
} catch {
    $wslInstalled = $false
}
if (-not $wslInstalled) {
    Step "Installing WSL2 + $DistroName (this triggers ONE reboot if WSL itself was never enabled before)"
    wsl --install -d $DistroName --no-launch

    # --no-launch has a known failure mode where the distro doesn't actually
    # get registered (invisible in `wsl --list` afterward) - verify it landed
    # instead of silently continuing into a distro that isn't really there.
    Start-Sleep -Seconds 3
    try {
        $verifyInstalled = (WslList) -match $DistroName
    } catch {
        $verifyInstalled = $false
    }
    if (-not $verifyInstalled) {
        Write-Host "WSL reports $DistroName still isn't registered." -ForegroundColor Yellow
        Write-Host "If this is the machine's first-ever WSL install, Windows needs a reboot now." -ForegroundColor Yellow
        Write-Host "After the reboot run this script again - it continues from here (verified on Windows 11 25H2)." -ForegroundColor Yellow
        $ans = Read-Host "Reboot now? [Y/n]"
        if ($ans -eq "" -or $ans -match '^[Yy]') { Restart-Computer -Force }
        Finish 1
    }
} else {
    Write-Host "$DistroName already installed."
}

# -- 2. Unattended Linux user creation ---------------------------------------
# WSL's normal first launch forces an interactive "create a UNIX user" wizard
# inside the terminal. Skipping that entirely: launch as root, create the user
# and a random password non-interactively, set it as the distro's default user.
Step "Creating Linux user '$LinuxUser' (unattended)"
# `id -u` inside WSL exits non-zero when the user doesn't exist - check
# $LASTEXITCODE, not the captured output. Output-truthiness is wrong here:
# a non-empty error string on stderr (redirected to $null) still leaves
# stdout empty either way, so this must key off the actual exit status.
# Stderr text alone is a terminating error under ErrorActionPreference=Stop, so the
# probe is silenced inside bash; only the exit status comes back.
$null = wsl -d $DistroName -u root -- bash -c "id -u $LinuxUser >/dev/null 2>&1" 2>$null
$userExists = ($LASTEXITCODE -eq 0)
if (-not $userExists) {
    # Get-Random is a non-cryptographic PRNG - fine for game loot tables, not
    # for a password. Use the crypto RNG instead.
    $bytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $validChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    $randomPassword = -join ($bytes | ForEach-Object { $validChars[$_ % $validChars.Length] })
    wsl -d $DistroName -u root -- bash -c "useradd -m -s /bin/bash -G sudo $LinuxUser && echo '${LinuxUser}:${randomPassword}' | chpasswd"
    # Merge into /etc/wsl.conf, never overwrite it: Ubuntu's image ships "[boot] systemd=true"
    # there, and Cockpit needs systemd (Apache, Ollama services). Overwriting it silently
    # produced "System has not been booted with systemd" in the installer (Win11 25H2 test).
    wsl -d $DistroName -u root -- bash -c "touch /etc/wsl.conf; grep -q '^\[boot\]' /etc/wsl.conf || printf '[boot]\nsystemd=true\n' >> /etc/wsl.conf; grep -q '^systemd=' /etc/wsl.conf || sed -i 's/^\[boot\]/[boot]\nsystemd=true/' /etc/wsl.conf; grep -q '^\[user\]' /etc/wsl.conf || printf '[user]\ndefault=$LinuxUser\n' >> /etc/wsl.conf"
    Write-Host ""
    Write-Host "Linux account created:" -ForegroundColor Green
    Write-Host "  username: $LinuxUser"
    Write-Host "  password: $randomPassword"
    Write-Host "(Only used for sudo prompts inside WSL - write it down, it won't be shown again.)" -ForegroundColor Yellow
} else {
    Write-Host "User '$LinuxUser' already exists - skipping."
}
# %USERPROFILE%\.wslconfig, two keys (Windows 11 22H2+; older builds ignore them):
#  vmIdleTimeout=-1       WSL otherwise stops the distro ~60 s after the last terminal
#                         closes, taking Apache and Cockpit with it ("localhost refused").
#  networkingMode=mirrored  in the default NAT mode Apache's port was forwarded on
#                         [::1] only; Edge/Chrome dial 127.0.0.1 and got "refused".
#                         Mirrored mode shares Windows' network stack: localhost just works.
# Takes effect at the next full WSL restart (wsl --shutdown) - done right here.
$wslcfg = Join-Path $HOME ".wslconfig"
$cfgText = if (Test-Path $wslcfg) { Get-Content $wslcfg -Raw } else { "" }
if ($cfgText -notmatch "(?m)^\[wsl2\]") { $cfgText = "[wsl2]`r`n" + $cfgText }
foreach ($kv in @("vmIdleTimeout=-1", "networkingMode=mirrored")) {
    $key = $kv.Split("=")[0]
    if ($cfgText -notmatch "(?m)^\s*$key\s*=") { $cfgText = $cfgText -replace "(?m)^\[wsl2\]", "[wsl2]`r`n$kv" }
}
Set-Content -Path $wslcfg -Value $cfgText -Encoding ASCII
Write-Host "WSL settings in ${wslcfg}: vmIdleTimeout=-1, networkingMode=mirrored"
wsl --shutdown    # apply .wslconfig + wsl.conf; the distro restarts on next use

# -- 3. VS Code + WSL Remote extension ---------------------------------------
Step "Checking VS Code"
$codePath = Get-Command code -ErrorAction SilentlyContinue
if (-not $codePath) {
    Write-Host "Installing VS Code via winget..."
    winget install --id Microsoft.VisualStudioCode -e --source winget --accept-package-agreements --accept-source-agreements

    # winget updates the registry PATH, not this session's $env:PATH - on a
    # machine where VS Code was never installed before, `code` won't resolve
    # here otherwise, even though the install itself just succeeded.
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
} else {
    Write-Host "VS Code already installed."
}

Step "Installing the WSL Remote extension"
code --install-extension ms-vscode-remote.remote-wsl --force

# -- 3b. Windows shortcuts: Start menu + Desktop "AI Cockpit" ----------------
# Opens the Cockpit window (WebKitGTK under WSLg) through wsl.exe; cockpit-start
# exists once install_cockpit.sh has run inside the distro. The .lnk starts
# wsl.exe minimised so no console window flashes. Pin it to the taskbar if you like.
Step "Windows shortcuts"
$iconDir = Join-Path $env:LOCALAPPDATA "AICockpit"
New-Item -ItemType Directory -Force -Path $iconDir | Out-Null
$icoSrc = Join-Path $PSScriptRoot "web\ai-cockpit.ico"
$ico = Join-Path $iconDir "ai-cockpit.ico"
if (Test-Path $icoSrc) { Copy-Item $icoSrc $ico -Force }
$wsh = New-Object -ComObject WScript.Shell
foreach ($dir in @([Environment]::GetFolderPath("Programs"), [Environment]::GetFolderPath("Desktop"))) {
    $lnk = $wsh.CreateShortcut((Join-Path $dir "AI Cockpit.lnk"))
    $lnk.TargetPath = "$env:SystemRoot\System32\wsl.exe"
    $lnk.Arguments = "-d $DistroName -- bash -lc cockpit-start"
    $lnk.WorkingDirectory = $env:USERPROFILE
    $lnk.Description = "AI Cockpit (runs inside WSL: $DistroName)"
    $lnk.WindowStyle = 7    # minimised: the wsl.exe console stays out of the way
    if (Test-Path $ico) { $lnk.IconLocation = "$ico,0" }
    $lnk.Save()
}
Write-Host "Shortcuts: Start menu > AI Cockpit, and on the Desktop."

# -- 4. Print manual next steps - Cockpit itself installs inside WSL ---------
# This script stops here on purpose. It never touches WSL beyond user/distro
# setup above - it doesn't download the bundle or run install_cockpit.sh for
# you, despite what a "one-click installer" name might imply.
# The bundle is already on disk (this script is inside it) - hand over the exact
# WSL path instead of asking for a second download. Copy into the Linux filesystem:
# /mnt/c is slow and the installer sets Linux ownership/permissions there.
$wslBundle = "/mnt/" + $PSScriptRoot.Substring(0,1).ToLower() + ($PSScriptRoot.Substring(2) -replace "\\", "/")
Step "WSL2 is ready - the Cockpit install itself is a manual step from here"
Write-Host @"

Next steps (this script only sets up the Windows/WSL2/VS Code side):

  1. Open the '$DistroName' app from the Start Menu (or run: wsl -d $DistroName)
  2. In that Linux shell, copy the bundle in and run the installer:
       cp -r '$wslBundle' ~/cockpit && cd ~/cockpit && bash install_cockpit.sh
     (same installer as on Linux, no changes needed; sudo password = the one above)
  3. Then open it from the Start menu or Desktop: "AI Cockpit" (its own window, via WSLg).
     A plain browser works too: http://localhost/cockpit/  (http, not https)

To edit project files with VS Code using native tooling (fast, no /mnt/c/
slowdown): in VS Code, press Ctrl+Shift+P -> "WSL: Connect to WSL" -> open
your project folder from inside the '$DistroName' filesystem.

"@ -ForegroundColor White

Finish 0
