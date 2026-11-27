//
//  MissionControlCaches.swift
//  Spaceman
//
//  What the Mission Control labels keep in Spaceman's caches folder, so the first session after a launch is
//  labelled from its first frame: the captions' looks and which bars magnify.
//

import AppKit
import ImageIO
import os

/// Files in folders of Spaceman's caches folder, one property list each, read and written in order off the main
/// thread.
enum CacheFiles {

    private static let log = Logger(subsystem: Constants.AppInfo.bundleId, category: "missionControlLook")
    private static let queue = DispatchQueue(label: "\(Constants.AppInfo.bundleId).caches", qos: .utility)

    private static func folder(_ name: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Constants.AppInfo.bundleId, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Writes what `encode` gives, worked out off the main thread, as `file` in the folder `name`.
    static func write(_ file: String, in name: String, _ encode: @escaping () -> Data?) {
        queue.async {
            guard let folder = folder(name), let data = encode() else { return }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent("\(file).plist"), options: .atomic)
            } catch {
                log.log("Couldn't keep \(file, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Reads every file in the folder `name` that `decode` makes sense of, by file name, and hands them to `done`
    /// on the main thread.
    static func readAll<Value>(
        in name: String, decode: @escaping (Data) -> Value?, done: @escaping ([String: Value]) -> Void
    ) {
        queue.async {
            var read: [String: Value] = [:]
            let files = folder(name).flatMap {
                try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
            }
            for file in files ?? [] where file.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: file), let value = decode(data) else { continue }
                read[file.deletingPathExtension().lastPathComponent] = value
            }
            DispatchQueue.main.async { done(read) }
        }
    }

    static func png(of image: CGImage) -> Data? {
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? png as Data : nil
    }

    static func image(png: Data) -> CGImage? {
        CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
}

// MARK: - Looks

/// The captions' looks kept on disk, a file a screen, by display and size, with what the screen showed behind them.
enum CaptionLookStore {

    private static let folder = "CaptionLooks"
    private static let version = 2

    /// A look as written: its images as PNG, its colours as sRGB components.
    private struct Stored: Codable {
        struct Variant: Codable {
            let frame: CGRect
            let top: CGFloat
            let baseline: CGFloat
            let png: Data
        }

        struct Look: Codable {
            let exact: String
            let name: String
            let plain: Variant?
            let current: Variant?
            let wasCurrent: Bool
            let summary: String
            let textColor: [CGFloat]?
            let pillColor: [CGFloat]?
            let barColor: [CGFloat]?
        }

        let version: Int
        let background: String
        let looks: [Look]
    }

    /// The file a screen's looks are kept in: its display's UUID and its size in points.
    static func file(display: String, screen: CGSize) -> String {
        "\(display)-\(Int(screen.width.rounded()))x\(Int(screen.height.rounded()))"
    }

    /// Writes `looks` in place of those kept in `file`.
    static func save(_ looks: CaptionLooks.ScreenLooks, file: String) {
        CacheFiles.write(file, in: folder) { encode(looks) }
    }

    /// Reads every screen's looks kept, by file, and hands them to `done` on the main thread.
    static func load(_ done: @escaping ([String: CaptionLooks.ScreenLooks]) -> Void) {
        CacheFiles.readAll(in: folder, decode: decode, done: done)
    }

    static func encode(_ looks: CaptionLooks.ScreenLooks) -> Data? {
        func variant(_ variant: NativeCaptionLook.Variant?) -> Stored.Variant? {
            variant.flatMap { variant in
                CacheFiles.png(of: variant.image).map {
                    Stored.Variant(frame: variant.frame, top: variant.top, baseline: variant.baseline, png: $0)
                }
            }
        }
        let stored = Stored(version: version, background: looks.background, looks: looks.entries.map { entry in
            let look = entry.look
            return Stored.Look(
                exact: entry.exact, name: entry.name, plain: variant(look.plain), current: variant(look.current),
                wasCurrent: look.wasCurrent, summary: look.summary, textColor: look.textColor.flatMap(components),
                pillColor: look.pillColor.flatMap(components), barColor: look.barColor.flatMap(components))
        })
        return try? PropertyListEncoder().encode(stored)
    }

    static func decode(_ data: Data) -> CaptionLooks.ScreenLooks? {
        guard let stored = try? PropertyListDecoder().decode(Stored.self, from: data), stored.version == version
        else { return nil }
        func variant(_ variant: Stored.Variant?) -> NativeCaptionLook.Variant? {
            variant.flatMap { variant in
                CacheFiles.image(png: variant.png).map {
                    NativeCaptionLook.Variant(frame: variant.frame, top: variant.top, image: $0,
                                              baseline: variant.baseline)
                }
            }
        }
        return CaptionLooks.ScreenLooks(background: stored.background, entries: stored.looks.compactMap { kept in
            let plain = variant(kept.plain), current = variant(kept.current)
            guard plain != nil || current != nil else { return nil }
            var look = NativeCaptionLook(plain: plain, current: current, wasCurrent: kept.wasCurrent,
                                         summary: kept.summary)
            look.textColor = kept.textColor.flatMap(color)
            look.pillColor = kept.pillColor.flatMap(color)
            look.barColor = kept.barColor.flatMap(color)
            return CaptionLooks.ScreenLooks.Entry(exact: kept.exact, name: kept.name, look: look)
        })
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    private static func components(_ color: CGColor) -> [CGFloat]? {
        sRGB.flatMap { color.converted(to: $0, intent: .defaultIntent, options: nil)?.components }
    }

    private static func color(_ components: [CGFloat]) -> CGColor? {
        guard let sRGB, components.count == sRGB.numberOfComponents + 1 else { return nil }
        return CGColor(colorSpace: sRGB, components: components)
    }
}

// MARK: - Magnification

/// Which bars magnify, as learned, kept on disk in one file.
enum BarMagnificationStore {

    private static let folder = "Bars"
    private static let file = "magnification"
    private static let version = 1

    private struct Stored: Codable {
        let version: Int
        /// Whether each bar magnifies, by `BarMagnification`'s keys.
        let magnifies: [String: Bool]
    }

    static func save(_ learned: [String: BarMagnification.Learned]) {
        CacheFiles.write(file, in: folder) { encode(learned) }
    }

    /// Reads what was learned and hands it to `done` on the main thread: nothing when none was kept.
    static func load(_ done: @escaping ([String: BarMagnification.Learned]) -> Void) {
        CacheFiles.readAll(in: folder, decode: decode) { read in done(read[file] ?? [:]) }
    }

    static func encode(_ learned: [String: BarMagnification.Learned]) -> Data? {
        try? PropertyListEncoder().encode(Stored(version: version, magnifies: learned.mapValues { $0 == .magnifies }))
    }

    static func decode(_ data: Data) -> [String: BarMagnification.Learned]? {
        guard let stored = try? PropertyListDecoder().decode(Stored.self, from: data), stored.version == version
        else { return nil }
        return stored.magnifies.mapValues { $0 ? .magnifies : .doesNotMagnify }
    }
}
