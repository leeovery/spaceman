//
//  FrameClock.swift
//  Spaceman
//
//  Calls back once per display frame while the labels follow Mission Control.
//

import AppKit

/// Calls back once per display refresh while running, or 60 times a second without a screen.
final class FrameClock: NSObject {

    private let onFrame: () -> Void
    private var link: CADisplayLink?
    private var timer: Timer?
    /// When the frame being drawn reaches the screen (system uptime), when the display says.
    private(set) var targetTime: TimeInterval?
    /// How long a display frame lasts.
    private(set) var frameDuration: TimeInterval = 1.0 / 60

    init(onFrame: @escaping () -> Void) {
        self.onFrame = onFrame
    }

    func start() {
        guard link == nil, timer == nil else { return }
        if let screen = NSScreen.screens.first {
            let displayLink = screen.displayLink(target: self, selector: #selector(frame(_:)))
            displayLink.add(to: .main, forMode: .common)
            link = displayLink
        } else {
            let frameTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.onFrame() }
            RunLoop.main.add(frameTimer, forMode: .common)
            timer = frameTimer
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
        targetTime = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        // The display link counts in media time; convert to system uptime, which everything else uses.
        targetTime = ProcessInfo.processInfo.systemUptime + (link.targetTimestamp - CACurrentMediaTime())
        if link.targetTimestamp > link.timestamp { frameDuration = link.targetTimestamp - link.timestamp }
        onFrame()
    }
}
