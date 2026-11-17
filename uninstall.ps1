<#
.SYNOPSIS
  Restore the original DSH Desktop app.asar from the backup made by install.ps1.

.PARAMETER DshRoot
  DSH Desktop install folder (the one that contains a "resources" folder).
  Auto-detected when omitted.

.PARAMETER BackupDir
  Backup folder. Defaults to %LOCALAPPDATA%\dsh-open-in-app-fix\backups.

.PARAMETER BackupFile
  Restore one specific backup instead of the newest one.

.PARAMETER DryRun
  Report what would be done, write nothing.
#>
[CmdletBinding()]
param(
  [string]$DshRoot,
  [string]$BackupDir,
  [string]$BackupFile,
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

function Read-EntryBytes([string]$AsarPath, [int64]$Offset, [int]$Size) {
  $s = Open-Asar $AsarPath ([System.IO.FileAccess]::Read)
  try {
    $s.Position = $Offset
    $b = New-Object byte[] $Size
    [void]$s.Read($b, 0, $Size)
    return $b
  } finally { $s.Dispose() }
}

Write-Host ''
Write-Host '  DSH Windows open-in-app fix  [ROLLBACK]' -ForegroundColor Cyan
Write-Host '  ------------------------------------------------'

if (-not $DshRoot) { $DshRoot = Find-DshRoot }
if (-not $DshRoot) { Fail 'DSH Desktop install folder not found. Pass -DshRoot <folder that contains resources\app.asar>.' }
$asar = Join-Path $DshRoot 'resources\app.asar'
if (-not (Test-Path $asar)) { Fail "app.asar not found under: $DshRoot\resources" }

$s = Open-Asar $asar ([System.IO.FileAccess]::Read)
try { $hdr = Read-AsarHeader $s } finally { $s.Dispose() }

$entry = $null
foreach ($spec in $Specs) {
  $n = Get-AsarNode $hdr.Json $spec
  if ($n) { $entry = @{ Offset = [int64](Get-Prop $n 'offset') + $hdr.DataStart; Size = [int](Get-Prop $n 'size'); Spec = $spec }; break }
}
if (-not $entry) { Fail 'Launcher entry not found. Nothing to restore.' }

$curText = [System.Text.Encoding]::UTF8.GetString((Read-EntryBytes $asar $entry.Offset $entry.Size))
if (-not $curText.Contains($PatchNew)) { Write-Ok 'This install is not patched - nothing to restore.'; exit 0 }

if ($BackupFile) {
  if (-not (Test-Path $BackupFile)) { Fail "Backup not found: $BackupFile" }
  $backup = (Resolve-Path $BackupFile).Path
} else {
  $backup = Get-ChildItem (Join-Path $BackupDir 'app.asar.*.bak') -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
  if (-not $backup) { Fail "No backup found in $BackupDir . Cannot restore automatically." }
}
Write-Step "Backup      : $backup"

$orig = Read-EntryBytes $backup $entry.Offset $entry.Size
$origText = [System.Text.Encoding]::UTF8.GetString($orig)
if (-not $origText.Contains($PatchOld) -or $origText.Contains($PatchNew)) {
  Fail 'Backup does not match this install (different DSH version?). Nothing was changed.'
}

if ($DryRun) { Write-Ok 'Dry run complete - nothing was written.'; exit 0 }

$s = Open-Asar $asar ([System.IO.FileAccess]::ReadWrite)
try {
  $s.Position = $entry.Offset
  $s.Write($orig, 0, $orig.Length)
  $s.Flush()
} finally { $s.Dispose() }

$check = [System.Text.Encoding]::UTF8.GetString((Read-EntryBytes $asar $entry.Offset $entry.Size))
if ($check.Contains($PatchNew)) { Fail 'Restore verification failed. The backup is kept at the path above.' }
Write-Ok 'Original restored and verified. Restart DSH Desktop.'
