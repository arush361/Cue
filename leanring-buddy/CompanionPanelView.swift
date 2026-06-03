//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AVFoundation
import Combine
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var emailInput: String = ""
    @State private var isAPIKeyRowExpanded: Bool = false
    @State private var apiKeyInput: String = ""
    @State private var apiKeySaveStatus: APIKeySaveStatus = .idle

    /// Drives the pulsing red dot when a continuous session is active.
    @State private var continuousIndicatorPulse: Bool = false
    /// Toggled every second to force the countdown label to re-render.
    @State private var continuousSessionTick: Bool = false
    /// 1Hz ticker fed into the indicator row's onReceive so the
    /// "mm:ss left" countdown stays current without complex Combine.
    private let panelClockTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Brief status to render under the field after a save / clear attempt.
    enum APIKeySaveStatus: Equatable {
        case idle
        case saved
        case failed
        case cleared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            // Continuous-listening session indicator. Visible only while
            // a hands-free session is active. Pulses to remind the user
            // the mic is hot; tap to exit.
            if companionManager.isContinuousSessionActive {
                Spacer().frame(height: 10)
                continuousSessionIndicatorRow
                    .padding(.horizontal, 16)
            }

            // Steady-state panel (onboarded + permissions granted):
            // organized into three labeled sections. Daily-use controls
            // visible without scrolling; setup-once controls (API key)
            // collapsed by default.
            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer().frame(height: 18)

                // MODEL & VOICE — how Cue responds.
                panelSection(title: "MODEL & VOICE") {
                    modelPickerRow
                    voicePickerRow
                }

                Spacer().frame(height: 14)

                // DISPLAY — what Cue looks like on screen.
                panelSection(title: "DISPLAY") {
                    cursorColorPickerRow
                    showResponseSidePanelToggleRow
                }

                Spacer().frame(height: 14)

                // PRIVACY & CONNECTION — what Cue sends + the API key.
                panelSection(title: "PRIVACY & CONNECTION") {
                    webSearchToggleRow
                    anthropicAPIKeyRow
                }

                Spacer().frame(height: 16)

                dmFarzaButton.padding(.horizontal, 16)
            }

            // Setup-time UI: permissions section (when something's missing)
            // and the start button (when onboarding hasn't been completed).
            if !companionManager.allPermissionsGranted {
                Spacer().frame(height: 16)
                settingsSection.padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer().frame(height: 16)
                startButton.padding(.horizontal, 16)
            }

            Spacer().frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    /// Wraps a group of rows in a labeled section. Section header is
    /// small uppercase semibold (matches the existing PERMISSIONS label
    /// style at `settingsSection`). Rows inside get consistent spacing.
    @ViewBuilder
    private func panelSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            content()
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Cue")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .cueDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Continuous Session Indicator

    /// Pulsing red dot + countdown shown at the top of the panel while
    /// a hands-free continuous session is active. Tap to exit (alternate
    /// to the Cmd+Ctrl hotkey).
    private var continuousSessionIndicatorRow: some View {
        Button(action: {
            companionManager.exitContinuousSession(reason: .manual)
        }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(continuousIndicatorPulse ? 1.0 : 0.35)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: continuousIndicatorPulse)
                Text("Listening")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Text(continuousSessionCountdownText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.red.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.red.opacity(0.25), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { continuousIndicatorPulse = true }
        .onDisappear { continuousIndicatorPulse = false }
        .onReceive(panelClockTicker) { _ in
            // Force the countdown to re-evaluate every second by
            // touching state. Cheap and reliable.
            continuousSessionTick.toggle()
        }
    }

    /// mm:ss countdown text, computed from companionManager.continuousSessionEndsAt.
    /// Reads continuousSessionTick so the view re-renders on each tick.
    private var continuousSessionCountdownText: String {
        _ = continuousSessionTick   // dependency hook for the timer
        guard let endsAt = companionManager.continuousSessionEndsAt else { return "" }
        let secondsLeft = max(0, Int(endsAt.timeIntervalSinceNow.rounded()))
        let mm = secondsLeft / 60
        let ss = secondsLeft % 60
        return String(format: "%d:%02d left", mm, ss)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Hold Control+Option to talk.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted && !companionManager.hasSubmittedEmail {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop your email to get started.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("If I keep building this, I'll keep you in the loop.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Cue.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant all four below to keep using Cue.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, this is Cue.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("A side project I made for fun to help me learn stuff as I use my computer.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Nothing runs in the background. Cue will only take a screenshot when you press the hot key. So, you can give that permission in peace. If you are still sus, eh, I can't do much there champ.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Email + Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            if !companionManager.hasSubmittedEmail {
                VStack(spacing: 8) {
                    TextField("Enter your email", text: $emailInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )

                    Button(action: {
                        companionManager.submitEmail(emailInput)
                    }) {
                        Text("Submit")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .fill(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          ? DS.Colors.accent.opacity(0.4)
                                          : DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button(action: {
                    companionManager.triggerOnboarding()
                }) {
                    Text("Start")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }
        }
    }

    // MARK: - Anthropic API Key Row

    /// Expandable row inside the PERMISSIONS settings section that lets
    /// the user paste + save their Anthropic API key. The key is stored
    /// in macOS Keychain via `AnthropicAPIKeychain`; the full value is
    /// never re-displayed — only "sk-ant-…XXXX" (last 4) once saved.
    /// On save, CompanionManager rebuilds the ClaudeAPI client so the
    /// next push-to-talk uses the new key immediately.
    private var anthropicAPIKeyRow: some View {
        VStack(spacing: 6) {
            // Collapsed header — tap to expand.
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isAPIKeyRowExpanded.toggle() } }) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 14)
                        Text("API key")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                    Spacer()
                    if companionManager.hasSavedAnthropicAPIKey,
                       let lastFour = companionManager.savedAnthropicAPIKeyLastFour {
                        Text("sk-ant-…\(lastFour)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(DS.Colors.textTertiary)
                    } else {
                        Text("not set")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    Image(systemName: isAPIKeyRowExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isAPIKeyRowExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("sk-ant-…", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .disableAutocorrection(true)

                    HStack(spacing: 8) {
                        Button(action: saveAPIKey) {
                            Text("Save")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(DS.Colors.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if companionManager.hasSavedAnthropicAPIKey {
                            Button(action: clearAPIKey) {
                                Text("Clear saved key")
                                    .font(.system(size: 12))
                                    .foregroundColor(DS.Colors.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()

                        switch apiKeySaveStatus {
                        case .idle:
                            EmptyView()
                        case .saved:
                            Text("✓ Saved")
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                        case .failed:
                            Text("Save failed")
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                        case .cleared:
                            Text("Cleared")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }

                    Text("Stored in macOS Keychain. Never shown after save.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            }
        }
    }

    private func saveAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let didSave = companionManager.saveAnthropicAPIKey(trimmed)
        apiKeySaveStatus = didSave ? .saved : .failed
        if didSave { apiKeyInput = "" }
        // Auto-clear the status pill after a moment so the row settles.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if apiKeySaveStatus == .saved || apiKeySaveStatus == .failed {
                apiKeySaveStatus = .idle
            }
        }
    }

    private func clearAPIKey() {
        companionManager.clearSavedAnthropicAPIKey()
        apiKeyInput = ""
        apiKeySaveStatus = .cleared
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if apiKeySaveStatus == .cleared {
                apiKeySaveStatus = .idle
            }
        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }



    // MARK: - Cursor Color Picker

    /// Four-swatch picker for the cursor color. The currently selected
    /// swatch gets a white ring + a subtle drop shadow so it reads as
    /// the active choice. Tapping a swatch persists the new color via
    /// CompanionManager and updates the live cursor immediately.
    private var cursorColorPickerRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Cursor color")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            HStack(spacing: 8) {
                ForEach(CompanionCursorColor.allCases, id: \.self) { availableCursorColor in
                    cursorColorSwatchButton(forCursorColor: availableCursorColor)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func cursorColorSwatchButton(forCursorColor cursorColorOption: CompanionCursorColor) -> some View {
        let isCurrentlySelected = companionManager.selectedCursorColor == cursorColorOption
        return Button(action: {
            companionManager.setSelectedCursorColor(cursorColorOption)
        }) {
            Circle()
                .fill(cursorColorOption.swiftUIColor)
                .frame(width: 18, height: 18)
                .overlay(
                    // Inner highlight ring on the selected swatch — uses
                    // white so it reads on any cursor color.
                    Circle()
                        .stroke(Color.white, lineWidth: isCurrentlySelected ? 2 : 0)
                        .padding(2)
                )
                .overlay(
                    // Outer hairline border so unselected swatches still
                    // have a definition edge against the dark panel.
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(
                    color: cursorColorOption.swiftUIColor.opacity(isCurrentlySelected ? 0.55 : 0),
                    radius: isCurrentlySelected ? 5 : 0,
                    x: 0, y: 0
                )
                .scaleEffect(isCurrentlySelected ? 1.10 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isCurrentlySelected)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("\(cursorColorOption.displayName) cursor")
    }

    // MARK: - Web Search Toggle

    /// Lets the user enable / disable Claude's web-search tool for the
    /// chat endpoint. When on, every response request advertises the
    /// `web_search_20250305` server tool and Claude can pull live info
    /// (news, weather, sports, recent events). Capped at 3 searches
    /// per response.
    private var webSearchToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Search the web")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isWebSearchEnabled },
                set: { companionManager.setWebSearchEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Show Response Panel Toggle

    /// Lets the user disable the right-edge live-response panel entirely.
    /// When off, Cue still speaks responses but no panel appears.
    private var showResponseSidePanelToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.righthalf.inset.filled")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show response panel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.showResponseSidePanelPreference },
                set: { companionManager.setShowResponseSidePanelPreference($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Show Cue Cursor Toggle

    private var showCueCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show Cue")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isCueCursorEnabled },
                set: { companionManager.setCueCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Speech to Text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        HStack {
            Text("Model")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                modelOptionButton(label: "Sonnet", modelID: "claude-sonnet-4-6")
                modelOptionButton(label: "Opus", modelID: "claude-opus-4-6")
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
    }

    /// Voice picker. Uses a SwiftUI `Menu` (not `Picker`) so we can give
    /// the trigger label a visible chrome — `Picker(.menu)` on macOS dark
    /// panels renders as a near-invisible plain-text button. The trigger
    /// matches the model picker's rounded-rect + border style and shows
    /// the currently-selected voice name plus a chevron so it reads as
    /// "tap me." Selection binds to `selectedTTSVoiceIdentifier`
    /// (UserDefaults-backed, hot-swaps the live voice in LocalTTSClient).
    private var voicePickerRow: some View {
        let voices = LocalTTSClient.installedSelectableVoices()
        let currentLabel: String = {
            guard let id = companionManager.selectedTTSVoiceIdentifier,
                  let voice = voices.first(where: { $0.identifier == id }) else {
                return "Auto"
            }
            return voice.name
        }()
        return HStack {
            Text("Voice")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            Menu {
                Button(action: { companionManager.setSelectedTTSVoice(identifier: nil) }) {
                    HStack {
                        Text("Auto (best installed)")
                        if companionManager.selectedTTSVoiceIdentifier == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Divider()
                ForEach(voices, id: \.identifier) { voice in
                    Button(action: { companionManager.setSelectedTTSVoice(identifier: voice.identifier) }) {
                        HStack {
                            Text(LocalTTSClient.displayName(for: voice))
                            if companionManager.selectedTTSVoiceIdentifier == voice.identifier {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func modelOptionButton(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return Button(action: {
            companionManager.setSelectedModel(modelID)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Contact Me Button

    private var dmFarzaButton: some View {
        Button(action: {
            if let url = URL(string: "https://www.linkedin.com/in/sharma-arush/") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 12, weight: .medium))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Got feedback? Contact me")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Bugs, ideas, anything — connect on LinkedIn.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit Cue")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if companionManager.hasCompletedOnboarding {
                Spacer()

                Button(action: {
                    companionManager.replayOnboarding()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("Watch Onboarding Again")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}
