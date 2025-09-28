param(
    [string]$InputCsv = 'aggregated_playlist_youtube.csv',
    [string]$OutputCsv = 'aggregated_playlist_youtube.csv',
    [string]$OutputJson = 'aggregated_playlist_youtube.json',
    [int]$MaxRequests = 400
)

$ErrorActionPreference = 'Stop'
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

function Normalize-Key {
    param([string]$Artist,[string]$Title)
    $combo = "$Artist|$Title"
    $combo = $combo.ToLowerInvariant()
    $combo = [System.Text.RegularExpressions.Regex]::Replace($combo, '\s+', ' ')
    return $combo.Trim()
}

function Select-BestRelease {
    param($record)
    if (-not $record) { return $null }
    $releases = $record.releases
    if (-not $releases) { return $null }
    $preferred = $releases | Where-Object { $_."release-group"."primary-type" -eq 'Album' -and $_.title -notmatch '(?i)single|karaoke|instrumental' }
    if (-not $preferred) {
        $preferred = $releases | Where-Object { $_."release-group"."primary-type" -eq 'EP' -and $_.title -notmatch '(?i)single|karaoke|instrumental' }
    }
    if (-not $preferred) {
        $preferred = $releases | Where-Object { $_."release-group"."primary-type" -eq 'Compilation' -and $_.title -notmatch '(?i)single|karaoke|instrumental' }
    }
    if (-not $preferred) { $preferred = $releases }
    return ($preferred | Sort-Object { $_."release-group"."primary-type" })[0]
}

function Query-MusicBrainz {
    param(
        [string]$Artist,
        [string]$Title,
        [hashtable]$Cache,
        [ref]$RequestCount,
        [int]$MaxRequests
    )
    $key = Normalize-Key $Artist $Title
    if ($Cache.ContainsKey($key)) { return $Cache[$key] }
    if ($RequestCount.Value -ge $MaxRequests) { return $null }
    $encodedArtist = [System.Uri]::EscapeDataString($Artist)
    $encodedTitle = [System.Uri]::EscapeDataString($Title)
    $url = "https://musicbrainz.org/ws/2/recording/?query=recording:%22$encodedTitle%22%20AND%20artist:%22$encodedArtist%22&fmt=json&limit=5&inc=releases+release-groups"
    $headers = @{ 'User-Agent' = 'PlaylistAlbumRefiner/1.0 (https://github.com/headradio)' }
    try {
        $resp = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -TimeoutSec 30
    } catch {
        Start-Sleep -Milliseconds 1100
        $Cache[$key] = $null
        return $null
    }
    $RequestCount.Value++
    Start-Sleep -Milliseconds 1100
    if (-not $resp.recordings) {
        $Cache[$key] = $null
        return $null
    }
    $record = $resp.recordings | Sort-Object score -Descending | Select-Object -First 1
    $release = Select-BestRelease -record $record
    if ($release -and $release.title) {
        $title = $release.title.Trim()
        $Cache[$key] = $title
        return $title
    }
    $Cache[$key] = $null
    return $null
}

$data = Import-Csv -Path $InputCsv
$targets = $data | Where-Object { $_.Album -and $_.Album -match '(?i)-\s*single' }
if (-not $targets) {
    Write-Host 'No fallback single albums to refine.'
    exit 0
}

$cache = @{}
$requestCount = [ref]0
$updated = 0

foreach ($row in $targets) {
    $suggestion = Query-MusicBrainz -Artist $row.Artist -Title $row.Title -Cache $cache -RequestCount $requestCount -MaxRequests $MaxRequests
    if ($suggestion -and $suggestion -ne $row.Album) {
        $row.Album = $suggestion
        $updated++
    }
}

Write-Host "Refined" $updated "albums using" $requestCount.Value "MusicBrainz calls."

$data | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
$data | ConvertTo-Json -Depth 3 | Set-Content -Path $OutputJson -Encoding UTF8
Write-Host 'Album refinement complete.'
