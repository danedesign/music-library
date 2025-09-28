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

function Invoke-DeezerSearch {
    param([string]$Query, [int]$Limit = 10)
    try {
        return Invoke-RestMethod -Uri "https://api.deezer.com/search?q=$Query&limit=$Limit" -Method Get -TimeoutSec 30
    } catch {
        return $null
    }
}

function Choose-BestDeezer {
    param($data, [string]$Artist, [string]$Title)
    if (-not $data) { return $null }
    $targetArtist = Normalize-ComparableText $Artist
    $targetTitle = Normalize-ComparableText $Title
    $best = $null
    $bestScore = -1
    foreach ($item in $data) {
        $artistName = Normalize-ComparableText $item.artist.name
        $trackTitle = Normalize-ComparableText $item.title
        $albumTitle = Normalize-ComparableText $item.album.title
        $score = 0
        if ($artistName -eq $targetArtist) { $score += 60 }
        elseif ($artistName -and ($artistName.Contains($targetArtist) -or $targetArtist.Contains($artistName))) { $score += 30 }
        if ($trackTitle -eq $targetTitle) { $score += 60 }
        elseif ($trackTitle.Contains($targetTitle) -or $targetTitle.Contains($trackTitle)) { $score += 30 }
        if ($albumTitle -and $albumTitle -notmatch 'single') { $score += 15 }
        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = $item
        }
    }
    return $best
}

function Query-DeezerTrack {
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
    $results = @()

    $term = [System.Uri]::EscapeDataString(('artist:"{0}" track:"{1}"' -f $sanitizedArtist, $sanitizedTitle))
    $resp = Invoke-DeezerSearch -Query $term
    $RequestCount.Value++
    Start-Sleep -Milliseconds 350
    if ($resp -and $resp.data) { $results += $resp.data }

    if (-not $results) {
        $term2 = [System.Uri]::EscapeDataString("$sanitizedTitle $sanitizedArtist")
        $resp2 = Invoke-DeezerSearch -Query $term2
        $RequestCount.Value++
        Start-Sleep -Milliseconds 350
        if ($resp2 -and $resp2.data) { $results += $resp2.data }
    }

    if (-not $results) {
        $Cache[$key] = $null
        return $null
    }

    $best = Choose-BestDeezer -data $results -Artist $Artist -Title $Title
    $Cache[$key] = $best
    return $best
}

$data = Import-Csv -Path $InputCsv
$targets = $data | Where-Object { $_.Album -match '(?i)-\s*single' }
if (-not $targets) {
    Write-Host 'No albums with the "- Single" fallback remain.'
    exit 0
}

$cache = @{}
$requestCount = [ref]0
$updated = 0

foreach ($row in $targets) {
    $info = Query-DeezerTrack -Artist $row.Artist -Title $row.Title -Cache $cache -RequestCount $requestCount -MaxRequests $MaxRequests
    if ($info -and $info.album) {
        $albumTitle = $info.album.title
        if ($albumTitle -and $albumTitle -notmatch '(?i)single' -and $albumTitle -ne $row.Album) {
            $row.Album = $albumTitle
            if (-not $row.PSObject.Properties['AlbumArtUrl']) {
                $row | Add-Member -NotePropertyName 'AlbumArtUrl' -NotePropertyValue ''
            }
            if (-not $row.AlbumArtUrl -and $info.album.cover_xl) {
                $row.AlbumArtUrl = $info.album.cover_xl
            }
            $updated++
        }
    }
}

Write-Host "Albums refined via Deezer:" $updated "using" $requestCount.Value "lookups."

$data | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
$data | ConvertTo-Json -Depth 3 | Set-Content -Path $OutputJson -Encoding UTF8
Write-Host 'Deezer refinement complete.'
