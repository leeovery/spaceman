//
//  PreferencesViewModel.swift
//  Spaceman
//
//  Created by Sasindu Jayasinghe on 6/12/20.
//

import Foundation
import SwiftUI

class PreferencesViewModel: ObservableObject {
    let nameStore: SpaceNameStore
    @Published var spaceNamesDict: [String: SpaceNameInfo] = [:]
    @Published var sortedSpaceNamesDict: [Dictionary<String, SpaceNameInfo>.Element] = []

    init(nameStore: SpaceNameStore = .shared) {
        self.nameStore = nameStore
    }

    func loadData() {
        let allSpaceNames = nameStore.loadAll()
        let filtered = allSpaceNames.filter { AppDelegate.activeSpaceIDs.contains($0.key) }
        spaceNamesDict = filtered
        rebuildSortedSpaceNames()
    }

    func updateSpace(for key: String, to newName: String) {
        updateSpaceName(for: key, to: newName)
    }

    private func updateSpaceName(for key: String, to newName: String) {
        guard let info = spaceNamesDict[key] else { return }
        let updated = info.withName(newName)
        spaceNamesDict[key] = updated
        // Persist immediately so SpaceObserver sees the new name before its next
        // update cycle.
        nameStore.update { stored in
            stored[key] = updated
        }
    }

    func updateSpaceColor(for key: String, to color: NSColor?) {
        guard let info = spaceNamesDict[key] else { return }
        spaceNamesDict[key] = info.withColor(color?.toHexString())

        // Save immediately but don't rebuild sorted array (avoids ForEach recreation).
        // Use update() to merge into existing store, preserving disconnected display entries.
        nameStore.update { stored in
            for (key, info) in spaceNamesDict {
                stored[key] = info
            }
        }
    }

    func removeAllColors() {
        for key in spaceNamesDict.keys {
            spaceNamesDict[key]?.colorHex = nil
        }
        nameStore.update { stored in
            for key in stored.keys {
                stored[key]?.colorHex = nil
            }
        }
    }

    func persistChanges(for key: String?) {
        // Merge into existing store, preserving disconnected display entries.
        nameStore.update { stored in
            for (key, info) in spaceNamesDict {
                stored[key] = info
            }
        }
        rebuildSortedSpaceNames()
    }

    private func rebuildSortedSpaceNames() {
        // Sort by display index, then by position on display (respects display ordering)
        sortedSpaceNamesDict = spaceNamesDict.sorted { (first, second) in
            let displayA = first.value.currentDisplayIndex ?? 0
            let displayB = second.value.currentDisplayIndex ?? 0

            if displayA != displayB {
                return displayA < displayB
            }

            let positionA = first.value.positionOnDisplay ?? 0
            let positionB = second.value.positionOnDisplay ?? 0
            return positionA < positionB
        }

        if sortedSpaceNamesDict.isEmpty {
            sortedSpaceNamesDict.append((
                key: "0",
                value: SpaceNameInfo(spaceNum: 0, spaceName: "DISP", spaceLabel: "1")))
        }
    }
}
