import AppKit
import MediaRemoteAdapter

enum MRCmd {
    case play, pause, toggle, stop, next, prev
}

struct NowPlaying {
    let title: String?
    let artist: String?
    let album: String?
    let artwork: Data?
    let appName: String?
    let isPlaying: Bool
    let duration: TimeInterval?
    let elapsedTime: TimeInterval?
    let playbackRate: Double
}

final class MediaRemote {
    static let shared = MediaRemote()

    private let controller = MediaController()
    private var latestArtworkCache: (identifier: String?, data: Data?) = (nil, nil)

    private init() {}

    func register(onUpdate: @escaping (NowPlaying?) -> Void) {
        controller.onTrackInfoReceived = { [weak self] trackInfo in
            guard let self else { return }
            onUpdate(self.map(trackInfo))
        }
        controller.onListenerTerminated = {
            FileHandle.standardError.write("MediaRemoteAdapter listener terminated\n".data(using: .utf8)!)
        }
        controller.startListening()
    }

    func fetchInfo(_ cb: @escaping (NowPlaying?) -> Void) {
        controller.getTrackInfo { [weak self] trackInfo in
            guard let self else { cb(nil); return }
            cb(self.map(trackInfo))
        }
    }

    func send(_ cmd: MRCmd) {
        switch cmd {
        case .play: controller.play()
        case .pause: controller.pause()
        case .toggle: controller.togglePlayPause()
        case .stop: controller.stop()
        case .next: controller.nextTrack()
        case .prev: controller.previousTrack()
        }
    }

    func seek(to seconds: TimeInterval) {
        controller.setTime(seconds: max(0, seconds))
    }

    private func map(_ trackInfo: TrackInfo?) -> NowPlaying? {
        guard let trackInfo else { return nil }
        let p = trackInfo.payload
        let artworkData: Data?
        if let img = p.artwork, let tiff = img.tiffRepresentation {
            artworkData = tiff
            latestArtworkCache = (p.title, tiff)
        } else if latestArtworkCache.identifier == p.title {
            artworkData = latestArtworkCache.data
        } else {
            artworkData = nil
        }

        let durationSeconds: TimeInterval?
        if let micros = p.durationMicros, micros > 0 {
            durationSeconds = micros / 1_000_000
        } else {
            durationSeconds = nil
        }

        return NowPlaying(
            title: p.title,
            artist: p.artist,
            album: p.album,
            artwork: artworkData,
            appName: p.applicationName,
            isPlaying: p.isPlaying ?? ((p.playbackRate ?? 0) > 0),
            duration: durationSeconds,
            elapsedTime: p.currentElapsedTime,
            playbackRate: p.playbackRate ?? 0
        )
    }
}
