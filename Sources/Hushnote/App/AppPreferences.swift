import Foundation

/// The app-level appearance override. System leaves the palette under macOS'
/// control; the other values explicitly override it for every Hushnote scene.
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Durable, non-secret application preferences.
///
/// Credentials deliberately do not have a representation here; they remain in
/// the data-protection Keychain. Meeting content remains in SQLite.
struct AppPreferences {
    private enum Key {
        static let provider = "insights.provider"
        static let retainAudio = "recording.retainAudio"
        static let localModelPath = "insights.local.modelPath"
        static let llamaExecutablePath = "insights.local.executablePath"
        static let sidebarDestination = "workspace.sidebarDestination"
        static let meetingTabs = "workspace.meetingTabs"
        static let modelStorageParentPath = "models.storage.parentPath"
        static let appearance = "appearance.mode"
    }

    /// Shared with the root scene and Settings' observing `@AppStorage`.
    /// Keeping one key here prevents the UI preference from becoming a second
    /// persistence system beside `AppPreferences`.
    static let appearanceUserDefaultsKey = "appearance.mode"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedProvider: InsightProviderChoice {
        get {
            guard let id = defaults.string(forKey: Key.provider),
                  let provider = InsightProviderChoice(stableID: id) else { return .local }
            return provider
        }
        nonmutating set { defaults.set(newValue.stableID, forKey: Key.provider) }
    }

    /// New installs retain recordings so audio export is dependable. An
    /// explicit stored false remains false across launches.
    var retainAudio: Bool {
        get { defaults.object(forKey: Key.retainAudio) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.retainAudio) }
    }

    var localModelPath: String {
        get { defaults.string(forKey: Key.localModelPath) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Key.localModelPath) }
    }

    var llamaExecutablePath: String? {
        get { defaults.string(forKey: Key.llamaExecutablePath) }
        nonmutating set { defaults.set(newValue, forKey: Key.llamaExecutablePath) }
    }

    /// Parent chosen by the user. Hushnote owns a single `Hushnote Models`
    /// child beneath it; nil keeps the dependencies' existing default caches.
    var modelStorageParentPath: String? {
        get {
            guard let path = defaults.string(forKey: Key.modelStorageParentPath), !path.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        nonmutating set {
            let standardized = newValue.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            defaults.set(standardized, forKey: Key.modelStorageParentPath)
        }
    }

    var modelStoragePaths: ModelStoragePaths {
        ModelStoragePaths(parentDirectory: modelStorageParentPath.map(URL.init(fileURLWithPath:)))
    }

    /// Missing and malformed values are deliberately treated as System so an
    /// existing install follows macOS without a migration prompt.
    var appearance: AppearanceMode {
        get {
            guard let raw = defaults.string(forKey: Key.appearance),
                  let mode = AppearanceMode(rawValue: raw) else { return .system }
            return mode
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.appearance) }
    }

    var sidebarDestination: SidebarDestination? {
        get {
            guard let raw = defaults.string(forKey: Key.sidebarDestination) else { return nil }
            switch raw {
            case "meetings": return .meetings
            case "unfiled": return .unfiled
            case "shared": return .shared
            case "recentlyDeleted": return .recentlyDeleted
            case "models": return .models
            case "settings": return .settings
            case "storage": return .storage
            default:
                if raw.hasPrefix("meeting:"),
                   let id = UUID(uuidString: String(raw.dropFirst("meeting:".count))) {
                    return .meeting(id)
                }
                guard raw.hasPrefix("folder:"),
                      let id = UUID(uuidString: String(raw.dropFirst("folder:".count))) else { return nil }
                return .folder(id)
            }
        }
        nonmutating set {
            let raw: String? = switch newValue {
            case .meetings: "meetings"
            case .unfiled: "unfiled"
            case .shared: "shared"
            case .recentlyDeleted: "recentlyDeleted"
            case .models: "models"
            case .settings: "settings"
            case .storage: "storage"
            case .meeting(let id): "meeting:\(id.uuidString)"
            case .folder(let id): "folder:\(id.uuidString)"
            case nil: nil
            }
            defaults.set(raw, forKey: Key.sidebarDestination)
        }
    }

    var meetingTabs: [UUID: WorkspaceTab] {
        get {
            guard let data = defaults.data(forKey: Key.meetingTabs),
                  let raw = try? JSONDecoder().decode([String: WorkspaceTab].self, from: data) else { return [:] }
            return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        }
        nonmutating set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.uuidString, $0.value) })
            defaults.set(try? JSONEncoder().encode(raw), forKey: Key.meetingTabs)
        }
    }

    func pruneMeetingTabs(keeping meetingIDs: Set<UUID>) -> [UUID: WorkspaceTab] {
        let pruned = meetingTabs.filter { meetingIDs.contains($0.key) }
        meetingTabs = pruned
        return pruned
    }
}
