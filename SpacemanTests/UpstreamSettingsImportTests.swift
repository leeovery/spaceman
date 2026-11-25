//
//  UpstreamSettingsImportTests.swift
//  SpacemanTests
//
//  Tests the one-time copy of the upstream bundle ID's settings into this app's defaults.
//

import XCTest
@testable import Spaceman

final class UpstreamSettingsImportTests: XCTestCase {

    /// Fixed names: the preferences daemon leaves an empty plist behind for every domain a test
    /// writes, so reusing two names keeps that to two files.
    private let sourceDomain = "UpstreamSettingsImportTests.source"
    private let destinationSuite = "UpstreamSettingsImportTests.destination"
    private var source: UserDefaults!
    private var destination: UserDefaults!

    override func setUp() {
        super.setUp()
        source = UserDefaults(suiteName: sourceDomain)!
        destination = UserDefaults(suiteName: destinationSuite)!
        source.removePersistentDomain(forName: sourceDomain)
        destination.removePersistentDomain(forName: destinationSuite)
    }

    override func tearDown() {
        source.removePersistentDomain(forName: sourceDomain)
        destination.removePersistentDomain(forName: destinationSuite)
        source = nil
        destination = nil
        super.tearDown()
    }

    private func runImport() {
        UpstreamSettingsImport.run(from: sourceDomain, into: destination)
    }

    private var destinationValues: [String: Any] {
        destination.persistentDomain(forName: destinationSuite) ?? [:]
    }

    func testCopiesEveryKeyWithItsType() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data([0x01, 0x02, 0x03])
        source.set("HOME", forKey: "string")
        source.set(3, forKey: "int")
        source.set(1.5, forKey: "double")
        source.set(true, forKey: "bool")
        source.set(data, forKey: "data")
        source.set(date, forKey: "date")
        source.set(["a", "b"], forKey: "array")
        source.set(["x": 1], forKey: "dictionary")

        runImport()

        XCTAssertEqual(destination.object(forKey: "string") as? String, "HOME")
        XCTAssertEqual(destination.object(forKey: "int") as? Int, 3)
        XCTAssertEqual(destination.object(forKey: "double") as? Double, 1.5)
        let boolType = destination.object(forKey: "bool").map { CFGetTypeID($0 as CFTypeRef) }
        XCTAssertEqual(boolType, CFBooleanGetTypeID())
        XCTAssertEqual(destination.object(forKey: "data") as? Data, data)
        XCTAssertEqual(destination.object(forKey: "date") as? Date, date)
        XCTAssertEqual(destination.object(forKey: "array") as? [String], ["a", "b"])
        XCTAssertEqual(destination.object(forKey: "dictionary") as? [String: Int], ["x": 1])
    }

    func testCopiesOnlyTheSourceDomainsOwnKeys() {
        source.set("HOME", forKey: "string")

        runImport()

        XCTAssertEqual(Set(destinationValues.keys), ["string", UpstreamSettingsImport.importedKey])
    }

    func testSkipsSelfUpdaterKeys() {
        source.set("https://example.com/appcast.xml", forKey: "SUFeedURL")
        source.set(true, forKey: "SUEnableAutomaticChecks")
        source.set(Date(), forKey: "SULastCheckTime")
        source.set(true, forKey: "showHUD")

        runImport()

        XCTAssertNil(destination.object(forKey: "SUFeedURL"))
        XCTAssertNil(destination.object(forKey: "SUEnableAutomaticChecks"))
        XCTAssertNil(destination.object(forKey: "SULastCheckTime"))
        XCTAssertEqual(destination.object(forKey: "showHUD") as? Bool, true)
    }

    func testReplacesAValueAlreadyInTheDestination() {
        source.set(4, forKey: "iconSize")
        destination.set(2, forKey: "iconSize")

        runImport()

        XCTAssertEqual(destination.object(forKey: "iconSize") as? Int, 4)
    }

    func testSetsTheImportedFlag() {
        runImport()

        XCTAssertTrue(destination.bool(forKey: UpstreamSettingsImport.importedKey))
    }

    func testSecondRunChangesNothing() {
        source.set("HOME", forKey: "string")
        runImport()
        let afterFirstRun = destinationValues as NSDictionary

        source.set("WORK", forKey: "string")
        source.set(3, forKey: "added")
        runImport()

        XCTAssertEqual(destinationValues as NSDictionary, afterFirstRun)
    }
}
