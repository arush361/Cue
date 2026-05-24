//
//  ResponseSidePanelManager.swift
//  leanring-buddy
//
//  Owns the floating right-edge response panel: a borderless NSPanel that
//  slides in from the right when Claude is streaming a reply, hosts the
//  SwiftUI `ResponseSidePanelView`, and slides out when the user starts a
//  new turn or auto-hides for short responses 2 seconds after TTS ends.
//
//  Lifecycle pattern mirrors `OverlayWindowManager` in OverlayWindow.swift
//  but with a single-panel anchored layout instead of one panel per screen,
//  and `.floating` level (cursor overlay stays above us at `.screenSaver`).
//
//  The manager subscribes to three @Published properties on CompanionManager:
//    - isResponsePanelVisible: drives show/hide animations
//    - streamingResponseText:  used to decide whether to auto-hide short responses
//    - voiceState:             observed indirectly via the TTS-finished signal
//                              to schedule the auto-hide timer
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class ResponseSidePanelManager {
    /// Width of the floating panel in points. Designed for comfortable reading
    /// without dominating the screen. Fixed for simplicity; resizable can come later.
    private static let panelWidthInPoints: CGFloat = 380

    /// Margin from the right and top/bottom edges of the visible frame so the
    /// panel doesn't crash into the menu bar / dock.
    private static let panelEdgeMarginInPoints: CGFloat = 12

    /// Distance the panel travels during the slide-in / slide-out animation.
    /// Slightly wider than the panel itself so the slide-out fully exits the
    /// visible area before alpha hits zero.
    private static let slideAnimationOffsetInPoints: CGFloat = 420

    /// Length of a response considered "short". Short responses auto-hide
    /// after `autoHideAfterTTSDelaySeconds`; longer ones persist until the
    /// next push-to-talk or a manual close.
    private static let shortResponseCharacterThreshold: Int = 200

    /// How long to wait after TTS playback ends before fading a short-response
    /// panel out. Long enough for the user to register the panel was there,
    /// short enough that the next interaction feels clean.
    private static let autoHideAfterTTSDelaySeconds: TimeInterval = 2.0

    /// Initial / minimum panel height. Tuned to roughly fit the header,
    /// ~5 lines of body text at the 14pt font size, and the footer — so
    /// the panel opens compact and only grows as the response streams in.
    /// `nonisolated` so it can be used as a default-argument value from
    /// callers that aren't main-actor-isolated.
    nonisolated private static let minimumPanelHeightInPoints: CGFloat = 220

    /// Extra vertical breathing room subtracted from the screen's visible
    /// height when computing the max panel size, so the panel never butts
    /// directly against the menu bar or dock.
    nonisolated private static let panelTopBottomTotalMarginInPoints: CGFloat = 24

    private let companionManager: CompanionManager
    private var floatingResponsePanel: NSPanel?

    private var cancellables: Set<AnyCancellable> = []
    private var ttsCompletionObservationTimer: Timer?
    private var pendingAutoHideTask: Task<Void, Never>?

    /// True while the panel is currently visible on-screen (either fully
    /// shown or mid-slide-in). Used to avoid duplicate show animations
    /// when streaming chunks keep arriving.
    private var isPanelCurrentlyVisible: Bool = false

    /// The most recent height we've actually applied to the NSPanel.
    /// Used to skip redundant resizes when the SwiftUI side reports the
    /// same height repeatedly during stream updates.
    private var lastAppliedPanelHeight: CGFloat = ResponseSidePanelManager.minimumPanelHeightInPoints

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        subscribeToCompanionManagerState()
        startTTSCompletionObserver()
    }

    deinit {
        ttsCompletionObservationTimer?.invalidate()
    }

    // MARK: - Observation

    private func subscribeToCompanionManagerState() {
        // Drive show/hide off of `isResponsePanelVisible` so any code that
        // wants to dismiss the panel just flips the flag.
        companionManager.$isResponsePanelVisible
            .removeDuplicates()
            .sink { [weak self] shouldBeVisible in
                guard let self else { return }
                if shouldBeVisible {
                    self.showPanelIfNeeded()
                } else {
                    self.hidePanelIfShowing()
                }
            }
            .store(in: &cancellables)
    }

    /// Polls TTS playback state on a low-frequency timer so we can schedule
    /// the auto-hide window precisely when audio playback finishes (rather
    /// than when the network response finishes, which is much earlier).
    /// Polling is simpler than wiring a delegate through both TTS clients.
    private func startTTSCompletionObserver() {
        var wasPlayingLastTick = false
        ttsCompletionObservationTimer = Timer.scheduledTimer(
            withTimeInterval: 0.25,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let isPlayingThisTick = self.companionManager.isAnyTTSPlaying
                // Falling edge: TTS just transitioned from playing → idle.
                if wasPlayingLastTick && !isPlayingThisTick {
                    self.scheduleAutoHideForShortResponseIfApplicable()
                }
                wasPlayingLastTick = isPlayingThisTick
            }
        }
    }

    private func scheduleAutoHideForShortResponseIfApplicable() {
        let responseLength = companionManager.streamingResponseText.count
        guard responseLength > 0,
              responseLength < Self.shortResponseCharacterThreshold,
              isPanelCurrentlyVisible else {
            return
        }

        // Cancel any in-flight auto-hide so multiple TTS completions don't
        // stack delays on top of each other.
        pendingAutoHideTask?.cancel()
        pendingAutoHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoHideAfterTTSDelaySeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.companionManager.isResponsePanelVisible = false
        }
    }

    // MARK: - Show

    private func showPanelIfNeeded() {
        // Cancel any pending auto-hide — if a new response arrived, the
        // panel should stay open.
        pendingAutoHideTask?.cancel()
        pendingAutoHideTask = nil

        guard !isPanelCurrentlyVisible else { return }
        isPanelCurrentlyVisible = true

        let panel = floatingResponsePanel ?? makeNewFloatingResponsePanel()
        floatingResponsePanel = panel

        // Position offscreen to the right, then slide into place. Use the
        // last measured content height so a returning panel restores at
        // whatever size the previous response grew it to.
        let onScreenFrame = computeOnScreenPanelFrame(targetHeight: lastAppliedPanelHeight)
        var offScreenFrame = onScreenFrame
        offScreenFrame.origin.x = onScreenFrame.origin.x + Self.slideAnimationOffsetInPoints

        panel.setFrame(offScreenFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(onScreenFrame, display: true)
            panel.animator().alphaValue = 1.0
        }
    }

    private func makeNewFloatingResponsePanel() -> NSPanel {
        let initialFrame = computeOnScreenPanelFrame()

        let panel = NonStealingFloatingPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let hostingView = NSHostingView(rootView: ResponseSidePanelView(
            companionManager: companionManager,
            onCloseRequested: { [weak self] in
                self?.companionManager.isResponsePanelVisible = false
            },
            onIdealContentHeightChanged: { [weak self] reportedIdealHeight in
                Task { @MainActor in
                    self?.applyContentHeightChange(reportedIdealHeight)
                }
            }
        ))
        hostingView.frame = panel.contentLayoutRect
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        return panel
    }

    /// Computes the panel frame anchored to the right edge of the active
    /// screen. Height defaults to the minimum (~5 lines worth) but the
    /// caller can pass a larger value once the SwiftUI content has
    /// reported its measured height.
    private func computeOnScreenPanelFrame(
        targetHeight: CGFloat = ResponseSidePanelManager.minimumPanelHeightInPoints
    ) -> NSRect {
        let primaryScreen = NSScreen.main ?? NSScreen.screens.first!
        let visibleFrame = primaryScreen.visibleFrame

        let availableHeight = visibleFrame.height - Self.panelTopBottomTotalMarginInPoints
        let clampedTargetHeight = min(max(targetHeight, Self.minimumPanelHeightInPoints), availableHeight)

        return NSRect(
            x: visibleFrame.maxX - Self.panelWidthInPoints - Self.panelEdgeMarginInPoints,
            y: visibleFrame.minY + Self.panelEdgeMarginInPoints,
            width: Self.panelWidthInPoints,
            height: clampedTargetHeight
        )
    }

    /// Resizes the open panel to match the SwiftUI content's measured
    /// height. Called every time `ResponseSidePanelView` reports a new
    /// ideal height via its PreferenceKey. Skips updates that don't
    /// change the applied height by more than 1pt to avoid rebroadcast
    /// jitter during streaming.
    private func applyContentHeightChange(_ reportedIdealHeight: CGFloat) {
        guard isPanelCurrentlyVisible, let panel = floatingResponsePanel else {
            lastAppliedPanelHeight = max(
                reportedIdealHeight,
                Self.minimumPanelHeightInPoints
            )
            return
        }

        let primaryScreen = NSScreen.main ?? NSScreen.screens.first!
        let availableHeight = primaryScreen.visibleFrame.height - Self.panelTopBottomTotalMarginInPoints
        let clampedHeight = min(
            max(reportedIdealHeight, Self.minimumPanelHeightInPoints),
            availableHeight
        )

        guard abs(clampedHeight - lastAppliedPanelHeight) > 1.0 else { return }
        lastAppliedPanelHeight = clampedHeight

        let newFrame = computeOnScreenPanelFrame(targetHeight: clampedHeight)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(newFrame, display: true)
        }
    }

    // MARK: - Hide

    private func hidePanelIfShowing() {
        pendingAutoHideTask?.cancel()
        pendingAutoHideTask = nil

        guard isPanelCurrentlyVisible, let panel = floatingResponsePanel else { return }
        isPanelCurrentlyVisible = false

        let onScreenFrame = computeOnScreenPanelFrame(targetHeight: lastAppliedPanelHeight)
        var offScreenFrame = onScreenFrame
        offScreenFrame.origin.x = onScreenFrame.origin.x + Self.slideAnimationOffsetInPoints

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(offScreenFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            // Reset to compact for the next response so a short reply
            // doesn't inherit the size of the previous long one.
            // Hop to the main actor since the completionHandler is
            // Sendable and lastAppliedPanelHeight is main-actor-isolated.
            Task { @MainActor in
                self?.lastAppliedPanelHeight = Self.minimumPanelHeightInPoints
            }
        })
    }
}

// MARK: - Non-stealing floating panel

/// NSPanel subclass that explicitly refuses key / main status. The default
/// `.nonactivatingPanel` mask handles most of this but `canBecomeKey`
/// returning `false` makes the click-on-Copy behavior more predictable —
/// clicks land on the panel's controls without taking keyboard focus away
/// from whatever app the user was working in.
private final class NonStealingFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
