import AVFoundation
import Foundation

/// Track metadata (R9).
///
/// Tags lead, filenames are the fallback. Measured on a real 1,009-file library:
/// 946 tracks had usable tags and 62 did not. Filename-first would be wrong,
/// because files like `02 - O Ganso.mp3` carry a useless name and correct tags.
public struct TrackMetadata: Codable, Hashable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    /// Optional so an existing library still decodes after this was added;
    /// see Store.swift on why new fields must never be required.
    public var genre: String?
    public var duration: Double
    /// Featured artist lifted out of the title, e.g. "(feat. X)".
    public var featured: String?
    /// Artist split on multi-artist separators.
    public var artists: [String]
    /// Canonical key so one artist written several ways collapses to one entity.
    public var artistKey: String
    /// Folded key covering title, artist and album for search (R12).
    public var searchKey: String
    /// Where the values came from, for diagnostics.
    public var source: Source

    public enum Source: String, Codable, Sendable { case tags, filename, mixed }

    public static let unknownArtist = "Unknown Artist"
    public static let unknownAlbum = "Unknown Album"
}

public enum MetadataParser {

    // MARK: - Filename shapes seen in the wild

    /// "02 - Title", "13. Title", "07_Title"
    private static let trackPrefix = try! NSRegularExpression(
        pattern: #"^\s*(\d{1,3})\s*[-._)]\s*"#)
    /// "06 Title" inside an "Artist - Album - 06 Title" layout
    private static let trackBare = try! NSRegularExpression(
        pattern: #"^\s*(\d{1,3})\s+"#)
    /// "(feat. X)", "ft. X", "featuring X", "with X"
    private static let featured = try! NSRegularExpression(
        pattern: #"\s*[\(\[]?\s*(?:feat\.?|ft\.?|featuring|with)\s+([^\)\]]+)[\)\]]?\s*"#,
        options: [.caseInsensitive])
    /// Multi-artist separators. Deliberately not English-only: "Elis Regina e
    /// Tom Jobim" uses Portuguese "e", and "King Gizzard & The Lizard Wizard"
    /// uses "&" as part of one name, which is why splitting is advisory and the
    /// full string is always kept as the display artist.
    private static let multiArtist = try! NSRegularExpression(
        pattern: #"\s+(?:&|and|e|y|x|vs\.?|,)\s+"#, options: [.caseInsensitive])

    private static func replacing(_ re: NSRegularExpression, in s: String,
                                  with t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                    withTemplate: t)
    }

    private static func firstGroup(_ re: NSRegularExpression, in s: String) -> String? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r]).trimmingCharacters(in: .whitespaces)
    }

    /// Collapse an artist's spelling variants into one stable key.
    /// Display always keeps the original string; only grouping uses this.
    public static func canonicalArtist(_ name: String) -> String {
        var n = replacing(featured, in: name, with: " ")
        n = SearchKey.fold(n)
        if n.hasPrefix("the ") { n = String(n.dropFirst(4)) }
        let stripped = n.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : " "
        }
        return String(stripped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Parse the shapes actually present in a messy library.
    /// Returns nil fields rather than guessing when a shape is unrecognised.
    public static func parseFilename(_ stem: String)
        -> (artist: String?, album: String?, title: String, track: Int?) {

        let parts = stem.components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // "Artist - Album - NN Title" is the dominant shape in this library.
        if parts.count >= 3 {
            let artist = parts[0], album = parts[1]
            let last = parts[2...].joined(separator: " - ")
            if let num = firstGroup(trackBare, in: last) {
                return (artist, album, replacing(trackBare, in: last, with: ""), Int(num))
            }
            return (artist, album, last, nil)
        }

        // "Artist - Title", but not "02 - Title"
        if parts.count == 2, Int(parts[0]) == nil {
            return (parts[0], nil, parts[1], nil)
        }

        // "02 - Title" or "13. Title"
        if let num = firstGroup(trackPrefix, in: stem) {
            return (nil, nil, replacing(trackPrefix, in: stem, with: ""), Int(num))
        }

        return (nil, nil, stem, nil)
    }

    #if os(iOS)
    /// Modern async tag reading. This is the path that ships.
    ///
    /// `AVAsset`'s synchronous accessors are deprecated and block; `load(_:)`
    /// is the supported API and lets a large import stay responsive.
    public static func metadata(for url: URL) async -> TrackMetadata {
        let stem = url.deletingPathExtension().lastPathComponent
        let parsed = parseFilename(stem)
        let asset = AVURLAsset(url: url)

        var duration: Double = 0
        if let d = try? await asset.load(.duration) {
            let s = CMTimeGetSeconds(d)
            if s.isFinite, s > 0 { duration = s }
        }

        var tagTitle: String?, tagArtist: String?, tagAlbum: String?
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey?.rawValue,
                      let value = try? await item.load(.stringValue),
                      !value.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                switch key {
                case "title": tagTitle = value
                case "artist": tagArtist = value
                case "albumName": tagAlbum = value
                default: break
                }
            }
        }

        var tagTrack: Int?, tagDisc: Int?, tagAlbumArtist: String?, tagGenre: String?
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                guard let items = try? await asset.loadMetadata(for: format) else { continue }
                for item in items {
                    let k = ((item.key as? String) ?? item.identifier?.rawValue ?? "").lowercased()
                    if k.contains("trk") || k.contains("tracknumber") {
                        if let n = try? await item.load(.numberValue) { tagTrack = n.intValue }
                        else if let s = try? await item.load(.stringValue) {
                            tagTrack = Int(s.split(separator: "/").first.map(String.init) ?? "")
                        }
                    } else if k.contains("disk") || k.contains("discnumber") {
                        if let n = try? await item.load(.numberValue) { tagDisc = n.intValue }
                    } else if k.contains("alb"), k.contains("art") {
                        if let s = try? await item.load(.stringValue), !s.isEmpty {
                            tagAlbumArtist = s
                        }
                    } else if k.contains("gen") || k.contains("tcon") || k == "©gen" {
                        if let s = try? await item.load(.stringValue), !s.isEmpty {
                            tagGenre = s
                        }
                    }
                }
            }
        }

        return assemble(title: tagTitle ?? parsed.title,
                        artist: tagArtist ?? parsed.artist ?? TrackMetadata.unknownArtist,
                        album: tagAlbum ?? parsed.album ?? TrackMetadata.unknownAlbum,
                        albumArtist: tagAlbumArtist,
                        track: tagTrack ?? parsed.track, disc: tagDisc,
                        duration: duration, genre: tagGenre,
                        hadTitleTag: tagTitle != nil, hadArtistTag: tagArtist != nil)
    }
    #endif

    #if !os(iOS)
    /// Synchronous tag reading, used only by the macOS verification build,
    /// whose SDK predates the async `load(_:)` API. Never compiled for iOS.
    public static func metadata(for url: URL) -> TrackMetadata {
        let stem = url.deletingPathExtension().lastPathComponent
        let parsed = parseFilename(stem)

        var tagTitle: String?, tagArtist: String?, tagAlbum: String?
        var tagAlbumArtist: String?, tagTrack: Int?, tagDisc: Int?, tagGenre: String?
        var duration: Double = 0

        let asset = AVURLAsset(url: url)
        let d = CMTimeGetSeconds(asset.duration)
        if d.isFinite, d > 0 { duration = d }

        for item in asset.commonMetadata {
            guard let key = item.commonKey?.rawValue,
                  let value = item.stringValue,
                  !value.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            switch key {
            case "title": tagTitle = value
            case "artist": tagArtist = value
            case "albumName": tagAlbum = value
            default: break
            }
        }

        // Track and disc numbers are format-specific, not in commonMetadata.
        for format in asset.availableMetadataFormats {
            for item in asset.metadata(forFormat: format) {
                let k = ((item.key as? String) ?? item.identifier?.rawValue ?? "").lowercased()
                if k.contains("trk") || k.contains("tracknumber") {
                    if let n = item.numberValue { tagTrack = n.intValue }
                    else if let s = item.stringValue {
                        tagTrack = Int(s.split(separator: "/").first.map(String.init) ?? "")
                    }
                } else if k.contains("disk") || k.contains("discnumber") {
                    if let n = item.numberValue { tagDisc = n.intValue }
                } else if k.contains("alb"), k.contains("art") {
                    if let s = item.stringValue, !s.isEmpty { tagAlbumArtist = s }
                } else if k.contains("gen") || k.contains("tcon") {
                    if let s = item.stringValue, !s.isEmpty { tagGenre = s }
                }
            }
        }

        return assemble(title: tagTitle ?? parsed.title,
                        artist: tagArtist ?? parsed.artist ?? TrackMetadata.unknownArtist,
                        album: tagAlbum ?? parsed.album ?? TrackMetadata.unknownAlbum,
                        albumArtist: tagAlbumArtist,
                        track: tagTrack ?? parsed.track,
                        disc: tagDisc,
                        duration: duration, genre: tagGenre,
                        hadTitleTag: tagTitle != nil,
                        hadArtistTag: tagArtist != nil)
    }

    #endif

    /// Pure assembly step, shared by the tag path and by tests.
    public static func assemble(title: String, artist: String, album: String,
                                albumArtist: String? = nil, track: Int? = nil,
                                disc: Int? = nil, duration: Double = 0,
                                genre: String? = nil,
                                hadTitleTag: Bool = false,
                                hadArtistTag: Bool = false) -> TrackMetadata {
        let source: TrackMetadata.Source
        if hadTitleTag && hadArtistTag { source = .tags }
        else if !hadTitleTag && !hadArtistTag { source = .filename }
        else { source = .mixed }

        let feat = firstGroup(featured, in: title)
        let splits = multiArtist
            .stringByReplacingMatches(in: artist,
                                      range: NSRange(artist.startIndex..., in: artist),
                                      withTemplate: "\u{1}")
            .split(separator: "\u{1}")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return TrackMetadata(
            title: title, artist: artist, album: album,
            albumArtist: albumArtist, trackNumber: track, discNumber: disc,
            genre: genre.flatMap { g in
                let t = g.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            },
            duration: duration, featured: feat,
            artists: splits.isEmpty ? [artist] : splits,
            artistKey: canonicalArtist(artist),
            searchKey: SearchKey.fold("\(title) \(artist) \(album)"),
            source: source)
    }
}
