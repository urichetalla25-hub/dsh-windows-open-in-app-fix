<#
.SYNOPSIS
  One-click fix for "Open in VS Code" failures in DeepSeek Harness Desktop on Windows.

.DESCRIPTION
  The DSH desktop shell starts its Host process with ELECTRON_RUN_AS_NODE=1.
  That variable stays in the Host environment and is inherited by every child
  process. The open-in-app launcher only strips credential-like variables, so
  Electron-based targets (VS Code, Cursor, Windsurf) start in Node mode, treat
  the workspace folder as a script, and exit non-zero almost immediately. DSH
  then reports a generic launch failure.

  This script removes that inherited variable at the open-in-app launch site
  only. It patches inside resources\app.asar with a byte-length-preserving
  replacement, so archive offsets stay valid and uninstall can restore exactly.

.PARAMETER DshRoot
  DSH Desktop install folder (the one that contains a "resources" folder).
  Auto-detected when omitted.

.PARAMETER BackupDir
  Where the full original app.asar backup is stored.
  Defaults to %LOCALAPPDATA%\dsh-open-in-app-fix\backups.

.PARAMETER DryRun
  Report what would be done, write nothing.

.NOTES
  No telemetry. No network access. No registry or global environment changes.
#>
[CmdletBinding()]
param(
  [string]$DshRoot,
  [string]$BackupDir,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$PatchOld = '...scrubbedParentEnv(),'
$PatchNew = '...((env) => (delete env.ELECTRON_RUN_AS_NODE, env))(scrubbedParentEnv()),'
$Specs = @(
  'dsh|node_modules|@deepseek-ai|dsh-host-open-in-app|lib|index.js',
  'node_modules|@deepseek-ai|dsh-host-open-in-app|lib|index.js'
)
if (-not $BackupDir) { $BackupDir = Join-Path $env:LOCALAPPDATA 'dsh-open-in-app-fix\backups' }

function Write-Step([string]$Text) { Write-Host "[*] $Text" }
function Write-Ok([string]$Text) { Write-Host "[+] $Text" -ForegroundColor Green }
function Fail([string]$Text) { Write-Host "[x] $Text" -ForegroundColor Red; exit 1 }

function Get-Prop($Object, [string]$Name) {
  if ($null -eq $Object) { return $null }
  $p = $Object.PSObject.Properties[$Name]
  if ($p) { return $p.Value }
  return $null
}

function Find-DshRoot {
  $candidates = @()
  $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness')
  $candidates += (Join-Path $env:ProgramFiles 'DeepSeek Harness')
  foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    try {
      Get-ItemProperty $key -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'DeepSeek Harness*' -and $_.InstallLocation } |
        ForEach-Object { $candidates += $_.InstallLocation }
    } catch { }
  }
  foreach ($c in $candidates) {
    if ($c -and (Test-Path (Join-Path $c 'resources\app.asar'))) { return (Resolve-Path $c).Path }
  }
  return $null
}

function Open-Asar([string]$Path, $Access) {
  return [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, $Access, [System.IO.FileShare]::ReadWrite)
}

function Read-AsarHeader($Stream) {
  $br = New-Object System.IO.BinaryReader($Stream)
  [void]$br.ReadUInt32()
  $headerSize = $br.ReadUInt32()
  [void]$br.ReadUInt32()
  $jsonLen = $br.ReadUInt32()
  $Stream.Position = 16
  $json = [System.Text.Encoding]::UTF8.GetString($br.ReadBytes([int]$jsonLen))
  if ($json.Length -lt 2 -or $json[0] -ne '{') { throw 'app.asar header is not readable (unexpected layout)' }
  return @{ DataStart = [int64]$headerSize + 8; Json = ($json | ConvertFrom-Json) }
}

function Get-AsarNode($Root, [string]$Spec) {
  $node = $Root
  foreach ($seg in $Spec.Split('|')) {
    if ($null -eq $node) { return $null }
    $node = Get-Prop (Get-Prop $node 'files') $seg
  }
  return $node
}

function Resolve-Entry($Header) {
  foreach ($spec in $Specs) {
    $n = Get-AsarNode $Header.Json $spec
    if ($n) {
      $size = Get-Prop $n 'size'
      $off = Get-Prop $n 'offset'
      if ($null -ne $size -and $null -ne $off) {
        return @{ Offset = [int64]$off + $Header.DataStart; Size = [int]$size; Spec = $spec }
      }
    }
  }
  return $null
}

function Read-EntryBytes([string]$AsarPath, [int64]$Offset, [int]$Size) {
  $s = Open-Asar $AsarPath ([System.IO.FileAccess]::Read)
  try {
    $s.Position = $Offset
    $b = New-Object byte[] $Size
    [void]$s.Read($b, 0, $Size)
    return $b
  } finally { $s.Dispose() }
}

function Get-AppVersion([string]$AsarPath, $Header) {
  $n = Get-AsarNode $Header.Json 'package.json'
  if (-not $n) { return 'unknown' }
  try {
    $b = Read-EntryBytes $AsarPath ([int64](Get-Prop $n 'offset') + $Header.DataStart) ([int](Get-Prop $n 'size'))
    return ([System.Text.Encoding]::UTF8.GetString($b) | ConvertFrom-Json).version
  } catch { return 'unknown' }
}

function Trim-CommentBlock([string]$Text, [int]$LaunchIndex, [int]$Need) {
  # Delete whole ASCII-only JSDoc lines above the launch site until >= Need bytes are gone.
  # Returns @{ Text = ...; Removed = <bytes> } or $null when there is not enough headroom.
  $start = $Text.LastIndexOf('/**', $LaunchIndex)
  if ($start -lt 0) { return $null }
  $end = $Text.IndexOf('*/', $start)
  if ($end -lt 0 -or $end -gt $LaunchIndex) { return $null }
  $block = $Text.Substring($start, $end - $start)
  $lines = $block -split [char]10
  $drop = @{}
  $bytes = 0
  for ($i = $lines.Count - 1; $i -ge 1 -and $bytes -lt $Need; $i--) {
    $line = $lines[$i]
    if ($line -match '^\s*\*/' -or $line -match '/\*\*') { continue }
    $ascii = $true
    foreach ($ch in $line.ToCharArray()) { if ([int]$ch -gt 127) { $ascii = $false; break } }
    if (-not $ascii) { continue }
    if ($line.Trim().Length -lt 8) { continue }
    $drop[$i] = $true
    $bytes += $line.Length + 1
  }
  if ($bytes -lt $Need) { return $null }
  $kept = @()
  for ($i = 0; $i -lt $lines.Count; $i++) { if (-not $drop.ContainsKey($i)) { $kept += $lines[$i] } }
  $newBlock = ($kept -join [string][char]10)
  return @{ Text = ($Text.Substring(0, $start) + $newBlock + $Text.Substring($end)); Removed = $bytes }
}

$mode = if ($DryRun) { 'DRY RUN' } else { 'APPLY' }
Write-Host ''
Write-Host "  DSH Windows open-in-app fix  [$mode]" -ForegroundColor Cyan
Write-Host '  ------------------------------------------------'

if (-not $DshRoot) { $DshRoot = Find-DshRoot }
if (-not $DshRoot) { Fail 'DSH Desktop install folder not found. Pass -DshRoot <folder that contains resources\app.asar>.' }
$asar = Join-Path $DshRoot 'resources\app.asar'
if (-not (Test-Path $asar)) { Fail "app.asar not found under: $DshRoot\resources" }
Write-Step "DSH install : $asar"

$s = Open-Asar $asar ([System.IO.FileAccess]::Read)
try { $hdr = Read-AsarHeader $s } finally { $s.Dispose() }
$version = Get-AppVersion $asar $hdr
$entry = Resolve-Entry $hdr
if (-not $entry) { Fail 'Launcher entry not found inside app.asar. This DSH build is not supported.' }
Write-Step "DSH version : $version"
Write-Step "Launcher    : $($entry.Spec)"

$orig = Read-EntryBytes $asar $entry.Offset $entry.Size
$text = [System.Text.Encoding]::UTF8.GetString($orig)

if ($text.Contains($PatchNew)) { Write-Ok 'Already patched - nothing to do.'; exit 0 }
if (-not $text.Contains('launchDetachedApp') -or -not $text.Contains('ELECTRON_RUN_AS_NODE')) {
  Fail 'Launcher shape does not match a known build. Refusing to modify.'
}
$hits = ([regex]::Matches($text, [regex]::Escape($PatchOld))).Count
if ($hits -ne 1) { Fail "Launch site is not unique in this build ($hits matches). Refusing to modify." }

$patched = $text.Replace($PatchOld, $PatchNew)
$grew = [System.Text.Encoding]::UTF8.GetByteCount($patched) - $orig.Length
if ($grew -le 0) { Fail 'Unexpected replacement size. Refusing to modify.' }
$trim = Trim-CommentBlock $patched $patched.IndexOf($PatchNew) $grew
if (-not $trim) { Fail 'Cannot keep the archive byte-identical (no comment headroom). Refusing to modify.' }
$patched = $trim.Text
$pad = $trim.Removed - $grew
if ($pad -gt 0) { $patched += (' ' * $pad) }
$bytes = [System.Text.Encoding]::UTF8.GetBytes($patched)
if ($bytes.Length -ne $orig.Length) { Fail "Length mismatch after patch ($($bytes.Length) vs $($orig.Length)). Refusing to write." }
Write-Step ("Patch size  : {0} bytes -> {0} bytes (comment trimmed {1}, padding {2})" -f $orig.Length, $trim.Removed, $pad)

if ($DryRun) { Write-Ok 'Dry run complete - nothing was written. Re-run without -DryRun to apply.'; exit 0 }

if (-not (Test-Path $BackupDir)) { [void](New-Item -ItemType Directory -Path $BackupDir -Force) }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $BackupDir ("app.asar.{0}.{1}.bak" -f $version, $stamp)
$info = Get-Item $asar
$free = (New-Object System.IO.DriveInfo($info.PSDrive.Name)).AvailableFreeSpace
if ($free -lt ($info.Length * 2)) { Fail 'Not enough free disk space for the full app.asar backup.' }
Write-Step "Backup      : $backup"
Copy-Item -LiteralPath $asar -Destination $backup -Force
[void](Set-Content -LiteralPath ($backup + '.txt') -Value ("launcher={0} size={1} version={2} at={3}" -f $entry.Spec, $entry.Size, $version, (Get-Date -Format 's')) -Encoding ASCII)

$s = Open-Asar $asar ([System.IO.FileAccess]::ReadWrite)
try {
  $s.Position = $entry.Offset
  $s.Write($bytes, 0, $bytes.Length)
  $s.Flush()
} finally { $s.Dispose() }

$check = Read-EntryBytes $asar $entry.Offset $entry.Size
$checkText = [System.Text.Encoding]::UTF8.GetString($check)
if (-not $checkText.Contains($PatchNew)) { Fail "Write verification failed. Restore with uninstall.ps1 (backup: $backup)" }
if ($check.Length -ne $orig.Length) { Fail "Write verification failed (size). Restore with uninstall.ps1 (backup: $backup)" }
Write-Ok 'Written and verified.'

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("oia-check-{0}.mjs" -f $stamp)
try {
  [System.IO.File]::WriteAllText($tmp, $checkText, (New-Object System.Text.UTF8Encoding($false)))
  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if ($nodeCmd) {
    & $nodeCmd.Source --check $tmp 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Ok 'Syntax check passed.' } else { Write-Host '[!] Syntax check reported an error - run uninstall.ps1.' -ForegroundColor Yellow }
  } else {
    $exe = Join-Path $DshRoot 'DeepSeek Harness.exe'
    if (Test-Path $exe) {
      $env:ELECTRON_RUN_AS_NODE = '1'
      & $exe --check $tmp 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) { Write-Ok 'Syntax check passed.' } else { Write-Host '[!] Syntax check reported an error - run uninstall.ps1.' -ForegroundColor Yellow }
      Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
    } else {
      Write-Host '[!] Node runtime not found - syntax check skipped.' -ForegroundColor Yellow
    }
  }
} finally { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }

Write-Host ''
Write-Ok 'Fix applied. Restart DSH Desktop, then use: ... > Open in > VS Code'
Write-Host '    Rollback: .\uninstall.ps1'
