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

    /// Whether the native look can apply on this macOS: it captures the Dock's Spaces Bar, which macOS 27
    /// moved to WindowManager.
    static var nativeLookIsAvailable: Bool { MissionControlLabels.spacesBarIsInDock }

    /// The style labels are drawn in: the native look only where it is available and Screen Recording is
    /// granted, which macOS only reports to a relaunched app. Otherwise the spaces' colours.
    static func effective(
        chosen: MissionControlLabelStyle, nativeLookAvailable: Bool, screenRecordingGranted: Bool
    ) -> MissionControlLabelStyle {
        chosen == .nativeLook && nativeLookAvailable && screenRecordingGranted ? .nativeLook : .spaceColors
    }

    /// The style labels are drawn in now, from the stored settings.
    static func current(
        in defaults: UserDefaults = .standard,
        nativeLookAvailable: Bool = nativeLookIsAvailable,
        screenRecordingGranted: Bool = CGPreflightScreenCaptureAccess()
    ) -> MissionControlLabelStyle {
        effective(
            chosen: chosen(in: defaults), nativeLookAvailable: nativeLookAvailable,
            screenRecordingGranted: screenRecordingGranted)
    }

    /// Whether to ask for Screen Recording: only while the labels are shown in the native look where it
    /// is available, and only while it is missing.
    static func needsScreenRecording(
        namesShown: Bool, chosen: MissionControlLabelStyle, nativeLookAvailable: Bool, screenRecordingGranted: Bool
    ) -> Bool {
        namesShown && chosen == .nativeLook && nativeLookAvailable && !screenRecordingGranted
    }

    /// Whether to ask for Screen Recording now, from the stored settings.
    static func needsScreenRecordingNow(
        in defaults: UserDefaults = .standard,
        nativeLookAvailable: Bool = nativeLookIsAvailable,
        screenRecordingGranted: Bool = CGPreflightScreenCaptureAccess()
    ) -> Bool {
        needsScreenRecording(
            namesShown: defaults.bool(forKey: namesShownKey), chosen: chosen(in: defaults),
            nativeLookAvailable: nativeLookAvailable, screenRecordingGranted: screenRecordingGranted)
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
