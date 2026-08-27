<#
  inventory.ps1  —  TASK 1: locate + inventory Valorant .vrf replays (Windows)

  RUN THIS ON YOUR WINDOWS MACHINE. I cannot reach your filesystem from the
  cloud sandbox, so nothing here has been tested against a real .vrf. Treat
  every "header" field below as UNVERIFIED until you run it and eyeball it.

  Usage (PowerShell):
      powershell -ExecutionPolicy Bypass -File .\inventory.ps1
      # optional: point at a copied-out folder instead of the live one
      powershell -ExecutionPolicy Bypass -File .\inventory.ps1 -Path "D:\vrf_backup"

  What is RELIABLE here:  path discovery, file size, on-disk timestamps,
                          match-id (the filename IS the Riot match id).
  What is BEST-EFFORT:    duration / map / patch pulled from the header.
                          The .vrf header is a Riot-marked Unreal replay
                          container; the stream body is Oodle-compressed, but
                          the LEADING metadata block is usually NOT. This
                          script only sniffs that leading block. If the fields
                          come back as garbage, the header is encrypted/custom
                          and you need the full C# parser (see parse_one.md).
#>

param(
    [string]$Path = "$env:LOCALAPPDATA\VALORANT\Saved\Demos"
)

Write-Host "Looking in: $Path" -ForegroundColor Cyan
if (-not (Test-Path $Path)) {
    Write-Host "NOT FOUND. Other paths people report (check each):" -ForegroundColor Yellow
    @(
        "$env:LOCALAPPDATA\VALORANT\Saved\Demos",
        "$env:LOCALAPPDATA\VALORANT\Saved\Replays",
        "$env:USERPROFILE\Documents\VALORANT"
    ) | ForEach-Object { Write-Host "   $_" }
    Write-Host "AppData is hidden by default; the folder can exist even if Explorer hides it." -ForegroundColor Yellow
    return
}

$files = Get-ChildItem -Path $Path -Filter *.vrf -File -ErrorAction SilentlyContinue
if (-not $files) { Write-Host "No .vrf files found in $Path" -ForegroundColor Yellow; return }

# Standard Unreal local-file replay magic (little-endian uint32 0x1CA2E27F).
$UNREAL_MAGIC = 0x1CA2E27F

$rows = foreach ($f in $files) {
    $matchId  = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    $sizeMB   = [Math]::Round($f.Length / 1MB, 1)

    # --- best-effort header sniff: read first 4 KB, look for the Unreal magic ---
    $magicHit = $false
    $friendly = ""
    try {
        $fs = [IO.File]::OpenRead($f.FullName)
        $buf = New-Object byte[] 4096
        $n = $fs.Read($buf, 0, $buf.Length)
        $fs.Close()

        for ($i = 0; $i -le $n - 4; $i++) {
            $val = [BitConverter]::ToUInt32($buf, $i)
            if ($val -eq $UNREAL_MAGIC) { $magicHit = $true; break }
        }
        # Pull any run of printable ASCII >= 4 chars as a candidate friendly name / map token.
        $ascii = -join ($buf[0..($n-1)] | ForEach-Object {
            if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { "`0" } })
        $tokens = $ascii -split "`0" | Where-Object { $_.Length -ge 4 }
        $friendly = ($tokens | Select-Object -First 6) -join " | "
    } catch { }

    [pscustomobject]@{
        MatchId        = $matchId
        SizeMB         = $sizeMB
        Modified       = $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
        UnrealHeader   = if ($magicHit) { "yes" } else { "NO/enc?" }
        HeaderStrings  = $friendly
    }
}

$rows | Sort-Object Modified | Format-Table -AutoSize
Write-Host ""
Write-Host ("Total: {0} files, {1:N1} MB" -f $rows.Count, (($files | Measure-Object Length -Sum).Sum/1MB)) -ForegroundColor Green
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Cyan
Write-Host "  * MatchId column = the Riot match id. It is the join key to Riot's match API."
Write-Host "  * 'Map / patch / duration from header' is NOT reliably readable here."
Write-Host "    If HeaderStrings shows map names (Ascent/Bind/...) the leading block is plaintext."
Write-Host "    If it is garbage, use the full C# parser (parse_one.md) to get real fields."
$rows | Export-Csv -NoTypeInformation -Path (Join-Path $PSScriptRoot "vrf_inventory.csv")
Write-Host "  * Wrote vrf_inventory.csv"
