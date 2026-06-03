//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    // MARK: - Double-tap detection
    //
    // We watch for two quick press-release cycles in rapid succession
    // (each "tap" is a hold of less than `maxTapHoldSeconds`; the gap
    // between the first release and the second press must be less than
    // `maxBetweenTapsSeconds`). When the heuristic matches on the
    // second `.pressed`, we emit `.doublePressActivation` instead of
    // `.pressed` so CompanionManager can route it to the continuous-
    // session enter/exit toggle without triggering normal PTT.
    private var lastPressedAt: Date?
    private var lastReleasedAt: Date?
    private static let maxTapHoldSeconds: TimeInterval = 0.300
    private static let maxBetweenTapsSeconds: TimeInterval = 0.400

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            let now = Date()
            // Detect "tap, then this press" — the previous cycle was a
            // brief tap AND the gap since release is small. If yes,
            // promote to `.doublePressActivation` instead of firing a
            // regular `.pressed` (which would kick off normal PTT).
            let wasRecentTap: Bool
            if let lastPressed = lastPressedAt, let lastReleased = lastReleasedAt {
                let lastHold = lastReleased.timeIntervalSince(lastPressed)
                let gap = now.timeIntervalSince(lastReleased)
                wasRecentTap = lastHold >= 0
                    && lastHold < Self.maxTapHoldSeconds
                    && gap >= 0
                    && gap < Self.maxBetweenTapsSeconds
            } else {
                wasRecentTap = false
            }
            lastPressedAt = now
            isShortcutCurrentlyPressed = true
            if wasRecentTap {
                // Clear the cached tap so a third quick press doesn't
                // re-fire activation immediately afterward.
                lastReleasedAt = nil
                lastPressedAt = nil
                shortcutTransitionPublisher.send(.doublePressActivation)
            } else {
                shortcutTransitionPublisher.send(.pressed)
            }
        case .released:
            lastReleasedAt = Date()
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        case .doublePressActivation:
            // The underlying transition function never emits this case;
            // it's synthesized in the .pressed branch above. Listed for
            // exhaustiveness.
            break
        }

        return Unmanaged.passUnretained(event)
    }
}
