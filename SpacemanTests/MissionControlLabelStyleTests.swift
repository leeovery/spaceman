//
//  MissionControlLabelStyleTests.swift
//  SpacemanTests
//
//  Tests which style the Mission Control labels are drawn in, when Screen Recording is asked for,
//  and the one-time start of the style from the hidden default it replaced.
//

import XCTest
@testable import Spaceman

final class MissionControlLabelStyleTests: XCTestCase {

    /// A fixed name: the preferences daemon leaves an empty plist behind for every domain a test writes.
    private let suite = "MissionControlLabelStyleTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Effective style

    private func effective(
        _ chosen: MissionControlLabelStyle, available: Bool = true, granted: Bool
    ) -> MissionControlLabelStyle {
        MissionControlLabelStyle.effective(
            chosen: chosen, nativeLookAvailable: available, screenRecordingGranted: granted)
    }

    func testNativeLookWithScreenRecordingIsDrawnNative() {
        XCTAssertEqual(effective(.nativeLook, granted: true), .nativeLook)
    }

    func testNativeLookWithoutScreenRecordingIsDrawnInSpaceColors() {
        XCTAssertEqual(effective(.nativeLook, granted: false), .spaceColors)
    }

    func testNativeLookWhereUnavailableIsDrawnInSpaceColorsWhateverTheGrant() {
        for granted in [true, false] {
            XCTAssertEqual(effective(.nativeLook, available: false, granted: granted), .spaceColors)
        }
    }

    func testSpaceColorsAreDrawnInSpaceColorsWhateverTheGrant() {
        for granted in [true, false] {
            XCTAssertEqual(effective(.spaceColors, granted: granted), .spaceColors)
        }
    }

    func testCurrentStyleReadsTheStoredStyle() {
        defaults.set(MissionControlLabelStyle.spaceColors.rawValue, forKey: MissionControlLabelStyle.defaultsKey)
        XCTAssertEqual(
            MissionControlLabelStyle.current(in: defaults, nativeLookAvailable: true, screenRecordingGranted: true),
            .spaceColors)
        defaults.set(MissionControlLabelStyle.nativeLook.rawValue, forKey: MissionControlLabelStyle.defaultsKey)
        XCTAssertEqual(
            MissionControlLabelStyle.current(in: defaults, nativeLookAvailable: true, screenRecordingGranted: true),
            .nativeLook)
    }

    // MARK: - Asking for Screen Recording

    private func needsScreenRecording(
        namesShown: Bool = true, chosen: MissionControlLabelStyle, available: Bool = true, granted: Bool
    ) -> Bool {
        MissionControlLabelStyle.needsScreenRecording(
            namesShown: namesShown, chosen: chosen, nativeLookAvailable: available, screenRecordingGranted: granted)
    }

    func testScreenRecordingIsNeverAskedForWhereTheNativeLookIsUnavailable() {
        for chosen in MissionControlLabelStyle.allCases {
            for granted in [true, false] {
                XCTAssertFalse(needsScreenRecording(chosen: chosen, available: false, granted: granted))
            }
        }
    }

    private func needsScreenRecordingNow() -> Bool {
        MissionControlLabelStyle.needsScreenRecordingNow(
            in: defaults, nativeLookAvailable: true, screenRecordingGranted: false)
    }

    func testScreenRecordingNowReadsTheNamesShownAndStyleSettings() {
        XCTAssertFalse(needsScreenRecordingNow(), "names are off until turned on")
        defaults.set(true, forKey: MissionControlLabelStyle.namesShownKey)
        XCTAssertTrue(needsScreenRecordingNow(), "the style defaults to the native look")
        defaults.set(MissionControlLabelStyle.spaceColors.rawValue, forKey: MissionControlLabelStyle.defaultsKey)
        XCTAssertFalse(needsScreenRecordingNow())
    }

    func testScreenRecordingIsAskedForOnlyForTheNativeLookWithoutIt() {
        XCTAssertTrue(needsScreenRecording(chosen: .nativeLook, granted: false))
        XCTAssertFalse(needsScreenRecording(chosen: .nativeLook, granted: true))
        XCTAssertFalse(needsScreenRecording(chosen: .spaceColors, granted: false))
        XCTAssertFalse(needsScreenRecording(chosen: .spaceColors, granted: true))
    }

    func testScreenRecordingIsNeverAskedForWithNamesOff() {
        for chosen in MissionControlLabelStyle.allCases {
            for granted in [true, false] {
                XCTAssertFalse(needsScreenRecording(namesShown: false, chosen: chosen, granted: granted))
            }
        }
    }

    // MARK: - Chosen style

    func testChosenStyleDefaultsToNativeLook() {
        XCTAssertEqual(MissionControlLabelStyle.chosen(in: defaults), .nativeLook)
    }

    func testChosenStyleReadsTheStoredStyle() {
        defaults.set(MissionControlLabelStyle.spaceColors.rawValue, forKey: MissionControlLabelStyle.defaultsKey)
        XCTAssertEqual(MissionControlLabelStyle.chosen(in: defaults), .spaceColors)
    }

    func testUnknownStoredStyleReadsAsNativeLook() {
        defaults.set("plaid", forKey: MissionControlLabelStyle.defaultsKey)
        XCTAssertEqual(MissionControlLabelStyle.chosen(in: defaults), .nativeLook)
    }

    // MARK: - Migration

    func testNativeLookTurnedOffStartsAsSpaceColors() {
        defaults.set(false, forKey: MissionControlLabelStyle.legacyNativeLookKey)
        MissionControlLabelStyle.migrate(defaults)
        XCTAssertEqual(MissionControlLabelStyle.chosen(in: defaults), .spaceColors)
    }

    func testNativeLookTurnedOnStartsAsNativeLook() {
        defaults.set(true, forKey: MissionControlLabelStyle.legacyNativeLookKey)
        MissionControlLabelStyle.migrate(defaults)
        XCTAssertEqual(defaults.string(forKey: MissionControlLabelStyle.defaultsKey), "nativeLook")
    }

    func testNativeLookNeverSetStartsAsNativeLook() {
        MissionControlLabelStyle.migrate(defaults)
        XCTAssertEqual(defaults.string(forKey: MissionControlLabelStyle.defaultsKey), "nativeLook")
    }

    func testMigrationDropsTheOldKeys() {
        defaults.set(false, forKey: MissionControlLabelStyle.legacyNativeLookKey)
        defaults.set(true, forKey: MissionControlLabelStyle.legacyColoredKey)
        MissionControlLabelStyle.migrate(defaults)
        XCTAssertNil(defaults.object(forKey: MissionControlLabelStyle.legacyNativeLookKey))
        XCTAssertNil(defaults.object(forKey: MissionControlLabelStyle.legacyColoredKey))
    }

    func testMigrationRunsOnce() {
        defaults.set(MissionControlLabelStyle.nativeLook.rawValue, forKey: MissionControlLabelStyle.defaultsKey)
        defaults.set(false, forKey: MissionControlLabelStyle.legacyNativeLookKey)
        MissionControlLabelStyle.migrate(defaults)
        XCTAssertEqual(MissionControlLabelStyle.chosen(in: defaults), .nativeLook)
    }
}
