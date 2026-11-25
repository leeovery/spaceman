//
//  MissionControlLabelStyle.swift
//  Spaceman
//
//  How the Mission Control name labels are drawn: matching the native captions, from captures of the
//  screen, or as boxes in the spaces' colours.
//

import CoreGraphics
import Foundation

enum MissionControlLabelStyle: String, CaseIterable {
    case nativeLook
    case spaceColors

    static let defaultsKey = "missionControlLabelStyle"
    /// The hidden on/off default the style replaced, read once by `migrate(_:)`.
    static let legacyNativeLookKey = "missionControlLabelsNativeLook"
    /// The "Use color" toggle the style replaced, dropped by `migrate(_:)`.
    static let legacyColoredKey = "areMissionControlLabelsColored"
    /// Whether the labels are shown at all.
    static let namesShownKey = "showMissionControlLabels"

    /// The style picked in Preferences.
    static func chosen(in defaults: UserDefaults = .standard) -> MissionControlLabelStyle {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .nativeLook
    }

    /// The style labels are drawn in: the native look needs Screen Recording, which macOS only
    /// reports granted to a relaunched app, so until then they are drawn in the spaces' colours.
    static func effective(
        chosen: MissionControlLabelStyle, screenRecordingGranted: Bool
    ) -> MissionControlLabelStyle {
        chosen == .nativeLook && screenRecordingGranted ? .nativeLook : .spaceColors
    }

    /// The style labels are drawn in now.
    static var current: MissionControlLabelStyle {
        effective(chosen: chosen(), screenRecordingGranted: CGPreflightScreenCaptureAccess())
    }

    /// Whether to ask for Screen Recording: only while the labels are shown in the native look, and
    /// only while it is missing.
    static func needsScreenRecording(
        namesShown: Bool, chosen: MissionControlLabelStyle, screenRecordingGranted: Bool
    ) -> Bool {
        namesShown && chosen == .nativeLook && !screenRecordingGranted
    }

    /// Whether to ask for Screen Recording now, from the stored settings.
    static var needsScreenRecordingNow: Bool {
        needsScreenRecording(
            namesShown: UserDefaults.standard.bool(forKey: namesShownKey), chosen: chosen(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess())
    }

    /// Starts the style from the hidden default it replaced, once: colours if the native look was
    /// turned off, otherwise native. The defaults it replaced are dropped.
    static func migrate(_ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: defaultsKey) == nil else { return }
        let wasOff = defaults.object(forKey: legacyNativeLookKey) as? Bool == false
        defaults.set((wasOff ? spaceColors : nativeLook).rawValue, forKey: defaultsKey)
        defaults.removeObject(forKey: legacyNativeLookKey)
        defaults.removeObject(forKey: legacyColoredKey)
    }
}
