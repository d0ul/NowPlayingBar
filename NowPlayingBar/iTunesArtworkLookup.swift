import Foundation

final class ITunesArtworkLookup {
    static let shared = ITunesArtworkLookup()

    private init() {}

    private struct CacheEntry {
        let url: String?
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheQueue = DispatchQueue(label: "ITunesArtworkLookup.cache")

    private var debounceWorkItem: DispatchWorkItem?
    private let debounceDelay: TimeInterval = 0.4

    private var currentTask: URLSessionDataTask?

    func lookupArtwork(title: String, artist: String, completion: @escaping (String?) -> Void) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            completion(nil)
            return
        }

        let key = "\(trimmedTitle)|\(trimmedArtist)".lowercased()

        if let cached = cacheQueue.sync(execute: { cache[key] }) {
            completion(cached.url)
            return
        }

        debounceWorkItem?.cancel()
        currentTask?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.performLookup(title: trimmedTitle, artist: trimmedArtist, key: key, completion: completion)
        }
        debounceWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + debounceDelay, execute: workItem)
    }

    private func performLookup(title: String, artist: String, key: String, completion: @escaping (String?) -> Void) {
        let term = artist.isEmpty ? title : "\(title) \(artist)"
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5")
        ]

        guard let url = components.url else {
            completion(nil)
            return
        }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                if (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                self.log("lookup failed for '\(term)': \(error.localizedDescription)")
                self.store(nil, for: key)
                completion(nil)
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                self.log("lookup for '\(term)' returned no parseable results")
                self.store(nil, for: key)
                completion(nil)
                return
            }

            let bestMatch = self.pickBestMatch(results, title: title, artist: artist)
            let artworkURL = bestMatch.flatMap { self.highResArtworkURL(from: $0) }

            if artworkURL == nil {
                self.log("no artwork match for '\(term)' (got \(results.count) results)")
            }

            self.store(artworkURL, for: key)
            completion(artworkURL)
        }
        currentTask = task
        task.resume()
    }

    private func pickBestMatch(_ results: [[String: Any]], title: String, artist: String) -> [String: Any]? {
        guard !artist.isEmpty else { return results.first }

        let normalizedArtist = artist.lowercased()
        if let exact = results.first(where: {
            guard let resultArtist = ($0["artistName"] as? String)?.lowercased() else { return false }
            return resultArtist == normalizedArtist
                || resultArtist.contains(normalizedArtist)
                || normalizedArtist.contains(resultArtist)
        }) {
            return exact
        }
        return results.first
    }

    private func highResArtworkURL(from result: [String: Any]) -> String? {
        guard let thumb = result["artworkUrl100"] as? String else { return nil }
        return thumb.replacingOccurrences(of: "100x100bb", with: "600x600bb")
    }

    private func store(_ url: String?, for key: String) {
        cacheQueue.sync {
            cache[key] = CacheEntry(url: url)
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write("[ITunesArtworkLookup] \(message)\n".data(using: .utf8)!)
    }
}
