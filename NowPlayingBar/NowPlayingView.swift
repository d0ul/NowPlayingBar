import Combine
import SwiftUI

final class NowPlayingModel: ObservableObject {
    @Published var title = "Nothing Playing"
    @Published var artist = ""
    @Published var album = ""
    @Published var appName = ""
    @Published var isPlaying = false
    @Published var artwork: NSImage?

    @Published var duration: TimeInterval = 0
    @Published var elapsed: TimeInterval = 0
    @Published var isScrubbing = false

    private var baseElapsed: TimeInterval = 0
    private var baseTimestamp: Date = Date()
    private var rate: Double = 0
    private var ticker: Timer?

    private var lastDiscordSignature: String?

    func update(_ np: NowPlaying?) {
        guard let np else {
            title = "Nothing Playing"; artist = ""; album = ""; appName = ""; isPlaying = false; artwork = nil
            duration = 0; elapsed = 0; rate = 0
            ticker?.invalidate(); ticker = nil
            updateDiscordActivity()
            return
        }
        title = np.title ?? "Unknown"
        artist = np.artist ?? ""
        album = np.album ?? ""
        appName = np.appName ?? ""
        isPlaying = np.isPlaying
        artwork = np.artwork.flatMap { NSImage(data: $0) }

        duration = np.duration ?? 0
        rate = np.playbackRate

        if !isScrubbing {
            baseElapsed = np.elapsedTime ?? elapsed
            baseTimestamp = Date()
            elapsed = baseElapsed
        }

        restartTicker()
        updateDiscordActivity()
    }

    func commitSeek(to time: TimeInterval) {
        MediaRemote.shared.seek(to: time)
        baseElapsed = time
        baseTimestamp = Date()
        elapsed = time
        lastDiscordSignature = nil
        updateDiscordActivity()
    }

    private func restartTicker() {
        ticker?.invalidate()
        guard rate > 0, duration > 0 else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, !self.isScrubbing else { return }
            let projected = self.baseElapsed + self.rate * Date().timeIntervalSince(self.baseTimestamp)
            self.elapsed = min(max(projected, 0), self.duration)
        }
    }


    private var trackSequence = 0

    private func updateDiscordActivity() {
        guard DiscordRPC.shared.isEnabled else { return }

        guard !title.isEmpty, title != "Nothing Playing" else {
            trackSequence += 1
            let signature = "cleared"
            if lastDiscordSignature != signature {
                lastDiscordSignature = signature
                DiscordRPC.shared.clearActivity()
            }
            return
        }

        let signature = [title, artist, album, String(isPlaying), String(Int(duration)), String(Int(baseElapsed))]
            .joined(separator: "|")
        guard signature != lastDiscordSignature else { return }
        lastDiscordSignature = signature

        trackSequence += 1
        let sequence = trackSequence

        let start = isPlaying ? baseTimestamp.addingTimeInterval(-baseElapsed) : nil
        let end: Date? = {
            guard isPlaying, duration > 0 else { return nil }
            return baseTimestamp.addingTimeInterval(duration - baseElapsed)
        }()

        let capturedTitle = title
        let capturedArtist = artist
        let capturedAlbum = album

        ITunesArtworkLookup.shared.lookupArtwork(title: capturedTitle, artist: capturedArtist) { [weak self] artworkURL in
            DispatchQueue.main.async {
                guard let self, self.trackSequence == sequence else { return }
                DiscordRPC.shared.setActivity(
                    details: capturedTitle,
                    state: capturedArtist.isEmpty ? nil : capturedArtist,
                    largeImageURL: artworkURL,
                    largeImageText: capturedAlbum.isEmpty ? nil : capturedAlbum,
                    startTimestamp: start,
                    endTimestamp: end,
                    isPlaying: self.isPlaying
                )
            }
        }
    }
}

private func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

struct NowPlayingView: View {
    @ObservedObject var model: NowPlayingModel

    private let controlButtonSize: CGFloat = 22

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Group {
                    if let img = model.artwork {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note")
                            .resizable().aspectRatio(contentMode: .fit).padding(24)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 90, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title).font(.headline).lineLimit(1)
                    Text(model.artist).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                    Text(model.album).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    if !model.appName.isEmpty {
                        Text(model.appName).font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            seekBar

            HStack(spacing: 20) {
                controlButton("backward.fill") { MediaRemote.shared.send(.prev) }
                controlButton(model.isPlaying ? "pause.fill" : "play.fill") {
                    MediaRemote.shared.send(.toggle)
                }
                controlButton("forward.fill") { MediaRemote.shared.send(.next) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 22)
        .frame(width: 300, height: 214)
    }

    private func controlButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .frame(width: controlButtonSize, height: controlButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var seekBar: some View {
        let hasDuration = model.duration > 0
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { model.elapsed },
                    set: { model.elapsed = $0 }
                ),
                in: 0...max(model.duration, 0.01),
                onEditingChanged: { editing in
                    model.isScrubbing = editing
                    if !editing {
                        model.commitSeek(to: model.elapsed)
                    }
                }
            )
            .disabled(!hasDuration)

            HStack {
                Text(formatTime(model.elapsed))
                Spacer()
                Text(hasDuration ? formatTime(model.duration) : "--:--")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
    }
}
