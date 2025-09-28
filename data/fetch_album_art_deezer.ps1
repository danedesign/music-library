param(
    [string]$InputCsv = 'aggregated_playlist_youtube.csv',
    [string]$OutputCsv = 'aggregated_playlist_youtube.csv',
    [string]$OutputJson = 'aggregated_playlist_youtube.json',
    [int]$MaxRequests = 1000
)

$ErrorActionPreference = 'Stop'
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

function Normalize-ComparableText {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $lower = $Value.ToLowerInvariant()
    $lower = [System.Text.RegularExpressions.Regex]::Replace($lower, '[^a-z0-9]+', ' ')
    $lower = [System.Text.RegularExpressions.Regex]::Replace($lower, '\s+', ' ')
    return $lower.Trim()
}

function Query-DeezerCover {
    param(
        [string]$Artist,
        [string]$Title,
        [hashtable]$Cache,
        [ref]$RequestCount,
        [int]$MaxRequests
    )
    $key = Normalize-ComparableText("$Artist|$Title")
    if ($Cache.ContainsKey($key)) { return $Cache[$key] }
    if ($RequestCount.Value -ge $MaxRequests) { return $null }
    $sanitizedArtist = $Artist -replace '"', ''
    $sanitizedTitle = $Title -replace '"', ''
    $term = 'artist:"{0}" track:"{1}"' -f $sanitizedArtist, $sanitizedTitle
    $encoded = [System.Uri]::EscapeDataString($term)
    $url = "https://api.deezer.com/search?q=$encoded&limit=10"
    try {
        $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30
    } catch {
        Start-Sleep -Milliseconds 350
        $Cache[$key] = $null
        return $null
    }
    $RequestCount.Value++
    Start-Sleep -Milliseconds 350
    if (-not $resp.data) {
        $Cache[$key] = $null
        return $null
    }
    $targetArtist = Normalize-ComparableText $Artist
    $targetTitle = Normalize-ComparableText $Title
    $best = $null
    $bestScore = -1
    foreach ($item in $resp.data) {
        $artistName = Normalize-ComparableText $item.artist.name
        $trackTitle = Normalize-ComparableText $item.title
        $albumTitle = Normalize-ComparableText $item.album.title
        $score = 0
        if ($artistName -eq $targetArtist) { $score += 60 }
        elseif ($artistName -and ($artistName.Contains($targetArtist) -or $targetArtist.Contains($artistName))) { $score += 30 }
        if ($trackTitle -eq $targetTitle) { $score += 60 }
        elseif ($trackTitle.Contains($targetTitle) -or $targetTitle.Contains($trackTitle)) { $score += 30 }
        if ($albumTitle -and $albumTitle -notmatch 'single') { $score += 10 }
        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = $item
        }
    }
    if ($best -and $best.album) {
        $cover = $best.album.cover_xl
        if (-not $cover) { $cover = $best.album.cover_big }
        if ($cover) {
            $Cache[$key] = $cover
            return $cover
        }
    }
    $Cache[$key] = $null
    return $null
}

$data = Import-Csv -Path $InputCsv
foreach ($row in $data) {
    if (-not $row.PSObject.Properties['AlbumArtUrl']) {
        $row | Add-Member -NotePropertyName 'AlbumArtUrl' -NotePropertyValue ''
    }
}

$targets = $data | Where-Object { [string]::IsNullOrWhiteSpace($_.AlbumArtUrl) }
$cache = @{}
$requestCount = [ref]0
$updated = 0

foreach ($row in $targets) {
    $url = Query-DeezerCover -Artist $row.Artist -Title $row.Title -Cache $cache -RequestCount $requestCount -MaxRequests $MaxRequests
    if ($url) {
        $row.AlbumArtUrl = $url
        $updated++
    }
}

Write-Host "Covers populated:" $updated "using" $requestCount.Value "Deezer lookups."

$data | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
$data | ConvertTo-Json -Depth 3 | Set-Content -Path $OutputJson -Encoding UTF8
Write-Host 'Artwork caching complete.'
