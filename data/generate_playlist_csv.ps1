param(
    [string]$OutputPath = "aggregated_playlist_youtube.csv"
)

$ErrorActionPreference = 'Stop'

function Normalize-ComparableString {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $trimmed = $Value.Trim()
    $collapsed = [System.Text.RegularExpressions.Regex]::Replace($trimmed, '\s+', ' ')
    return $collapsed.ToLowerInvariant()
}

function Get-NormalizedKey {
    param(
        [Parameter(Mandatory = $true)][string]$Artist,
        [Parameter(Mandatory = $true)][string]$Title
    )
    return (Normalize-ComparableString -Value $Artist) + '|' + (Normalize-ComparableString -Value $Title)
}

function Convert-PlistDictToHashtable {
    param([System.Xml.XmlNode]$Node)
    $result = @{}
    if (-not $Node) { return $result }
    $children = $Node.ChildNodes
    for ($i = 0; $i -lt $children.Count; $i += 2) {
        $keyNode = $children.Item($i)
        $valueNode = $children.Item($i + 1)
        if (-not $keyNode -or -not $valueNode) { continue }
        $key = $keyNode.InnerText
        if (-not $key) { continue }
        $value = switch ($valueNode.Name) {
            'string' { $valueNode.InnerText }
            'integer' { $valueNode.InnerText }
            'date' { $valueNode.InnerText }
            'true' { $true }
            'false' { $false }
            default { $valueNode.InnerText }
        }
        $result[$key] = $value
    }
    return $result
}

function Build-LibraryAlbumMap {
    param([string[]]$LibraryFiles)
    $map = @{}
    foreach ($file in $LibraryFiles) {
        if (-not (Test-Path -Path $file)) { continue }
        try {
            [xml]$library = Get-Content -Path $file
        } catch {
            Write-Warning "Unable to parse library file '$file': $_"
            continue
        }
        $rootDict = $library.plist.dict
        if (-not $rootDict) { continue }
        $children = $rootDict.ChildNodes
        $tracksDict = $null
        for ($i = 0; $i -lt $children.Count; $i += 2) {
            if ($children.Item($i).InnerText -eq 'Tracks') {
                $tracksDict = $children.Item($i + 1)
                break
            }
        }
        if (-not $tracksDict) { continue }
        for ($i = 0; $i -lt $tracksDict.ChildNodes.Count; $i += 2) {
            $trackDictNode = $tracksDict.ChildNodes.Item($i + 1)
            $props = Convert-PlistDictToHashtable -Node $trackDictNode
            if (-not $props.ContainsKey('Name')) { continue }
            $name = $props['Name']
            $artist = $props['Artist']
            if (-not $artist -and $props.ContainsKey('Album Artist')) { $artist = $props['Album Artist'] }
            $album = $props['Album']
            if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($artist) -or [string]::IsNullOrWhiteSpace($album)) { continue }
            $key = Get-NormalizedKey -Artist $artist -Title $name
            if (-not $map.ContainsKey($key)) {
                $map[$key] = $album.Trim()
            }
        }
    }
    return $map
}

function Extract-ArtistTitleFromLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $pairs = @(
        @{ Open = '《'; Close = '》' },
        @{ Open = '「'; Close = '」' },
        @{ Open = '“'; Close = '”' },
        @{ Open = '"'; Close = '"' },
        @{ Open = '«'; Close = '»' }
    )
    foreach ($pair in $pairs) {
        $open = $pair.Open
        $close = $pair.Close
        $start = $Line.IndexOf($open)
        if ($start -lt 0) { continue }
        $end = $Line.IndexOf($close, $start + $open.Length)
        if ($end -le $start) { continue }
        $artist = $Line.Substring(0, $start).Trim()
        $title = $Line.Substring($start + $open.Length, $end - $start - $open.Length).Trim()
        if (-not [string]::IsNullOrWhiteSpace($artist) -and -not [string]::IsNullOrWhiteSpace($title)) {
            return @($artist, $title)
        }
    }
    return $null
}

$libraryFiles = @('Library.xml', 'Library_Bartholomew.xml', '资料库.xml', '???.xml') | Where-Object { Test-Path -Path $_ }
$script:LibraryAlbumMap = Build-LibraryAlbumMap -LibraryFiles $libraryFiles
$script:SongTable = @{}

function Add-Song {
    param([string]$Title, [string]$Artist, [string]$Album)
    if ([string]::IsNullOrWhiteSpace($Title) -or [string]::IsNullOrWhiteSpace($Artist)) { return }
    $normalizedKey = Get-NormalizedKey -Artist $Artist -Title $Title
    $cleanTitle = $Title.Trim()
    $cleanArtist = $Artist.Trim()
    $cleanAlbum = if ([string]::IsNullOrWhiteSpace($Album)) { '' } else { $Album.Trim() }
    if (-not $SongTable.ContainsKey($normalizedKey)) {
        if (-not $cleanAlbum -and $LibraryAlbumMap.ContainsKey($normalizedKey)) {
            $cleanAlbum = $LibraryAlbumMap[$normalizedKey]
        }
        $SongTable[$normalizedKey] = [pscustomobject]@{
            Title = $cleanTitle
            Artist = $cleanArtist
            Album = $cleanAlbum
        }
    } else {
        if ([string]::IsNullOrWhiteSpace($SongTable[$normalizedKey].Album)) {
            if ($cleanAlbum) {
                $SongTable[$normalizedKey].Album = $cleanAlbum
            } elseif ($LibraryAlbumMap.ContainsKey($normalizedKey)) {
                $SongTable[$normalizedKey].Album = $LibraryAlbumMap[$normalizedKey]
            }
        }
    }
}

foreach ($file in Get-ChildItem -Filter 'Replay *.txt' -File) {
    $rows = Import-Csv -Path $file.FullName -Delimiter ([char]9) -Encoding Unicode
    foreach ($row in $rows) {
        Add-Song -Title $row.Name -Artist $row.Artist -Album $row.Album
    }
}

if (Test-Path -Path 'Netease Playlists.csv') {
    $rows = Import-Csv -Path 'Netease Playlists.csv' -Header 'Artist', 'Title'
    foreach ($row in $rows) {
        $title = $row.Title
        $artist = $row.Artist
        if ([string]::IsNullOrWhiteSpace($title) -or $title.Trim().StartsWith('====')) { continue }
        if ([string]::IsNullOrWhiteSpace($artist) -or $artist.Trim().StartsWith('====')) { continue }
        Add-Song -Title $title -Artist $artist -Album ''
    }
}

if (Test-Path -Path 'test.csv') {
    $rows = Import-Csv -Path 'test.csv'
    foreach ($row in $rows) {
        $title = $row.'Track Name'
        $artist = $row.'Artist Name(s)'
        if ([string]::IsNullOrWhiteSpace($title) -or $title.Trim().StartsWith('====')) { continue }
        Add-Song -Title $title -Artist $artist -Album ''
    }
}

if (Test-Path -Path 'Netease Playlists.txt') {
    foreach ($line in Get-Content -Path 'Netease Playlists.txt') {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('====')) { continue }
        $values = Extract-ArtistTitleFromLine -Line $trimmed
        if ($values) {
            Add-Song -Title $values[1] -Artist $values[0] -Album ''
        }
    }
}

$results = foreach ($item in $SongTable.GetEnumerator()) {
    $song = $item.Value
    $query = [System.Uri]::EscapeDataString("$($song.Artist) $($song.Title)")
    [pscustomobject]@{
        Title = $song.Title
        Artist = $song.Artist
        Album = $song.Album
        YouTubeMusicUrl = "https://music.youtube.com/search?q=$query"
    }
}

$sorted = $results | Sort-Object Artist, Title
$sorted | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Host "Wrote $($sorted.Count) songs to $OutputPath"
