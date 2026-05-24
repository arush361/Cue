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

// MARK: - Granola-style palette (scoped to this view)

/// Color palette for the Granola-look response panel. Kept local to this
/// file so it doesn't bleed into the dark-themed parts of the app. If we
/// ever want to apply the same aesthetic to other surfaces, lift these
/// constants into `DesignSystem.swift` under a `DS.Granola.*` namespace.
private enum GranolaPaperPalette {
    /// Warm off-white "paper" background. Slightly translucent so the
    /// system glass material peeks through and the panel adapts to the
    /// user's wallpaper rather than feeling like a flat sticker.
    static let paperBackground = Color(red: 0.972, green: 0.961, blue: 0.937).opacity(0.92)

    /// Body text — near-black with a hint of warmth so it doesn't clash
    /// with the warm paper.
    static let primaryText = Color(red: 0.117, green: 0.117, blue: 0.117)

    /// Secondary text for the header title and labels. Mid-gray.
    static let secondaryText = Color(red: 0.32, green: 0.32, blue: 0.32)

    /// Placeholder text ("Listening for Claude's response…").
    static let tertiaryText = Color(red: 0.55, green: 0.54, blue: 0.52)

    /// Hairline borders for dividers and button outlines.
    static let hairlineBorder = Color(red: 0.86, green: 0.84, blue: 0.80)

    /// Subtle "control" fill behind round buttons (close, mute).
    static let controlBackground = Color(red: 0.91, green: 0.89, blue: 0.85)

    /// Hover/active state for those controls.
    static let controlBackgroundActive = Color(red: 0.84, green: 0.82, blue: 0.78)

    /// Pill-button background for the Copy action.
    static let pillButtonBackground = Color(red: 0.94, green: 0.92, blue: 0.88)

    /// Granola-style muted green accent — used for the live-status dot
    /// and the "Copied!" confirmation chip.
    static let mutedGreenAccent = Color(red: 0.36, green: 0.55, blue: 0.42)
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

    /// Granola-style background: warm paper layer with a hint of system
    /// blur underneath so the panel adapts to the user's wallpaper
    /// without feeling translucent. The blur layer is `.ultraThinMaterial`
    /// on all macOS versions; the cream tint is what gives it the paper
    /// feel.
    @ViewBuilder
    private var panelBackgroundLayer: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(GranolaPaperPalette.paperBackground)
        }
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
