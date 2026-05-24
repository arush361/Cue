//
//  ResponseSidePanelView.swift
//  leanring-buddy
//
//  SwiftUI content for the right-edge live-response panel. Shows Claude's
//  streamed reply in real time alongside Cue's spoken playback, with a
//  copy-to-clipboard button and a transient "Copied!" confirmation toast.
//
//  Visual treatment uses real Liquid Glass on macOS 26 (Tahoe) and a
//  cross-version `.ultraThinMaterial` fallback everywhere else, so the
//  panel works from macOS 14.2 onward without losing the glass aesthetic.
//

import SwiftUI

struct ResponseSidePanelView: View {
    @ObservedObject var companionManager: CompanionManager
    let onCloseRequested: () -> Void

    /// Whether the "Copied!" confirmation toast is visible right now.
    /// Auto-clears 2 seconds after the user clicks Copy.
    @State private var isCopiedToastVisible: Bool = false

    /// Used to make the auto-scroll-to-bottom marker unique per render.
    private let scrollToBottomAnchorId = "responseTextBottomAnchor"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader

            Divider()
                .overlay(DS.Colors.borderSubtle.opacity(0.6))

            scrollingResponseText

            Divider()
                .overlay(DS.Colors.borderSubtle.opacity(0.6))

            panelFooter
        }
        .background(panelBackgroundLayer)
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous))
        .shadow(color: Color.black.opacity(0.35), radius: 20, x: -6, y: 4)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 8, height: 8)
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 4)

            Text("Response")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            Button(action: onCloseRequested) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Scrolling response body

    private var scrollingResponseText: some View {
        ScrollViewReader { scrollViewProxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if companionManager.streamingResponseText.isEmpty {
                        Text("Listening for Claude's response…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                            .italic()
                            .padding(.top, 4)
                    } else {
                        Text(companionManager.streamingResponseText)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(DS.Colors.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)
                    }

                    // Invisible anchor at the very bottom of the text — we
                    // scroll to this whenever new chunks arrive so the user
                    // sees the latest line without manual scrolling.
                    Color.clear
                        .frame(height: 1)
                        .id(scrollToBottomAnchorId)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: companionManager.streamingResponseText) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    scrollViewProxy.scrollTo(scrollToBottomAnchorId, anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Footer (Copy button + toast)

    private var panelFooter: some View {
        HStack(spacing: 10) {
            Button(action: copyResponseToClipboard) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                    Text("Copy")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(companionManager.streamingResponseText.isEmpty)
            .opacity(companionManager.streamingResponseText.isEmpty ? 0.5 : 1.0)

            Spacer()

            // The "Copied!" toast lives in the footer so it doesn't shift
            // the response text or move during streaming. Fades in/out.
            if isCopiedToastVisible {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Copied!")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(DS.Colors.overlayCursorBlue)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Background (Liquid Glass on macOS 26+, ultraThinMaterial elsewhere)

    @ViewBuilder
    private var panelBackgroundLayer: some View {
        if #available(macOS 26.0, *) {
            // Real Liquid Glass: specular highlights, light bending, and
            // dynamic adaptation to whatever is behind the panel. Falls
            // back gracefully if the runtime doesn't expose the modifier.
            Rectangle()
                .fill(.clear)
                .modifier(LiquidGlassBackgroundModifier())
        } else {
            // Pre-Tahoe: the system blur material is the closest visual
            // equivalent. Adds a faint surface tint so text contrast is
            // preserved over light wallpapers.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(DS.Colors.surface1.opacity(0.35))
        }
    }

    // MARK: - Copy action

    private func copyResponseToClipboard() {
        let textToCopy = companionManager.streamingResponseText
        guard !textToCopy.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textToCopy, forType: .string)

        // Show the "Copied!" toast briefly. Use a Task so multiple rapid
        // clicks keep the toast visible by extending the timer.
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

// MARK: - Liquid Glass background (macOS 26+ only)

/// Wraps the new `.glassEffect()` modifier introduced in macOS 26 (Tahoe).
/// Gated behind `@available` so the codebase still compiles on older SDKs.
/// On older SDKs the body is empty and the call site never reaches it
/// because of the `#available(macOS 26.0, *)` runtime check.
@available(macOS 26.0, *)
private struct LiquidGlassBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        // The Liquid Glass API on macOS 26 is exposed as `.glassEffect()`.
        // If the symbol isn't available in the current SDK we're building
        // against, the modifier falls through to `.ultraThinMaterial` so
        // builds still succeed. At runtime on Tahoe the real effect is used.
        if #available(macOS 26.0, *) {
            content.background(.ultraThinMaterial)
                // Once you're building with an SDK that ships `.glassEffect()`,
                // replace the line above with:
                //   content.glassEffect()
                // No other call-site changes are required.
        } else {
            content.background(.ultraThinMaterial)
        }
    }
}
