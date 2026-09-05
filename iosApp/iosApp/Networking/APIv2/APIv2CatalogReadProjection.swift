import Foundation

/// Explicit projection into existing presentation models. Numeric IDs remain a
/// legacy consumer boundary: reject unsupported opaque values rather than using
/// zero, dropping versions, or changing the watch transport decoder.
private func catalogLegacyID(_ value: String) throws -> Int {
    guard let number = Int(value), number > 0, String(number) == value else {
        throw APIv2Error.unsupportedCatalogReadValue
    }
    return number
}

private func catalogLegacyInt(_ value: Int64) throws -> Int {
    guard let number = Int(exactly: value) else { throw APIv2Error.unsupportedCatalogReadValue }
    return number
}

extension ItemDetail {
    init(catalog value: APIv2CatalogRead.CatalogItemDetail) throws {
        self.contentId = value.contentId
        self.type = value.`type`
        self.status = value.status
        self.title = value.title
        self.sortTitle = value.sortTitle
        self.originalTitle = value.originalTitle
        self.originalLanguage = value.originalLanguage
        self.showStatus = value.showStatus
        self.year = try value.year.map { try catalogLegacyInt($0) }
        self.overview = value.overview
        self.tagline = value.tagline
        self.runtime = try value.runtime.map { try catalogLegacyInt($0) }
        self.contentRating = value.contentRating
        self.genres = value.genres
        self.ratingImdb = value.ratingImdb
        self.ratingTmdb = value.ratingTmdb
        self.ratingRtCritic = try value.ratingRtCritic.map { try catalogLegacyInt($0) }
        self.ratingRtAudience = try value.ratingRtAudience.map { try catalogLegacyInt($0) }
        self.imdbId = value.imdbId
        self.tmdbId = value.tmdbId
        self.tvdbId = value.tvdbId
        self.cast = try value.cast.map { try CastMember(catalog: $0) }
        self.crew = try value.crew.map { try CrewMember(catalog: $0) }
        self.studios = value.studios
        self.networks = value.networks
        self.countries = value.countries
        self.releaseDate = value.releaseDate
        self.firstAirDate = value.firstAirDate
        self.lastAirDate = value.lastAirDate
        self.posterUrl = value.posterUrl
        self.posterThumbhash = value.posterThumbhash
        self.backdropUrl = value.backdropUrl
        self.backdropThumbhash = value.backdropThumbhash
        self.logoUrl = value.logoUrl
        self.seasonCount = try value.seasonCount.map { try catalogLegacyInt($0) }
        self.seriesId = value.seriesId
        self.seriesTitle = value.seriesTitle
        self.seasonNumber = try value.seasonNumber.map { try catalogLegacyInt($0) }
        self.episodeNumber = try value.episodeNumber.map { try catalogLegacyInt($0) }
        self.episodeCount = try value.episodeCount.map { try catalogLegacyInt($0) }
        self.airDate = value.airDate
        self.isSpecials = value.isSpecials
        self.userData = try value.userData.map { try LeafItemUserData(catalog: $0) }
        self.versions = try value.versions.map { try FileVersion(catalog: $0) }
        self.subtitles = try value.subtitles.map { try SubtitleInfoBasic(catalog: $0) }
        self.intro = try value.intro.map { try TimeRange(catalog: $0) }
        self.credits = try value.credits.map { try TimeRange(catalog: $0) }
        self.effectiveSubtitleMode = value.effectiveSubtitleMode
        self.effectiveShowForcedSubtitles = value.effectiveShowForcedSubtitles
        self.effectiveSubtitleTrackSignature = try value.effectiveSubtitleTrackSignature.map { try SubtitleTrackSignature(catalog: $0) }
        self.overlaySummary = try value.overlaySummary.map { try OverlaySummary(catalog: $0) }
        self.audiobook = try value.audiobook.map { try AudiobookDetail(catalog: $0) }
        self.pendingTranslationLanguage = value.pendingTranslationLanguage
        self.videos = try value.videos.map { try $0.map { try ItemVideo(catalog: $0) } }
        self.extras = try value.extras.map { try $0.map { try ItemExtra(catalog: $0) } }
    }
}

extension Season {
    init(catalog value: APIv2CatalogRead.Season) throws {
        self.contentId = value.contentId
        self.seasonNumber = try catalogLegacyInt(value.seasonNumber)
        self.isSpecials = value.isSpecials
        self.title = value.title
        self.overview = value.overview
        self.airDate = value.airDate
        self.episodeCount = try catalogLegacyInt(value.episodeCount)
        self.posterUrl = value.posterUrl
        self.posterThumbhash = value.posterThumbhash
        self.userData = try value.userData.map { try SeasonUserData(catalog: $0) }
    }
}

extension EpisodeListItem {
    init(catalog value: APIv2CatalogRead.Episode) throws {
        self.contentId = value.contentId
        self.seasonNumber = try catalogLegacyInt(value.seasonNumber)
        self.episodeNumber = try catalogLegacyInt(value.episodeNumber)
        self.title = value.title
        self.overview = value.overview
        self.airDate = value.airDate
        self.runtime = try catalogLegacyInt(value.runtime)
        self.imdbId = value.imdbId
        self.tmdbId = value.tmdbId
        self.tvdbId = value.tvdbId
        self.stillUrl = value.stillUrl
        self.stillThumbhash = value.stillThumbhash
        self.userData = try value.userData.map { try LeafItemUserData(catalog: $0) }
        self.files = try value.files.map { try $0.map { try EpisodeFile(catalog: $0) } }
    }
}

extension Person {
    init(catalog value: APIv2CatalogRead.Person) throws {
        self.id = try catalogLegacyID(value.id)
        self.name = value.name
        self.bio = value.bio
        self.birthDate = value.birthDate
        self.deathDate = value.deathDate
        self.birthplace = value.birthplace
        self.homepage = value.homepage
        self.photoUrl = value.photoUrl
        self.photoThumbhash = value.photoThumbhash
        self.tmdbId = value.tmdbId
        self.imdbId = value.imdbId
        self.tvdbId = value.tvdbId
        self.plexGuid = value.plexGuid
    }
}

extension CastMember {
    init(catalog value: APIv2CatalogRead.CastCredit) throws {
        self.name = value.name
        self.character = value.character
        self.order = try catalogLegacyInt(value.order)
        self.personId = value.personId
        self.tmdbId = value.tmdbId
        self.tvdbId = value.tvdbId
        self.imdbId = value.imdbId
        self.photoUrl = value.photoUrl
        self.photoThumbhash = value.photoThumbhash
    }
}

extension CrewMember {
    init(catalog value: APIv2CatalogRead.CrewCredit) throws {
        self.name = value.name
        self.job = value.job
        self.personId = value.personId
        self.tmdbId = value.tmdbId
        self.tvdbId = value.tvdbId
        self.imdbId = value.imdbId
        self.photoUrl = value.photoUrl
        self.photoThumbhash = value.photoThumbhash
    }
}

extension LeafItemUserData {
    init(catalog value: APIv2CatalogRead.WatchRollup) throws {
        self.played = value.played
        self.isInProgress = value.isInProgress
        self.positionSeconds = value.positionSeconds
        self.durationSeconds = value.durationSeconds
        self.lastFileId = try value.lastFileId.map { try catalogLegacyID($0) }
        self.lastResolution = value.lastResolution
        self.lastHdr = value.lastHdr
        self.lastCodecVideo = value.lastCodecVideo
    }
}

extension FileVersion {
    init(catalog value: APIv2CatalogRead.FileVersion) throws {
        self.fileId = try catalogLegacyID(value.fileId)
        self.fileName = value.fileName
        self.resolution = value.resolution
        self.codecVideo = value.codecVideo
        self.codecAudio = value.codecAudio
        self.hdr = value.hdr
        self.container = value.container
        self.fileSize = value.fileSize
        self.duration = Double(value.duration)
        self.bitrate = try catalogLegacyInt(value.bitrate)
        self.videoTracks = try value.videoTracks.map { try $0.map { try VideoTrack(catalog: $0) } }
        self.audioTracks = try value.audioTracks.map { try $0.map { try AudioTrack(catalog: $0) } }
        self.subtitleTracks = try value.subtitleTracks.map { try $0.map { try SubtitleTrack(catalog: $0) } }
        self.chapters = try value.chapters.map { try $0.map { try VersionChapter(catalog: $0) } }
        self.intro = try value.intro.map { try TimeRange(catalog: $0) }
        self.credits = try value.credits.map { try TimeRange(catalog: $0) }
        self.presentationKind = value.presentationKind
        self.presentationGroupKey = value.presentationGroupKey
        self.presentationPartIndex = try value.presentationPartIndex.map { try catalogLegacyInt($0) }
        self.presentationPartTotal = try value.presentationPartTotal.map { try catalogLegacyInt($0) }
        self.editionRaw = value.editionRaw
        self.editionKey = value.editionKey
        self.edition = nil
        self.effectiveAudioTrackIndex = try value.effectiveAudioTrackIndex.map { try catalogLegacyInt($0) }
        self.effectiveAudioLanguage = value.effectiveAudioLanguage
    }
}

extension SubtitleInfoBasic {
    init(catalog value: APIv2CatalogRead.SubtitleInfo) throws {
        self.source = value.source
        self.language = value.language
        self.codec = value.codec
        self.forced = value.forced
        self.title = value.title
    }
}

extension TimeRange {
    init(catalog value: APIv2CatalogRead.Marker) throws {
        self.start = value.start
        self.end = value.end
    }
}

extension SubtitleTrackSignature {
    init(catalog value: APIv2CatalogRead.WatchSubtitleSignature) throws {
        self.source = value.source
        self.language = value.language
        self.codec = value.codec
        self.label = value.label
        self.forced = value.forced
        self.hearingImpaired = value.hearingImpaired
    }
}

extension OverlaySummary {
    init(catalog value: APIv2CatalogRead.CatalogItemOverlay) throws {
        self.resolution = value.resolution
        self.hdr = value.hdr
        self.audio = value.audio
        self.audioChannels = value.audioChannels
        self.videoCodec = value.videoCodec
        self.container = value.container
        self.aspectRatio = value.aspectRatio
        self.releaseType = value.releaseType
        self.edition = value.edition
        self.multiAudio = value.multiAudio
        self.multiSub = value.multiSub
    }
}

extension AudiobookDetail {
    init(catalog value: APIv2CatalogRead.AudiobookDetailExtension) throws {
        self.authors = try value.authors.map { try AudiobookPerson(catalog: $0) }
        self.narrators = try value.narrators.map { try AudiobookPerson(catalog: $0) }
        self.publisher = value.publisher
        self.totalDurationSeconds = try catalogLegacyInt(value.totalDurationSeconds)
        self.series = try value.series.map { try AudiobookSeriesGroup(catalog: $0) }
        self.otherNarrations = try value.otherNarrations.map { try AudiobookNarration(catalog: $0) }
        self.related = try AudiobookRelatedContent(catalog: value.related)
    }
}

extension ItemVideo {
    init(catalog value: APIv2CatalogRead.ItemVideoInfo) throws {
        self.kind = value.kind
        self.site = value.site
        self.siteKey = value.siteKey
        self.name = value.name
        self.language = value.language
        self.isOfficial = value.isOfficial
    }
}

extension ItemExtra {
    init(catalog value: APIv2CatalogRead.ItemExtraInfo) throws {
        self.contentId = value.contentId
        self.kind = value.kind
        self.title = value.title
        self.durationSeconds = try value.durationSeconds.map { try catalogLegacyInt($0) }
        self.fileId = try value.fileId.map { try catalogLegacyInt($0) }
    }
}

extension SeasonUserData {
    init(catalog value: APIv2CatalogRead.WatchRollup) throws {
        self.played = value.played
        self.watchedCount = try catalogLegacyInt(value.watchedCount)
        self.unplayedCount = try catalogLegacyInt(value.unplayedCount)
        self.inProgressCount = try catalogLegacyInt(value.inProgressCount)
    }
}

extension EpisodeFile {
    init(catalog value: APIv2CatalogRead.EpisodeFile) throws {
        self.fileId = try catalogLegacyID(value.fileId)
        self.resolution = value.resolution
        self.codecVideo = value.codecVideo
        self.hdr = value.hdr
        self.audioChannels = try value.audioChannels.map { try catalogLegacyInt($0) }
        self.container = value.container
        self.fileSize = value.fileSize
    }
}

extension VideoTrack {
    init(catalog value: APIv2CatalogRead.VideoTrack) throws {
        self.index = nil
        self.codec = value.codec
        self.width = try value.width.map { try catalogLegacyInt($0) }
        self.height = try value.height.map { try catalogLegacyInt($0) }
        self.frameRate = value.frameRate
        self.bitrate = try value.bitrate.map { try catalogLegacyInt($0) }
        self.profile = value.profile
        self.level = try value.level.map { try catalogLegacyInt($0) }
        self.bitDepth = try value.bitDepth.map { try catalogLegacyInt($0) }
        self.colorRange = value.colorRange
        self.colorSpace = value.colorSpace
        self.colorPrimaries = value.colorPrimaries
        self.colorTransfer = value.colorTransfer
        self.videoRange = value.videoRange
        self.dolbyVision = value.dolbyVision
        self.title = value.title
        self.language = nil
    }
}

extension AudioTrack {
    init(catalog value: APIv2CatalogRead.AudioTrack) throws {
        self.index = nil
        self.codec = value.codec
        self.channels = try value.channels.map { try catalogLegacyInt($0) }
        self.channelLayout = value.layout
        self.bitrate = try value.bitrate.map { try catalogLegacyInt($0) }
        self.sampleRate = try value.sampleRate.map { try catalogLegacyInt($0) }
        self.language = value.language
        self.title = value.title
        self.embeddedTitle = value.embeddedTitle
        self.isDefault = value.`default`
    }
}

extension SubtitleTrack {
    init(catalog value: APIv2CatalogRead.VersionSubtitleTrack) throws {
        self.index = try value.index.map { try catalogLegacyInt($0) }
        self.codec = value.codec
        self.language = value.language
        self.title = value.title
        self.embeddedTitle = value.embeddedTitle
        self.forced = value.forced
        self.hearingImpaired = value.hearingImpaired
        self.isDefault = value.`default`
        self.external = value.external
        self.externalPath = value.fileName
    }
}

extension VersionChapter {
    init(catalog value: APIv2CatalogRead.VersionChapter) throws {
        self.index = try catalogLegacyInt(value.index)
        self.title = value.title
        self.startSeconds = value.startSeconds
        self.endSeconds = value.endSeconds
        self.source = value.source
        self.thumbnailUrl = value.thumbnailUrl
        self.thumbnailThumbhash = value.thumbnailThumbhash
    }
}

extension AudiobookPerson {
    init(catalog value: APIv2CatalogRead.AudiobookPerson) throws {
        self.personId = value.personId
        self.name = value.name
        self.photoUrl = value.photoUrl
        self.photoThumbhash = value.photoThumbhash
    }
}

extension AudiobookSeriesGroup {
    init(catalog value: APIv2CatalogRead.AudiobookSeriesGroup) throws {
        self.name = value.name
        self.entries = try value.entries.map { try AudiobookRelatedItem(catalog: $0) }
    }
}

extension AudiobookNarration {
    init(catalog value: APIv2CatalogRead.AudiobookNarration) throws {
        self.contentId = value.contentId
        self.title = value.title
        self.year = try value.year.map { try catalogLegacyInt($0) }
        self.narrators = value.narrators
    }
}

extension AudiobookRelatedContent {
    init(catalog value: APIv2CatalogRead.AudiobookRelatedContent) throws {
        self.alsoByAuthor = try value.alsoByAuthor.map { try AudiobookRelatedItem(catalog: $0) }
        self.similar = try value.similar.map { try AudiobookRelatedItem(catalog: $0) }
    }
}

extension AudiobookRelatedItem {
    init(catalog value: APIv2CatalogRead.AudiobookRelatedItem) throws {
        self.contentId = value.contentId
        self.title = value.title
        self.year = try value.year.map { try catalogLegacyInt($0) }
        self.posterUrl = value.posterUrl
        self.seriesIndex = try value.seriesIndex.map { try catalogLegacyInt($0) }
    }
}

extension SeasonsResponse {
    init(catalog items: [APIv2CatalogRead.Season]) throws {
        seasons = try items.map { try Season(catalog: $0) }
    }
}

extension EpisodesResponse {
    init(catalog items: [APIv2CatalogRead.Episode]) throws {
        episodes = try items.map { try EpisodeListItem(catalog: $0) }
    }
}
