import Foundation

enum MenuBarDisplayMode: String, CaseIterable {
    case albumOnly
    case albumAndTitle
    case titleOnly

    var menuTitle: String {
        switch self {
        case .albumOnly:
            return String(localized: "menu.displayMode.albumOnly", defaultValue: "Album Only")
        case .albumAndTitle:
            return String(localized: "menu.displayMode.albumAndTitle", defaultValue: "Album + Title")
        case .titleOnly:
            return String(localized: "menu.displayMode.titleOnly", defaultValue: "Title Only")
        }
    }

    func text(title: String?, album: String?) -> String {
        switch self {
        case .albumOnly:
            return album ?? ""
        case .albumAndTitle:
            let a = album ?? ""
            let t = title ?? ""
            if a.isEmpty { return t }
            if t.isEmpty { return a }
            return "\(a) — \(t)"
        case .titleOnly:
            return title ?? ""
        }
    }
}

enum AppSettings {
    private static let displayModeKey = "menuBarDisplayMode"
    private static let discordEnabledKey = "discordRPCEnabled"

    static var displayMode: MenuBarDisplayMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: displayModeKey),
                  let mode = MenuBarDisplayMode(rawValue: raw) else {
                return .albumAndTitle
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: displayModeKey)
        }
    }

    static var isDiscordRPCEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: discordEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: discordEnabledKey) }
    }
}
