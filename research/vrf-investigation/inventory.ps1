<#
  inventory.ps1  —  TASK 1: locate + inventory Valorant .vrf replays (Windows)

  VERIFIED against a real competitive replay (build release-13.04, 2026-08):
  the header + a player-loadout JSON block are PLAINTEXT. This script reads
  map, build/patch, and player-count (unique PUUIDs) straight out of each file.
  Only the per-tick network stream deeper in the file is Oodle-compressed.

  Usage (PowerShell):
      powershell -ExecutionPolicy Bypass -File .\inventory.ps1
      powershell -ExecutionPolicy Bypass -File .\inventory.ps1 -Path "D:\vrf_backup"

  RELIABLE here: path, size, timestamp, match-id (= filename), map, build,
                 player count. NOT here: positions/kills/tick-rate/duration
                 (those need the C# parser — see parse_one.md).
#>

param(
    [string]$Path = "$env:LOCALAPPDATA\VALORANT\Saved\Demos"
)

Write-Host "Looking in: $Path" -ForegroundColor Cyan
if (-not (Test-Path $Path)) {
    Write-Host "NOT FOUND. Other paths to check:" -ForegroundColor Yellow
    @(
        "$env:LOCALAPPDATA\VALORANT\Saved\Demos",
        "$env:LOCALAPPDATA\VALORANT\Saved\Replays"
    ) | ForEach-Object { Write-Host "   $_" }
    Write-Host "AppData is hidden by default; the folder can exist even if Explorer hides it." -ForegroundColor Yellow
    return
}

$files = Get-ChildItem -Path $Path -Filter *.vrf -File -ErrorAction SilentlyContinue
if (-not $files) { Write-Host "No .vrf files found in $Path" -ForegroundColor Yellow; return }

$RIOT_MAGIC = 0x43F4EFDD            # observed .vrf container magic (little-endian @0)
$enc = [Text.Encoding]::GetEncoding(28591)   # Latin-1: 1:1 byte<->char, works in PS 5.1

$rows = foreach ($f in $files) {
    $matchId = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    $sizeMB  = [Math]::Round($f.Length / 1MB, 1)
    $map = ""; $build = ""; $players = 0; $magicOk = $false

    try {
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        if ($bytes.Length -ge 4) {
            $magicOk = ([BitConverter]::ToUInt32($bytes, 0) -eq $RIOT_MAGIC)
        }
        $text = $enc.GetString($bytes)

        $m = [regex]::Match($text, '/Game/Maps/[A-Za-z0-9_]+/([A-Za-z0-9_]+)')
        if ($m.Success) { $map = $m.Groups[1].Value }

        $b = [regex]::Match($text, '\+\+[A-Za-z0-9]+-Core\+release-([0-9.]+)')
        if ($b.Success) { $build = $b.Groups[1].Value }

        $players = ([regex]::Matches($text, '"subject":\s*"[0-9a-f-]{36}"') |
                    ForEach-Object { $_.Value } | Sort-Object -Unique).Count
    } catch { }

    [pscustomobject]@{
        MatchId  = $matchId
        SizeMB   = $sizeMB
        Modified = $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
        Map      = $map
        Build    = $build
        Players  = $players
        Magic    = if ($magicOk) { "ok" } else { "??" }
    }
}

$rows | Sort-Object Build, Modified | Format-Table -AutoSize
Write-Host ""
Write-Host ("Total: {0} files, {1:N1} MB" -f $rows.Count, (($files | Measure-Object Length -Sum).Sum/1MB)) -ForegroundColor Green
$rows | Export-Csv -NoTypeInformation -Path (Join-Path $PSScriptRoot "vrf_inventory.csv")
Write-Host "Wrote vrf_inventory.csv" -ForegroundColor Cyan
Write-Host ""
Write-Host "READ-OUT:" -ForegroundColor Cyan
Write-Host "  * MatchId = Riot match id (the filename). Build = game patch. Both plaintext."
Write-Host "  * Players<10 or Magic='??' on an OLD file = the format shifted for that patch"
Write-Host "    (this is your old-patch fragility test - sort by Build to see the spread)."
Write-Host "  * Players column counts unique PUUIDs. Competitive strips names but keeps PUUIDs."
