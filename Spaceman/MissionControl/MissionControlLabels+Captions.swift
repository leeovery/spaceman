//
//  MissionControlLabels+Captions.swift
//  Spaceman
//
//  Matches the Spaces Bar's thumbnails to spaces and their stored names, in the order
//  Mission Control shows them.
//

import AppKit
import ApplicationServices

extension MissionControlLabels {

    /// Offset from AX position (thumbnail center) to caption center.
    /// On macOS 27+, AX reports position as thumbnail center, not top-left.
    /// Caption sits 53pt below center (measured by ActiveSpace on macOS 27.0).
    private static var captionOffset: CGFloat {
        let offset = UserDefaults.standard.object(forKey: "missionControlCaptionOffset") as? Double
        return offset.map { CGFloat($0) } ?? 53
    }

    func windowManagerCaptions(
        in bar: AXUIElement,
        mirrorToOtherScreens mirror: Bool,
        screens: [ScreenInfo]
    ) -> [Caption] {
        let found = AX.buttons(in: bar)
        let centres = found.map {
            // macOS 27: AX position is thumbnail CENTER, not top-left
            // frame.minX/minY = center point
            // Caption sits below the visible thumbnail
            CGPoint(x: $0.frame.minX, y: $0.frame.minY + Self.captionOffset)
        }
        guard let first = centres.first, let last = centres.last else { return [] }
        let source = screens.first { $0.frame.contains(first) }
        let fallbackWidth = found.first?.frame.width ?? 0
        let result = Self.match(found, centres: centres, fallbackWidth: fallbackWidth,
                                spaceIDs: Self.orderedSpaceIDs(displayUUID: source?.uuid))
        logMismatch(result.mismatch)
        var captions = result.captions

        guard mirror, let source else { return captions }
        let layoutMid = (first.x + last.x) / 2
        for target in screens where target.frame != source.frame {
            let offsetX = target.frame.midX - layoutMid
            let offsetY = target.frame.minY - source.frame.minY
            let moved = centres.map { CGPoint(x: $0.x + offsetX, y: $0.y + offsetY) }
            let mirrored = Self.match(found, centres: moved, fallbackWidth: fallbackWidth,
                                      spaceIDs: Self.orderedSpaceIDs(displayUUID: target.uuid))
            logMismatch(mirrored.mismatch)
            captions += mirrored.captions
        }
        return captions
    }

    /// Each display's current space, as ManagedSpaceIDs.
    static func currentSpaceIDs() -> Set<String> {
        let conn = _CGSDefaultConnection()
        guard let spacesRef = CGSCopyManagedDisplaySpaces(conn),
              let displays = spacesRef.takeRetainedValue() as? [[String: Any]] else { return [] }
        return Set(displays.compactMap { display in
            (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
        }.map(String.init))
    }

    static func displaysShareSpaces() -> Bool {
        let conn = _CGSDefaultConnection()
        guard let spacesRef = CGSCopyManagedDisplaySpaces(conn) else { return false }
        let spaces = spacesRef.takeRetainedValue() as? [[String: Any]]
        return spaces?.count == 1
    }

    /// The captions of one Dock Spaces Bar on `screen`; a caption can sit above its screen while
    /// the bar slides in or out. Safe off the main thread.
    static func dockCaptions(_ found: [AX.Button], screen: ScreenInfo)
        -> (captions: [Caption], mismatch: String?) {
        let centres = found.map {
            // Dock: AX frame is top-left origin
            // Caption "Desktop N" sits below the frame
            // Spaces bar (small ~24pt high): caption ~15pt below frame
            // Thumbnails (~77pt high): caption ~8pt below frame
            let gapToCaption: CGFloat = $0.frame.height < 40 ? 18 : 8
            let captionY = $0.frame.maxY + gapToCaption + MissionControlLabelOverlay.labelHeight / 2
            return CGPoint(x: $0.frame.midX, y: captionY)
        }
        return match(found, centres: centres, fallbackWidth: found.first?.frame.width ?? 0,
                     spaceIDs: orderedSpaceIDs(displayUUID: screen.uuid))
    }

    /// Matches thumbnails to spaces and looks up names from SpaceNameStore. Safe off the main thread.
    fileprivate static func match(
        _ found: [AX.Button],
        centres: [CGPoint],
        fallbackWidth: CGFloat,
        spaceIDs: [String]
    ) -> (captions: [Caption], mismatch: String?) {
        guard !centres.isEmpty else { return ([], nil) }
        guard spaceIDs.count == found.count else {
            return ([], "\(found.count) thumbnails but \(spaceIDs.count) spaces")
        }

        let storedNames = SpaceNameStore.shared.loadAll()
        let captions = centres.indices.compactMap { index -> Caption? in
            let spaceID = spaceIDs[index]
            // A space never named shows the Dock's own caption.
            guard let nameInfo = storedNames[spaceID], !nameInfo.spaceName.isEmpty,
                  nameInfo.spaceName != SpaceObserver.unnamedSpaceName
            else { return nil }
            let neighbours = [index - 1, index + 1]
                .filter(centres.indices.contains)
                .map { abs(centres[$0].x - centres[index].x) }
            let width = (neighbours.min() ?? fallbackWidth) - labelGap
            return Caption(
                centre: centres[index],
                maxWidth: width,
                covers: found[index].title,
                name: nameInfo.spaceName,
                colorHex: nameInfo.colorHex,
                spaceID: spaceID)
        }
        return (captions, nil)
    }

    // MARK: - Spaces, in the order Mission Control shows them

    /// Returns ManagedSpaceIDs (as strings) for the display with `displayUUID`, in visual order.
    /// With one display, or with displays sharing their spaces, that display's spaces.
    fileprivate static func orderedSpaceIDs(displayUUID: String?) -> [String] {
        let conn = _CGSDefaultConnection()
        guard let spacesRef = CGSCopyManagedDisplaySpaces(conn) else { return [] }
        guard let displays = spacesRef.takeRetainedValue() as? [[String: Any]] else { return [] }

        let display = displays.count == 1
            ? displays.first
            : displays.first { ($0["Display Identifier"] as? String) == displayUUID }
        guard let display, let spaces = display["Spaces"] as? [[String: Any]] else { return [] }

        // Get UUIDs for visual order lookup
        let uuids = spaces.compactMap { $0["uuid"] as? String }
        let orderedUUIDs = visualOrder(of: uuids)

        // Build UUID -> ManagedSpaceID map
        var uuidToID: [String: String] = [:]
        for space in spaces {
            if let uuid = space["uuid"] as? String,
               let managedSpaceID = space["ManagedSpaceID"] as? Int {
                uuidToID[uuid] = String(managedSpaceID)
            }
        }

        // Return ManagedSpaceIDs in visual order
        return orderedUUIDs.compactMap { uuidToID[$0] }
    }

    static func displayUUID(of screen: NSScreen) -> String? {
        guard let screenNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(
            CGDirectDisplayID(screenNumber.uint32Value))?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// The Dock's order of the spaces, left to right in Mission Control.
    private static func visualOrder(of uuids: [String]) -> [String] {
        // Through the preferences system, which has the Dock's order the moment it changes: the file on
        // disk catches up 7-9 seconds after a thumbnail is dragged to another place.
        let domain = "com.apple.spaces" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let config = CFPreferencesCopyAppValue("SpacesDisplayConfiguration" as CFString, domain)
                as? [String: Any],
              let management = config["Management Data"] as? [String: Any],
              let monitors = management["Monitors"] as? [[String: Any]] else { return uuids }

        let wanted = Set(uuids)
        var best: [String] = []
        for monitor in monitors {
            let spaces = monitor["Spaces"] as? [[String: Any]] ?? []
            let order = spaces.compactMap { $0["uuid"] as? String }
            if Set(order).intersection(wanted).count > Set(best).intersection(wanted).count {
                best = order
            }
        }
        return Set(best) == wanted && best.count == uuids.count ? best : uuids
    }
}
