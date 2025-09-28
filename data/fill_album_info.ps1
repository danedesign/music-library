param(
    [string]$InputCsv = 'aggregated_playlist_youtube.csv',
    [string]$OutputCsv = 'aggregated_playlist_youtube.csv',
    [string]$UpdatedJson = 'aggregated_playlist_youtube.json'
)

$ErrorActionPreference = 'Stop'

function Normalize-ComparableText {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $lowered = $Value.ToLowerInvariant()
    $clean = [System.Text.RegularExpressions.Regex]::Replace($lowered, '\s+', ' ')
    return $clean.Trim()
}

function Strip-FeaturingToken {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $result = [System.Text.RegularExpressions.Regex]::Replace($Value, '\s*\(feat\.[^\)]*\)', '', 'IgnoreCase')
    $result = [System.Text.RegularExpressions.Regex]::Replace($result, '\s*feat\.?\s+.*', '', 'IgnoreCase')
    $result = [System.Text.RegularExpressions.Regex]::Replace($result, '\s*ft\.?\s+.*', '', 'IgnoreCase')
    return $result.Trim()
}

function Build-LibraryAlbumMap {
    param([string[]]$LibraryFiles)
    $map = @{}
    foreach ($file in $LibraryFiles) {
        if (-not (Test-Path -Path $file)) { continue }
        try {
            [xml]$library = Get-Content -Path $file -Encoding UTF8
        } catch {
            Write-Warning ("Could not parse library file {0}: {1}" -f $file, $_)
            continue
        }
        $root = $library.plist.dict
        if (-not $root) { continue }
        $nodes = $root.ChildNodes
        $tracksDict = $null
        for ($i = 0; $i -lt $nodes.Count; $i += 2) {
            if ($nodes.Item($i).InnerText -eq 'Tracks') {
                $tracksDict = $nodes.Item($i + 1)
                break
            }
        }
        if (-not $tracksDict) { continue }
        for ($i = 0; $i -lt $tracksDict.ChildNodes.Count; $i += 2) {
            $trackNode = $tracksDict.ChildNodes.Item($i + 1)
            $trackChildren = $trackNode.ChildNodes
            $props = @{}
            for ($j = 0; $j -lt $trackChildren.Count; $j += 2) {
                $props[$trackChildren.Item($j).InnerText] = $trackChildren.Item($j + 1).InnerText
            }
            if (-not $props.ContainsKey('Name')) { continue }
            $name = $props['Name']
            $artist = if ($props.ContainsKey('Artist')) { $props['Artist'] } elseif ($props.ContainsKey('Album Artist')) { $props['Album Artist'] } else { $null }
            $album = $props['Album']
            if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($artist) -or [string]::IsNullOrWhiteSpace($album)) { continue }
            $key = (Normalize-ComparableText $artist) + '|' + (Normalize-ComparableText $name)
            if (-not $map.ContainsKey($key)) {
                $map[$key] = $album.Trim()
            }
        }
    }
    return $map
}

$libraryFiles = @('Library.xml', 'Library_Bartholomew.xml', '资料库.xml', '???.xml') | Where-Object { Test-Path -Path $_ }
$libraryAlbumMap = Build-LibraryAlbumMap -LibraryFiles $libraryFiles

$data = Import-Csv -Path $InputCsv
$existingAlbumMap = @{}
foreach ($row in $data) {
    if (-not [string]::IsNullOrWhiteSpace($row.Album)) {
        $key = (Normalize-ComparableText $row.Artist) + '|' + (Normalize-ComparableText $row.Title)
        if (-not $existingAlbumMap.ContainsKey($key)) {
            $existingAlbumMap[$key] = $row.Album
        }
    }
}

$missingRows = $data | Where-Object { [string]::IsNullOrWhiteSpace($_.Album) }
$missingCount = $missingRows.Count
Write-Host "Missing album entries:" $missingCount
if ($missingCount -eq 0) {
    $data | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    $data | ConvertTo-Json -Depth 3 | Set-Content -Path $UpdatedJson -Encoding UTF8
    Write-Host "No updates needed."
    exit 0
}

$albumCache = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
$queryCache = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()

foreach ($kv in $existingAlbumMap.GetEnumerator()) {
    $albumCache[$kv.Key] = $kv.Value
}
foreach ($kv in $libraryAlbumMap.GetEnumerator()) {
    if (-not $albumCache.ContainsKey($kv.Key)) {
        $albumCache[$kv.Key] = $kv.Value
    }
}

$client = [System.Net.Http.HttpClient]::new()
$client.DefaultRequestHeaders.UserAgent.ParseAdd('PlaylistAlbumResolver/1.0')

function Invoke-ItunesSearch {
    param(
        [System.Net.Http.HttpClient]$Client,
        [string]$Term,
        [string]$Entity
    )
    if ([string]::IsNullOrWhiteSpace($Term)) { return $null }
    $normalizedTerm = Normalize-ComparableText $Term
    $cacheKey = "$Entity|$normalizedTerm"
    if ($queryCache.ContainsKey($cacheKey)) {
        return $queryCache[$cacheKey]
    }
    $encoded = [System.Uri]::EscapeDataString($Term)
    $url = "https://itunes.apple.com/search?term=$encoded&media=music&entity=$Entity&limit=1"
    try {
        $response = $Client.GetAsync($url).GetAwaiter().GetResult()
    } catch {
        return $null
    }
    if (-not $response.IsSuccessStatusCode) {
        return $null
    }
    $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if ([string]::IsNullOrWhiteSpace($json)) { return $null }
    try {
        $parsed = $json | ConvertFrom-Json
    } catch {
        return $null
    }
    if (-not $parsed -or $parsed.resultCount -lt 1) {
        return $null
    }
    $album = $parsed.results[0].collectionName
    if ($album) {
        $queryCache[$cacheKey] = $album
    }
    return $album
}

function Resolve-Album {
    param(
        [string]$Artist,
        [string]$Title
    )

    $normalizedKey = (Normalize-ComparableText $Artist) + '|' + (Normalize-ComparableText $Title)
    if ($albumCache.ContainsKey($normalizedKey)) {
        return $albumCache[$normalizedKey]
    }

    $cleanArtist = Strip-FeaturingToken $Artist
    $cleanTitle = Strip-FeaturingToken $Title

    $queries = @()
    $queries += @{ term = "$Artist $Title"; entity = 'song' }
    if ($cleanArtist -ne $Artist -or $cleanTitle -ne $Title) {
        $queries += @{ term = "$cleanArtist $cleanTitle"; entity = 'song' }
    }
    $queries += @{ term = "$Artist"; entity = 'album' }
    if ($cleanArtist -ne $Artist) {
        $queries += @{ term = "$cleanArtist"; entity = 'album' }
    }
    $queries += @{ term = "$Title"; entity = 'album' }

    foreach ($query in $queries) {
        $term = $query.term
        $entity = $query.entity
        if ([string]::IsNullOrWhiteSpace($term)) { continue }
        $album = Invoke-ItunesSearch -Client $client -Term $term -Entity $entity
        if ($album) {
            $albumCache[$normalizedKey] = $album
            return $album
        }
    }

    $fallback = "$Title - Single"
    $albumCache[$normalizedKey] = $fallback
    return $fallback
}

$index = 0
foreach ($row in $data) {
    $index++
    if ([string]::IsNullOrWhiteSpace($row.Album)) {
        Write-Progress -Activity 'Resolving album names' -Status "Processing $index of $($data.Count)" -PercentComplete (($index / $data.Count) * 100) -CurrentOperation "$($row.Title) - $($row.Artist)"
        $row.Album = Resolve-Album -Artist $row.Artist -Title $row.Title
    } elseif ($index % 200 -eq 0) {
        Write-Progress -Activity 'Resolving album names' -Status "Processing $index of $($data.Count)" -PercentComplete (($index / $data.Count) * 100) -CurrentOperation 'Skipping (already set)'
    }
}
Write-Progress -Activity 'Resolving album names' -Completed -Status 'Done'

$failures = ($data | Where-Object { [string]::IsNullOrWhiteSpace($_.Album) }).Count
if ($failures -gt 0) {
    Write-Warning "$failures songs still missing album info after processing"
} else {
    Write-Host 'All songs now have album info.'
}

$data | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
$data | ConvertTo-Json -Depth 3 | Set-Content -Path $UpdatedJson -Encoding UTF8
Write-Host "Album fill complete."
