import AppKit

/// Debug logging helper
private func debugLog(_ message: String) {
    let logFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("aerospace-animation-debug.log")
    let timestamp = Date().formatted(date: .omitted, time: .standard)
    let logMessage = "[\(timestamp)] \(message)\n"
    if let data = logMessage.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}

/// Ease-out cubic easing function for smooth deceleration
func easeOutCubic(_ t: Double) -> Double {
    1 - pow(1 - t, 3)
}

/// Linear interpolation between two CGFloat values
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
    a + (b - a) * CGFloat(t)
}

/// Check if a window position is off-screen (hidden in corner)
func isOffScreen(_ topLeft: CGPoint, _ size: CGSize) -> Bool {
    let windowRect = CGRect(origin: topLeft, size: size)
    // Check if window is visible on any screen
    for screen in NSScreen.screens {
        let screenFrame = screen.frame
        // If window overlaps significantly with any screen, it's not off-screen
        let intersection = windowRect.intersection(screenFrame)
        if !intersection.isNull && intersection.width > 50 && intersection.height > 50 {
            return false
        }
    }
    return true
}

/// Get the monitor bounds for a given target position
private func getMonitorBounds(for targetTopLeft: CGPoint) -> CGRect? {
    // Find the monitor that contains the target position
    for screen in NSScreen.screens {
        if screen.frame.contains(targetTopLeft) {
            return screen.frame
        }
    }
    // Fallback to main screen
    return NSScreen.main?.frame
}

/// Manages parallel window animations on a single thread
/// @unchecked because it's only accessed from the app's dedicated thread
final class WindowAnimationCoordinator: @unchecked Sendable {
    private var animations: [UInt32: WindowAnimation] = [:]
    private var isRunning = false
    private let frameInterval = 1.0 / 120.0  // ~120 fps

    struct WindowAnimation {
        let window: AXUIElement
        let startTopLeft: CGPoint
        let startSize: CGSize
        let targetTopLeft: CGPoint
        let targetSize: CGSize
        let startTime: Double
        let duration: Double
        let job: RunLoopJob
        var lastSetTopLeft: CGPoint?
        var lastSetSize: CGSize?
        let onComplete: (@Sendable () -> Void)?
    }

    func addAnimation(
        windowId: UInt32,
        window: AXUIElement,
        targetTopLeft: CGPoint?,
        targetSize: CGSize?,
        duration: Double,
        job: RunLoopJob,
        slideDirection: SlideDirection? = nil,
        onComplete: (@Sendable () -> Void)? = nil
    ) {
        // Get current position/size
        guard let currentTopLeft = window.get(Ax.topLeftCornerAttr),
              let currentSize = window.get(Ax.sizeAttr) else {
            // Fallback to instant if we can't get current values
            if let topLeft = targetTopLeft { window.set(Ax.topLeftCornerAttr, topLeft) }
            if let size = targetSize { window.set(Ax.sizeAttr, size) }
            return
        }

        let finalTargetTopLeft = targetTopLeft ?? currentTopLeft
        let finalTargetSize = targetSize ?? currentSize

        // Skip if nothing is changing
        if finalTargetTopLeft == currentTopLeft && finalTargetSize == currentSize {
            return
        }

        // Determine effective start position and size
        var effectiveStartTopLeft = currentTopLeft
        var effectiveStartSize = currentSize
        let windowIsOffScreen = isOffScreen(currentTopLeft, currentSize)

        if let direction = slideDirection, windowIsOffScreen {
            // Window is coming from off-screen - override start position to slide from specified direction
            // Start from monitor width away to match exit animation distance
            if let monitorBounds = getMonitorBounds(for: finalTargetTopLeft) {
                let slideDistance = monitorBounds.width
                effectiveStartTopLeft = CGPoint(
                    x: direction == .right
                        ? finalTargetTopLeft.x + slideDistance  // Start monitor-width to the right
                        : finalTargetTopLeft.x - slideDistance,  // Start monitor-width to the left
                    y: finalTargetTopLeft.y  // Keep target Y position
                )
                effectiveStartSize = finalTargetSize  // Start at target size for slide-in
                // Move window to start position before animating
                window.set(Ax.topLeftCornerAttr, effectiveStartTopLeft)
                window.set(Ax.sizeAttr, effectiveStartSize)
            }
        }

        animations[windowId] = WindowAnimation(
            window: window,
            startTopLeft: effectiveStartTopLeft,
            startSize: effectiveStartSize,
            targetTopLeft: finalTargetTopLeft,
            targetSize: finalTargetSize,
            startTime: CACurrentMediaTime(),
            duration: duration,
            job: job,
            lastSetTopLeft: nil,
            lastSetSize: nil,
            onComplete: onComplete
        )
        
        debugLog("Added animation for window \(windowId) from \(effectiveStartTopLeft) to \(finalTargetTopLeft)")

        if !isRunning {
            isRunning = true
            runAnimationLoop()
        }
    }

    func cancelAnimation(windowId: UInt32) {
        if animations[windowId] != nil {
            debugLog("Cancelling animation for window \(windowId)")
        }
        animations.removeValue(forKey: windowId)
    }
    
    func isAnimating(windowId: UInt32) -> Bool {
        animations[windowId] != nil
    }

    private func runAnimationLoop() {
        var lastFrameTime = CACurrentMediaTime()
        let epsilon: CGFloat = 0.5  // Skip updates if change is less than 0.5 pixels

        while !animations.isEmpty {
            let now = CACurrentMediaTime()
            var completedIds: [UInt32] = []
            var updates: [(UInt32, WindowAnimation)] = []

            for (windowId, anim) in animations {
                if anim.job.isCancelled {
                    completedIds.append(windowId)
                    continue
                }

                let elapsed = now - anim.startTime
                let progress = min(elapsed / anim.duration, 1.0)
                let t = easeOutCubic(progress)

                let x = lerp(anim.startTopLeft.x, anim.targetTopLeft.x, t)
                let y = lerp(anim.startTopLeft.y, anim.targetTopLeft.y, t)
                let w = lerp(anim.startSize.width, anim.targetSize.width, t)
                let h = lerp(anim.startSize.height, anim.targetSize.height, t)

                let newTopLeft = CGPoint(x: x, y: y)
                let newSize = CGSize(width: w, height: h)

                // Calculate total animation distance to determine if we can complete early
                let totalPositionDistance = max(
                    abs(anim.targetTopLeft.x - anim.startTopLeft.x),
                    abs(anim.targetTopLeft.y - anim.startTopLeft.y)
                )
                let totalSizeDistance = max(
                    abs(anim.targetSize.width - anim.startSize.width),
                    abs(anim.targetSize.height - anim.startSize.height)
                )
                
                // Only allow early completion for long-distance animations (>100px)
                // This prevents "pop" on short animations while avoiding slow tail on long ones
                let canCompleteEarly = totalPositionDistance > 100 || totalSizeDistance > 100
                
                if canCompleteEarly {
                    let positionDelta = max(
                        abs(newTopLeft.x - anim.targetTopLeft.x),
                        abs(newTopLeft.y - anim.targetTopLeft.y)
                    )
                    let sizeDelta = max(
                        abs(newSize.width - anim.targetSize.width),
                        abs(newSize.height - anim.targetSize.height)
                    )
                    
                    let closeEnough = positionDelta < 3.0 && sizeDelta < 3.0
                    
                    if closeEnough {
                        // Jump to final position and complete
                        anim.window.set(Ax.topLeftCornerAttr, anim.targetTopLeft)
                        anim.window.set(Ax.sizeAttr, anim.targetSize)
                        anim.onComplete?()
                        completedIds.append(windowId)
                        continue
                    }
                }
                
                if progress >= 1.0 {
                    // Animation time completed - set final position
                    anim.window.set(Ax.topLeftCornerAttr, anim.targetTopLeft)
                    anim.window.set(Ax.sizeAttr, anim.targetSize)
                    anim.onComplete?()
                    completedIds.append(windowId)
                    continue
                }

                // Only make AX calls if values changed significantly
                var updatedAnim = anim
                
                if anim.lastSetTopLeft == nil || 
                   abs(newTopLeft.x - anim.lastSetTopLeft!.x) > epsilon || 
                   abs(newTopLeft.y - anim.lastSetTopLeft!.y) > epsilon {
                    anim.window.set(Ax.topLeftCornerAttr, newTopLeft)
                    updatedAnim.lastSetTopLeft = newTopLeft
                }
                
                if anim.lastSetSize == nil || 
                   abs(newSize.width - anim.lastSetSize!.width) > epsilon || 
                   abs(newSize.height - anim.lastSetSize!.height) > epsilon {
                    anim.window.set(Ax.sizeAttr, newSize)
                    updatedAnim.lastSetSize = newSize
                }
                
                updates.append((windowId, updatedAnim))
            }

            // Apply updates after iteration to avoid mutation during iteration
            for (windowId, anim) in updates {
                animations[windowId] = anim
            }

            for id in completedIds {
                animations.removeValue(forKey: id)
            }

            if animations.isEmpty {
                break
            }

            // Use CFRunLoopRunInMode to allow new animations to be added during the wait
            let targetNextFrame = lastFrameTime + frameInterval
            let sleepTime = targetNextFrame - CACurrentMediaTime()
            if sleepTime > 0 {
                CFRunLoopRunInMode(.defaultMode, sleepTime, true)
            }
            lastFrameTime = CACurrentMediaTime()
        }

        isRunning = false
    }
}
