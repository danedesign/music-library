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
    $normalized = [System.Text.RegularExpressions.Regex]::Replace($normalized, '(?i)\b(deluxe|expanded|edition|remastered|radio edit|ep|version|explicit|bonus track|remix|single)\b', '')
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
        [int]$Limit = 10
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
        [string]$TargetTitle
    )
    $score = 0
    $candidateArtist = Normalize-ComparableText ($Candidate.artistName)
    $candidateCollection = Normalize-AlbumTitle ($Candidate.collectionName)
    $candidateTrack = Normalize-AlbumTitle ($Candidate.trackName)

    $targetArtist = Normalize-ComparableText $TargetArtist
    $targetTitle = Normalize-AlbumTitle $TargetTitle

    if ($candidateArtist -and $targetArtist) {
        if ($candidateArtist -eq $targetArtist) { $score += 60 }
        elseif ($candidateArtist.Contains($targetArtist) -or $targetArtist.Contains($candidateArtist)) { $score += 30 }
    }
    if ($candidateTrack -and $targetTitle) {
        if ($candidateTrack -eq $targetTitle) { $score += 40 }
        elseif ($candidateTrack.Contains($targetTitle) -or $targetTitle.Contains($candidateTrack)) { $score += 20 }
    }
    if ($candidateCollection) {
        if (-not $candidateCollection.Contains('single')) { $score += 20 }
        if ($Candidate.collectionType -eq 'Album') { $score += 30 }
        elseif ($Candidate.collectionType -eq 'Compilation') { $score += 15 }
    }
    return $score
}

function Resolve-Album {
    param(
        [System.Net.Http.HttpClient]$Client,
        [string]$Artist,
        [string]$Title,
        [string]$CurrentAlbum
    )

    $queries = @()
    $queries += @{ term = "$Artist $Title"; entity = 'song' }
    $queries += @{ term = "$Title $Artist"; entity = 'song' }
    foreach ($variant in Split-ArtistVariants $Artist) {
        if ($variant -ne $Artist) {
            $queries += @{ term = "$variant $Title"; entity = 'song' }
        }
    }
    $queries += @{ term = "$Artist"; entity = 'album' }
    $queries += @{ term = $Title; entity = 'album' }

    $bestCandidate = $null
    $bestScore = 0

    foreach ($query in $queries) {
        $results = Invoke-ItunesSearch -Client $Client -Term $query.term -Entity $query.entity
        foreach ($candidate in $results) {
            if (-not $candidate.collectionName) { continue }
            if ($candidate.collectionName -match '(?i)\b(single|karaoke|instrumental)\b') { continue }
            $score = Score-Candidate -Candidate $candidate -TargetArtist $Artist -TargetTitle $Title
            if ($score -gt $bestScore) {
                $bestScore = $score
                $bestCandidate = $candidate
            }
        }
        if ($bestScore -ge 80) { break }
        Start-Sleep -Milliseconds 120
    }

    if ($bestCandidate -and $bestCandidate.collectionName) {
        $proposed = $bestCandidate.collectionName.Trim()
        if (-not [string]::IsNullOrWhiteSpace($proposed) -and ($proposed -ne $CurrentAlbum)) {
            return $proposed
        }
    }
    return $CurrentAlbum
}

$data = Import-Csv -Path $InputCsv
if (-not $data) {
    Write-Error "No data found in $InputCsv"
    exit 1
}

$targets = $data | Where-Object { $_.Album -and $_.Album -match '(?i)-\s*single' }
if (-not $targets) {
    Write-Host 'No fallback single albums to revise.'
    exit 0
}

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(15)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('PlaylistAlbumRefiner/1.0')

$cache = @{}
$updatedCount = 0

foreach ($row in $targets) {
    $cacheKey = Normalize-ComparableText("$($row.Artist)|$($row.Title)")
    $newAlbum = $null
    if ($cache.ContainsKey($cacheKey)) {
        $newAlbum = $cache[$cacheKey]
    } else {
        $newAlbum = Resolve-Album -Client $client -Artist $row.Artist -Title $row.Title -CurrentAlbum $row.Album
        $cache[$cacheKey] = $newAlbum
    }
    if ($newAlbum -and $newAlbum -ne $row.Album) {
        $row.Album = $newAlbum
        $updatedCount++
    }
}

$client.Dispose()

Write-Host "Revised albums:" $updatedCount

$data | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
$data | ConvertTo-Json -Depth 3 | Set-Content -Path $OutputJson -Encoding UTF8
Write-Host 'Album refinement complete.'
