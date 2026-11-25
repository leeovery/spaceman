//
//  WindowServerEvents.swift
//  Spaceman
//
//  Listens for the window server's private notifications, which it posts to every app with a
//  connection to it, with no polling. Registered through SkyLight's SLSRegisterNotifyProc, looked up
//  at run time; SIP can stay on. They reach the app through its event loop.
//
//  Measured on macOS 26.7: "Mission Control began" arrives 12-19ms after the key that opens
//  Mission Control, and as a swipe that opens it starts, 90-300ms before the Dock answers any
//  Accessibility request. "Mission Control ended" arrives once it has finished closing. Each
//  arrives twice, a few milliseconds apart. Both also come for App Exposé.
//

import Foundation
import os

enum WindowServerEvents {

    static let missionControlBegan: Int32 = 1327
    static let missionControlEnded: Int32 = 1328

    /// Called on the main thread with the event's type, the system uptime it arrived at and its
    /// payload's bytes.
    typealias Handler = (_ type: Int32, _ time: TimeInterval, _ payload: [UInt8]) -> Void

    private typealias NotifyProc = @convention(c) (Int32, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?)
        -> Void
    private typealias RegisterNotifyProc = @convention(c) (NotifyProc, Int32, UnsafeMutableRawPointer?) -> Int32

    private static let log = Logger(subsystem: Constants.AppInfo.bundleId, category: "windowServerEvents")
    private static var handlers: [Int32: Handler] = [:]

    /// Calls `handler` for each `type` posted, from now on. Returns whether the window server took
    /// every registration. Main thread only; a type is registered once, later calls replace its handler.
    @discardableResult
    static func observe(_ types: [Int32], handler: @escaping Handler) -> Bool {
        guard let register = registerFunction() else {
            log.log("No SLSRegisterNotifyProc: Mission Control's start can't be seen")
            return false
        }
        var registered = true
        for type in types {
            let isNew = handlers[type] == nil
            handlers[type] = handler
            guard isNew else { continue }
            if register(notify, type, nil) != 0 {
                log.log("Window server refused event \(type)")
                registered = false
            }
        }
        return registered
    }

    private static let notify: NotifyProc = { type, data, length, _ in
        let time = ProcessInfo.processInfo.systemUptime
        let payload = data.map { Array(UnsafeRawBufferPointer(start: $0, count: Int(min(length, 64)))) } ?? []
        if Thread.isMainThread {
            handlers[type]?(type, time, payload)
        } else {
            DispatchQueue.main.async { handlers[type]?(type, time, payload) }
        }
    }

    private static func registerFunction() -> RegisterNotifyProc? {
        // AppKit loads SkyLight; open it by path in case that changes.
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        for name in ["SLSRegisterNotifyProc", "CGSRegisterNotifyProc"] {
            if let symbol = dlsym(defaultHandle, name) {
                return unsafeBitCast(symbol, to: RegisterNotifyProc.self)
            }
        }
        return nil
    }
}
