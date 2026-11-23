# Sets this Windows PC up for sideloading with Impactor and nothing more. Run elevated (it asks for it).
# Impactor needs only Apple's device service (Apple Mobile Device Support, usbmuxd on 127.0.0.1:27015) and Apple's
# USB driver. Apple's driver 552 (Windows Update) crashed in AppleUsbFilter.dll on this PC's chipset USB, so it pins
# 538 from the Microsoft Update Catalog and hides 552 from Windows Update. Safe to run again. Log: next to the script.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) {
  Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"" -Wait
  Get-Content (Join-Path $PSScriptRoot 'windows-sideload.log'); exit
}
$log = Join-Path $PSScriptRoot 'windows-sideload.log'
function L($m) { "$(Get-Date -Format HH:mm:ss) $m" | Tee-Object -FilePath $log -Append }
"=== $(Get-Date -Format s)" | Out-File $log -Encoding utf8
$ProgressPreference = 'SilentlyContinue'
$uninst = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
$installed = Get-ItemProperty $uninst -ErrorAction SilentlyContinue

# 1. What Impactor does not need: the iTunes app (its Mobile Device Support is a product of its own and stays), LocalSend.
foreach ($p in $installed | Where-Object { $_.DisplayName -eq 'iTunes' }) {
  L "uninstall iTunes"; Start-Process msiexec.exe -ArgumentList '/x', $p.PSChildName, '/qn', '/norestart' -Wait
}
foreach ($p in $installed | Where-Object { $_.DisplayName -like 'LocalSend*' -and $_.QuietUninstallString }) {
  L "uninstall LocalSend"; Start-Process cmd.exe -ArgumentList '/c', $p.QuietUninstallString -Wait
}

# 2. Apple's device service must be there and running.
if (-not (Get-Service 'Apple Mobile Device Service' -ErrorAction SilentlyContinue)) {
  L "install Apple Mobile Device Support"
  winget install --id Apple.AppleMobileDeviceSupport -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
}
Set-Service 'Apple Mobile Device Service' -StartupType Automatic; Start-Service 'Apple Mobile Device Service'
L "device service: $((Get-Service 'Apple Mobile Device Service').Status)"

# 3. Apple's USB driver 538 in the driver store (amd64 package from the Microsoft Update Catalog, signed by Microsoft),
#    and no other version of it: a newer one in the store would win over 538 on the next plug-in.
$have538 = $false; $cur = @{}
foreach ($line in (pnputil /enum-drivers) + '') {
  if ($line -match '^\s*(Published Name|Ver.ffentlichter Name)\s*:\s*(\S+)') { $cur = @{ pub = $Matches[2] } }
  elseif ($line -match '^\s*(Original Name|Originalname)\s*:\s*(\S+)') { $cur.orig = $Matches[2] }
  elseif ($line -match '^\s*(Driver Version|Treiberversion)\s*:\s*(.+)$') { $cur.ver = $Matches[2] }
  if ($cur.pub -and $cur.orig -eq 'appleusb.inf' -and $cur.ver -and -not $cur.done) {
    $cur.done = $true
    if ($cur.ver -match '538\.0\.0\.0') { $have538 = $true }
    else { L "remove Apple USB driver $($cur.ver) ($($cur.pub))"; pnputil /delete-driver $cur.pub /uninstall /force | Out-Null }
  }
}
if (-not $have538) {
  $dir = Join-Path $env:TEMP 'apple-usb-538'; Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory $dir | Out-Null
  Invoke-WebRequest -UseBasicParsing -OutFile "$dir\drv.cab" 'https://catalog.s.download.windowsupdate.com/d/msdownload/update/driver/drvs/2023/10/5fb262ea-d52d-46a7-9361-f3260ba57a1a_3e8075a4dded0a795131f82285e2f1a06525ebc2.cab'
  $sig = Get-AuthenticodeSignature "$dir\drv.cab"
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft') { L "driver package signature not valid: stop"; exit 1 }
  New-Item -ItemType Directory "$dir\x" | Out-Null; expand.exe "$dir\drv.cab" -F:* "$dir\x" | Out-Null
  L "add driver 538: $((pnputil /add-driver "$dir\x\AppleUsb.inf" /install | Out-String).Trim() -replace '\s+', ' ')"
} else { L "driver 538 already in the store" }

# 4. Keep Windows Update from swapping 552 back in (it offers it only while an iPhone is plugged in).
$session = New-Object -ComObject Microsoft.Update.Session; $searcher = $session.CreateUpdateSearcher(); $searcher.ServerSelection = 2
foreach ($u in $searcher.Search("IsInstalled=0 and Type='Driver'").Updates) {
  if ($u.Title -match 'Apple' -and $u.Title -notmatch '538') { $u.IsHidden = $true; L "hidden in Windows Update: $($u.Title)" }
}
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_05AC' -and $_.FriendlyName -match 'Composite' } | ForEach-Object {
  L "iPhone/iPad driver: $((Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_DriverVersion).Data)"
}
L "done"
