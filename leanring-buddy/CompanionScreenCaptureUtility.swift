//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    enum CaptureError: LocalizedError {
        case noEligibleWindow
        var errorDescription: String? {
            switch self {
            case .noEligibleWindow: return "no eligible frontmost window was found"
            }
        }
    }

    /// Companion-flow entry point. Tries to capture only the frontmost
    /// user-app window for a sharper, focused image. Falls back to a
    /// full all-screens capture if no eligible window can be found
    /// (e.g. only Finder is frontmost with no open window, or a
    /// menu / popup is active).
    static func captureFrontmostFocusedRegionAsJPEG() async throws -> [CompanionScreenCapture] {
        do {
            return [try await captureFrontmostUserWindowAsJPEG()]
        } catch {
            print("📸 frontmost-window capture unavailable (\(error.localizedDescription)) — falling back to full-screen")
            return try await captureAllScreensAsJPEG()
        }
    }

    /// Captures only the frontmost non-Cue app window. Throws
    /// `CaptureError.noEligibleWindow` when no suitable window exists;
    /// callers should fall back to a full-screen capture.
    static func captureFrontmostUserWindowAsJPEG() async throws -> CompanionScreenCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let cueBundleId = Bundle.main.bundleIdentifier
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Filter to "real" non-Cue app windows. `windowLayer == 0` excludes
        // floating panels, menus, Spotlight, the dock, etc.
        let eligible = content.windows.filter { window in
            guard let app = window.owningApplication else { return false }
            if app.bundleIdentifier == cueBundleId { return false }
            if window.windowLayer != 0 { return false }
            return window.frame.width > 50 && window.frame.height > 50
        }

        // Prefer the OS-frontmost app's window; else pick the topmost
        // eligible window. `content.windows` is z-ordered front-to-back.
        var pickedWindow: SCWindow? = nil
        if let pid = frontmostPid {
            pickedWindow = eligible.first { $0.owningApplication?.processID == pid }
        }
        if pickedWindow == nil { pickedWindow = eligible.first }

        guard let window = pickedWindow else {
            throw CaptureError.noEligibleWindow
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let maxDimension = 1280
        let frameWidth = window.frame.width
        let frameHeight = window.frame.height
        let aspectRatio = frameWidth / max(frameHeight, 1)
        if frameWidth >= frameHeight {
            configuration.width = maxDimension
            configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
        } else {
            configuration.height = maxDimension
            configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
        }

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw NSError(domain: "CompanionScreenCapture", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to JPEG-encode the window capture"])
        }

        // SCWindow.frame uses Core Graphics screen coordinates (y down from
        // the top of the primary display). The downstream coord transform
        // and overlay routing both expect AppKit coordinates (y up from the
        // bottom — same space as NSEvent.mouseLocation and NSScreen.frame),
        // so convert before storing.
        let windowFrameInAppKit = convertCGRectToAppKitCoordinates(window.frame)

        let appName = window.owningApplication?.applicationName ?? "the user's app"
        let title = window.title?.trimmingCharacters(in: .whitespaces) ?? ""
        let label = title.isEmpty
            ? "user's current window — \(appName)"
            : "user's current window — \(appName): '\(title)'"

        return CompanionScreenCapture(
            imageData: jpegData,
            label: label,
            isCursorScreen: true,
            displayWidthInPoints: Int(windowFrameInAppKit.width),
            displayHeightInPoints: Int(windowFrameInAppKit.height),
            displayFrame: windowFrameInAppKit,
            screenshotWidthInPixels: configuration.width,
            screenshotHeightInPixels: configuration.height
        )
    }

    /// Flips y between Core Graphics screen coords (y down from top of
    /// primary display) and AppKit screen coords (y up from bottom). x is
    /// unchanged. Uses `NSScreen.screens.first.frame.maxY` as the reference
    /// — that's the primary display's upper edge in AppKit space.
    private static func convertCGRectToAppKitCoordinates(_ cgRect: CGRect) -> CGRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: cgRect.origin.x,
            y: primaryMaxY - cgRect.origin.y - cgRect.size.height,
            width: cgRect.size.width,
            height: cgRect.size.height
        )
    }
}
