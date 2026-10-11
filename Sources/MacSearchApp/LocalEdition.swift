import Foundation
import Carbon

// Bundle-scoped policy keeps the personal build separate from upstream releases.
enum LocalEdition {
    static let enabled = true
    static func configure() {
        guard enabled else { return }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "appLanguage") == nil { defaults.set("zh", forKey: "appLanguage") }
        if defaults.object(forKey: "hotKeyModifiers") == nil {
            defaults.set(Int(cmdKey | optionKey | shiftKey), forKey: "hotKeyModifiers")
        }
    }
}
