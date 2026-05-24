//
//  ResponseSidePanelView.swift
//  leanring-buddy
//
//  SwiftUI content for the right-edge live-response panel. Shows Claude's
//  streamed reply in real time, with copy / mute / close controls and a
//  transient "Copied!" toast.
//
//  Visual treatment is intentionally Granola-inspired:
//    - Warm cream paper background (translucent over the system glass)
//    - Near-black body text on the cream surface
//    - Hairline borders and very soft shadows
//    - Pill-shaped buttons with low-contrast fills
//    - Muted green accent for confirmation toasts
//
//  Note that this is a deliberate aesthetic departure from the rest of
//  Cue (the menu bar panel and cursor overlay are dark-themed). Granola
//  style was specifically requested for the live response surface so it
//  reads as a calm "notes" pane rather than a chrome HUD.
//
//  Height is driven by content: the view reports its ideal height back
//  to the panel manager via a PreferenceKey, and the NSPanel resizes
//  accordingly. The panel opens at ~5 lines tall and grows as the
//  response streams in.
//

import SwiftUI

// MARK: - Content size reporting

/// PreferenceKey used by `ResponseSidePanelView` to tell its surrounding
/// NSPanel host (`ResponseSidePanelManager`) how tall the SwiftUI content
/// wants to be. The host clamps this to a min/max range and animates the
/// NSPanel's frame to match.
struct ResponseSidePanelIdealHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Adaptive panel chrome palette (scoped to this view)

/// Color palette for the response panel. All colors are system-adaptive
/// so the panel stays legible whether the user is in Light Mode or Dark
/// Mode and whatever their wallpaper looks like underneath the
/// `.ultraThinMaterial` glass backing.
///
/// Kept under the original `GranolaPaperPalette` name only to minimize
/// the diff — the Granola cream paper itself was retired so the panel
/// reads as near-transparent glass over the system blur.
private enum GranolaPaperPalette {
    /// Body / header text. White on dark appearance, black on light.
    /// Pulls high contrast against the system glass material.
    static let primaryText = Color.primary

    /// Header title and secondary labels.
    static let secondaryText = Color.secondary

    /// Placeholder ("Listening for Claude's response…").
    static let tertiaryText = Color.secondary.opacity(0.55)

    /// Hairline borders for dividers and button outlines. Adapts to
    /// appearance via Color.primary.
    static let hairlineBorder = Color.primary.opacity(0.10)

    /// Subtle "control" fill behind round buttons (close, mute).
    static let controlBackground = Color.primary.opacity(0.10)

    /// Hover/active state for those controls.
    static let controlBackgroundActive = Color.primary.opacity(0.18)

    /// Pill-button background for the Copy action.
    static let pillButtonBackground = Color.primary.opacity(0.08)

    /// Muted green accent — used for the live-status dot and the
    /// "Copied!" confirmation chip. Same color in both appearances
    /// because the green works on both light and dark glass backings.
    static let mutedGreenAccent = Color(red: 0.36, green: 0.65, blue: 0.46)
}

struct ResponseSidePanelView: View {
    @ObservedObject var companionManager: CompanionManager
    let onCloseRequested: () -> Void
    /// Called every time the view's ideal height changes. The host panel
    /// uses this to resize its NSPanel so the panel grows with the text.
    let onIdealContentHeightChanged: (CGFloat) -> Void

    /// Whether the "Copied!" confirmation toast is visible right now.
    /// Auto-clears 2 seconds after the user clicks Copy.
    @State private var isCopiedToastVisible: Bool = false

    /// Whether the user has muted the current response's audio. Flips
    /// the speaker icon between `speaker.wave.2.fill` and
    /// `speaker.slash.fill`. Resets to false whenever a fresh response
    /// arrives (detected via `streamingResponseText` clearing).
    @State private var isAudioMutedByUser: Bool = false

    /// Anchor id used to auto-scroll to the latest streamed text chunk.
    private let scrollToBottomAnchorId = "responseTextBottomAnchor"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader

            granolaDivider

            scrollingResponseText

            granolaDivider

            panelFooter
        }
        .background(panelBackgroundLayer)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(GranolaPaperPalette.hairlineBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.10), radius: 18, x: -4, y: 6)
        .background(
            // Report the panel's natural height so the host NSPanel can
            // resize itself to fit the content exactly.
            GeometryReader { geometryProxy in
                Color.clear.preference(
                    key: ResponseSidePanelIdealHeightPreferenceKey.self,
                    value: geometryProxy.size.height
                )
            }
        )
        .onPreferenceChange(ResponseSidePanelIdealHeightPreferenceKey.self) { newIdealHeight in
            onIdealContentHeightChanged(newIdealHeight)
        }
        .onChange(of: companionManager.streamingResponseText) { oldValue, newValue in
            // Reset mute state when a new response starts or ends so the
            // icon reflects "audio is playing" by default.
            if (oldValue.isEmpty && !newValue.isEmpty) ||
               (!oldValue.isEmpty && newValue.isEmpty) {
                isAudioMutedByUser = false
            }
        }
    }

    /// Granola-style hairline divider, inset from edges so it doesn't
    /// touch the rounded corner. Subtle enough to almost disappear.
    private var granolaDivider: some View {
        Rectangle()
            .fill(GranolaPaperPalette.hairlineBorder)
            .frame(height: 0.5)
            .padding(.horizontal, 16)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 10) {
            // Subtle "live" status dot.
            Circle()
                .fill(GranolaPaperPalette.mutedGreenAccent)
                .frame(width: 7, height: 7)

            Text("Response")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(GranolaPaperPalette.primaryText)
                .tracking(-0.1)

            Spacer()

            muteToggleButton
            closeButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Header controls

    /// Round close button using Granola's subtle "control" fill. The X
    /// itself uses bold dark ink so it's unmistakable on the cream paper.
    private var closeButton: some View {
        granolaRoundControlButton(
            iconSystemName: "xmark",
            iconWeight: .bold,
            iconSize: 11,
            accessibilityLabel: "Close the response panel",
            action: onCloseRequested
        )
    }

    /// Toggles between "audio is playing / will play" and "audio muted".
    /// First click stops the in-flight TTS. Second click re-speaks the
    /// current response from the beginning.
    private var muteToggleButton: some View {
        granolaRoundControlButton(
            iconSystemName: isAudioMutedByUser ? "speaker.slash.fill" : "speaker.wave.2.fill",
            iconWeight: .semibold,
            iconSize: 11,
            accessibilityLabel: isAudioMutedByUser ? "Replay audio" : "Mute audio",
            action: handleMuteToggle
        )
    }

    /// Shared Granola-style round-button construction so the mute and
    /// close buttons stay visually consistent.
    private func granolaRoundControlButton(
        iconSystemName: String,
        iconWeight: Font.Weight,
        iconSize: CGFloat,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: iconSystemName)
                .font(.system(size: iconSize, weight: iconWeight))
                .foregroundColor(GranolaPaperPalette.primaryText)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(GranolaPaperPalette.controlBackground)
                )
                .overlay(
                    Circle().stroke(GranolaPaperPalette.hairlineBorder, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(accessibilityLabel)
    }

    private func handleMuteToggle() {
        if isAudioMutedByUser {
            companionManager.replayCurrentResponseTTS()
            isAudioMutedByUser = false
        } else {
            companionManager.muteCurrentTTSPlayback()
            isAudioMutedByUser = true
        }
    }

    // MARK: - Scrolling response body

    private var scrollingResponseText: some View {
        ScrollViewReader { scrollViewProxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if companionManager.streamingResponseText.isEmpty {
                        Text("Listening for Claude's response…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(GranolaPaperPalette.tertiaryText)
                            .italic()
                            .padding(.top, 2)
                    } else {
                        Text(companionManager.streamingResponseText)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(GranolaPaperPalette.primaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(3)
                    }

                    // Invisible anchor for auto-scroll on each new chunk.
                    Color.clear
                        .frame(height: 1)
                        .id(scrollToBottomAnchorId)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: companionManager.streamingResponseText) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    scrollViewProxy.scrollTo(scrollToBottomAnchorId, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Footer (Copy button + toast)

    private var panelFooter: some View {
        HStack(spacing: 10) {
            Button(action: copyResponseToClipboard) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                    Text("Copy")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(GranolaPaperPalette.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(GranolaPaperPalette.pillButtonBackground)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(GranolaPaperPalette.hairlineBorder, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(companionManager.streamingResponseText.isEmpty)
            .opacity(companionManager.streamingResponseText.isEmpty ? 0.5 : 1.0)

            Spacer()

            // The "Copied!" toast lives in the footer so it doesn't shift
            // the response text or move during streaming. Uses the muted
            // green Granola accent for confirmation.
            if isCopiedToastVisible {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Copied!")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(GranolaPaperPalette.mutedGreenAccent)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Background

    /// Near-transparent background: just the system glass material, no
    /// additional tint. `.ultraThinMaterial` is the most see-through of
    /// the SwiftUI materials and adapts to the wallpaper underneath, so
    /// the panel feels almost like a piece of frosted glass floating
    /// over whatever is on screen.
    @ViewBuilder
    private var panelBackgroundLayer: some View {
        Rectangle().fill(.ultraThinMaterial)
    }

    // MARK: - Copy action

    private func copyResponseToClipboard() {
        let textToCopy = companionManager.streamingResponseText
        guard !textToCopy.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textToCopy, forType: .string)

        withAnimation(.easeOut(duration: 0.15)) {
            isCopiedToastVisible = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) {
                    isCopiedToastVisible = false
                }
            }
        }
    }
}
