param(
    [string]$InputCsv = 'aggregated_playlist_youtube.csv',
    [string]$OutputCsv = 'aggregated_playlist_youtube.csv',
    [string]$UpdatedJson = 'aggregated_playlist_youtube.json'
)

$ErrorActionPreference = 'Stop'

function Normalize-Key {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $lower = $Value.ToLowerInvariant()
    $lower = [System.Text.RegularExpressions.Regex]::Replace($lower, "[\u2019'`"]", '')
    $lower = [System.Text.RegularExpressions.Regex]::Replace($lower, "[\p{P}\p{S}]", ' ')
    $lower = [System.Text.RegularExpressions.Regex]::Replace($lower, '\s+', ' ')
    return $lower.Trim()
}

function Split-ArtistVariants {
    param([string]$Artist)
    if ([string]::IsNullOrWhiteSpace($Artist)) { return @() }
    $clean = $Artist -replace '(?i)feat\.?', '&' -replace '(?i)with', '&' -replace '(?i) x ', ' &' -replace '(?i)×', '&'
    $parts = $clean -split '[\\/&,+]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    return $parts
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
            $children = $trackNode.ChildNodes
            $props = @{}
            for ($j = 0; $j -lt $children.Count; $j += 2) {
                $props[$children.Item($j).InnerText] = $children.Item($j + 1).InnerText
            }
            if (-not $props.ContainsKey('Name')) { continue }
            $title = $props['Name']
            $artist = $props['Artist']
            if (-not $artist -and $props.ContainsKey('Album Artist')) { $artist = $props['Album Artist'] }
            $album = $props['Album']
            if ([string]::IsNullOrWhiteSpace($title) -or [string]::IsNullOrWhiteSpace($artist) -or [string]::IsNullOrWhiteSpace($album)) { continue }
            $key = (Normalize-Key "$artist|$title")
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

$byExact = @{}
$byTitle = @{}
$byArtistTitle = @{}

foreach ($row in $data) {
    $exactKey = Normalize-Key "${($row.Artist)}|${($row.Title)}"
    if (-not [string]::IsNullOrWhiteSpace($row.Album)) {
        if (-not $byExact.ContainsKey($exactKey)) {
            $byExact[$exactKey] = $row.Album
        }
        $titleKey = Normalize-Key $row.Title
        if (-not $byTitle.ContainsKey($titleKey)) {
            $byTitle[$titleKey] = $row.Album
        }
        foreach ($artistPart in Split-ArtistVariants $row.Artist) {
            $variantKey = Normalize-Key "$artistPart|$($row.Title)"
            if (-not $byArtistTitle.ContainsKey($variantKey)) {
                $byArtistTitle[$variantKey] = $row.Album
            }
        }
    }
}

$updated = 0
foreach ($row in $data) {
    if (-not [string]::IsNullOrWhiteSpace($row.Album)) { continue }
    $title = $row.Title
    $artist = $row.Artist
    $exactKey = Normalize-Key "$artist|$title"

    $album = $null
    if ($libraryAlbumMap.ContainsKey($exactKey)) {
        $album = $libraryAlbumMap[$exactKey]
    }
    if (-not $album -and $byExact.ContainsKey($exactKey)) {
        $album = $byExact[$exactKey]
    }
    if (-not $album) {
        foreach ($artistPart in Split-ArtistVariants $artist) {
            $variantKey = Normalize-Key "$artistPart|$title"
            if ($byArtistTitle.ContainsKey($variantKey)) {
                $album = $byArtistTitle[$variantKey]
                break
            }
            if (-not $album -and $libraryAlbumMap.ContainsKey($variantKey)) {
                $album = $libraryAlbumMap[$variantKey]
                break
            }
        }
    }
    if (-not $album) {
        $titleKey = Normalize-Key $title
        if ($byTitle.ContainsKey($titleKey)) {
            $album = $byTitle[$titleKey]
        }
    }
    if (-not $album) {
        $album = "$title - Single"
    }
    $row.Album = $album
    $updated++
}

$missingAfter = ($data | Where-Object { [string]::IsNullOrWhiteSpace($_.Album) }).Count
if ($missingAfter -gt 0) {
    Write-Warning "$missingAfter songs still missing album info after heuristics"
} else {
    Write-Host "Filled album info for $updated songs."
}

$data | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
$data | ConvertTo-Json -Depth 3 | Set-Content -Path $UpdatedJson -Encoding UTF8
Write-Host "Album fill complete."
