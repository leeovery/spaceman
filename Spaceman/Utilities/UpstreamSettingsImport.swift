//
//  UpstreamSettingsImport.swift
//  Spaceman
//
//  Copies the settings, space names and shortcuts saved under the upstream bundle ID
//  into this app's defaults, once.
//

import Foundation

enum UpstreamSettingsImport {
    static let upstreamDomain = "dev.ruittenb.Spaceman"
    static let importedKey = "importedUpstreamSettings"

    /// Copies every key of `domain` into `defaults`, unless an earlier run already has.
    /// The `SU*` keys stay behind: they belong to the self-updater this app no longer has.
    static func run(from domain: String = upstreamDomain, into defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: importedKey) else { return }
        for (key, value) in storedValues(in: domain) where !key.hasPrefix("SU") {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: importedKey)
    }

    /// The domain's own keys: `UserDefaults(suiteName:)` would mix in the global domain's.
    private static func storedValues(in domain: String) -> [String: Any] {
        let values = CFPreferencesCopyMultiple(
            nil, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return values as? [String: Any] ?? [:]
    }
}
