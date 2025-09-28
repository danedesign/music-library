param(
    [string]$InputCsv = 'aggregated_playlist_youtube.csv',
    [string]$OutputCsv = 'aggregated_playlist_youtube.csv',
    [string]$OutputJson = 'aggregated_playlist_youtube.json'
)

$ErrorActionPreference = 'Stop'

function Normalize-ComparableText {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $lower = $Value.ToLowerInvariant()
    foreach ($ch in @([char]0x2019, [char]39, [char]34, [char]96)) {
        $lower = $lower.Replace([string]$ch, [string]::Empty)
    }
    $lower = [System.Text.RegularExpressions.Regex]::Replace($lower, '[\p{P}\p{S}]', ' ')
    $lower = [System.Text.RegularExpressions.Regex]::Replace($lower, '\s+', ' ')
    return $lower.Trim()
}

function Normalize-AlbumTitle {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $normalized = $Value.ToLowerInvariant()
    $normalized = $normalized.Replace([char]0x2019, "'")
    $normalized = [System.Text.RegularExpressions.Regex]::Replace($normalized, '(?i)\b(deluxe|expanded|edition|remastered|radio edit|single|ep|version|explicit|bonus track|remix)\b', '')
    $normalized = [System.Text.RegularExpressions.Regex]::Replace($normalized, '[-_()\[\]\{\}:.,]', ' ')
    $normalized = [System.Text.RegularExpressions.Regex]::Replace($normalized, '\s+', ' ')
    return $normalized.Trim()
}

function Split-ArtistVariants {
    param([string]$Artist)
    if ([string]::IsNullOrWhiteSpace($Artist)) { return @() }
    $clean = $Artist -replace '(?i)feat\.?', '&' -replace '(?i)with', '&' -replace '(?i) x ', ' &' -replace '(?i)×', '&'
    $parts = $clean -split '[\\/&,+]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($parts.Count -gt 0) { return $parts }
    return @($Artist)
}

function Invoke-ItunesSearch {
    param(
        [System.Net.Http.HttpClient]$Client,
        [string]$Term,
        [string]$Entity,
        [int]$Limit = 5
    )
    if ([string]::IsNullOrWhiteSpace($Term)) { return @() }
    $encoded = [System.Uri]::EscapeDataString($Term)
    $url = "https://itunes.apple.com/search?term=$encoded&media=music&entity=$Entity&limit=$Limit"
    try {
        $response = $Client.GetAsync($url).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { return @() }
        $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ([string]::IsNullOrWhiteSpace($json)) { return @() }
        $parsed = $json | ConvertFrom-Json
        if (-not $parsed) { return @() }
        return $parsed.results
    } catch {
        return @()
    }
}

function Score-Candidate {
    param(
        [object]$Candidate,
        [string]$TargetArtist,
        [string]$TargetAlbum,
        [string]$TargetTitle
    )
    $score = 0
    $candidateArtist = Normalize-ComparableText ($Candidate.artistName)
    $candidateCollection = Normalize-AlbumTitle ($Candidate.collectionName)
    $candidateTrack = Normalize-AlbumTitle ($Candidate.trackName)

    $targetArtist = Normalize-ComparableText $TargetArtist
    $targetAlbum = Normalize-AlbumTitle $TargetAlbum
    $targetTitle = Normalize-AlbumTitle $TargetTitle

    if ($candidateArtist -and $targetArtist) {
        if ($candidateArtist -eq $targetArtist) { $score += 60 }
        elseif ($candidateArtist.Contains($targetArtist) -or $targetArtist.Contains($candidateArtist)) { $score += 30 }
    }

    if ($candidateCollection -and $targetAlbum) {
        if ($candidateCollection -eq $targetAlbum) { $score += 50 }
        elseif ($candidateCollection.Contains($targetAlbum) -or $targetAlbum.Contains($candidateCollection)) { $score += 25 }
    }

    if ($candidateTrack -and $targetTitle) {
        if ($candidateTrack -eq $targetTitle) { $score += 40 }
        elseif ($candidateTrack.Contains($targetTitle) -or $targetTitle.Contains($candidateTrack)) { $score += 20 }
    }

    return $score
}

function Find-Artwork {
    param(
        [System.Net.Http.HttpClient]$Client,
        [string]$Artist,
        [string]$Album,
        [string]$Title
    )

    $queries = @()
    if ($Album) { $queries += @{ term = "$Artist $Album"; entity = 'album' } }
    $queries += @{ term = "$Artist $Title"; entity = 'song' }
    $queries += @{ term = "$Title $Artist"; entity = 'song' }
    if ($Album) { $queries += @{ term = $Album; entity = 'album' } }
    foreach ($variant in Split-ArtistVariants $Artist) {
        if ($variant -ne $Artist) {
            if ($Album) { $queries += @{ term = "$variant $Album"; entity = 'album' } }
            $queries += @{ term = "$variant $Title"; entity = 'song' }
        }
    }
    $queries += @{ term = $Title; entity = 'song' }

    $bestCandidate = $null
    $bestScore = 0

    foreach ($query in $queries) {
        $results = Invoke-ItunesSearch -Client $Client -Term $query.term -Entity $query.entity -Limit 10
        foreach ($candidate in $results) {
            if (-not $candidate.artworkUrl100) { continue }
            $score = Score-Candidate -Candidate $candidate -TargetArtist $Artist -TargetAlbum $Album -TargetTitle $Title
            if ($score -gt $bestScore) {
                $bestScore = $score
                $bestCandidate = $candidate
            }
        }
        if ($bestScore -ge 70) { break }
        Start-Sleep -Milliseconds 120
    }

    if ($bestCandidate) {
        $art = $bestCandidate.artworkUrl100
        if ($art) {
            return $art -replace '100x100bb', '600x600bb'
        }
    }
    return $null
}

$data = Import-Csv -Path $InputCsv
if (-not $data) {
    Write-Error "No data found in $InputCsv"
    exit 1
}

foreach ($row in $data) {
    if (-not $row.PSObject.Properties['AlbumArtUrl']) {
        $row | Add-Member -NotePropertyName 'AlbumArtUrl' -NotePropertyValue ''
    }
}

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(15)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('PlaylistCoverFetcher/1.0')

$cache = @{}
$updated = 0
$missing = 0

foreach ($row in $data) {
    $key = Normalize-ComparableText("$($row.Artist)|$($row.Album)")
    if ($cache.ContainsKey($key)) {
        $row.AlbumArtUrl = $cache[$key]
        continue
    }
    $artUrl = $null
    if ($row.AlbumArtUrl) {
        $artUrl = $row.AlbumArtUrl
    }
    if (-not $artUrl) {
        $artUrl = Find-Artwork -Client $client -Artist $row.Artist -Album $row.Album -Title $row.Title
    }
    if (-not $artUrl) {
        $missing++
        $artUrl = ''
    } else {
        $updated++
    }
    $cache[$key] = $artUrl
    $row.AlbumArtUrl = $artUrl
}

$client.Dispose()

Write-Host "Artwork found for:" $updated
if ($missing -gt 0) {
    Write-Warning "$missing entries still missing artwork"
}

$data | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
$data | ConvertTo-Json -Depth 3 | Set-Content -Path $OutputJson -Encoding UTF8
Write-Host "Artwork update complete."
