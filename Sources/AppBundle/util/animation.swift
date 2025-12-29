import AppKit

/// Ease-out cubic easing function for smooth deceleration
func easeOutCubic(_ t: Double) -> Double {
    1 - pow(1 - t, 3)
}

/// Linear interpolation between two CGFloat values
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
    a + (b - a) * CGFloat(t)
}

/// Check if a window position is off-screen (hidden in corner)
private func isOffScreen(_ topLeft: CGPoint, _ size: CGSize) -> Bool {
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
    }

    func addAnimation(
        windowId: UInt32,
        window: AXUIElement,
        targetTopLeft: CGPoint?,
        targetSize: CGSize?,
        duration: Double,
        job: RunLoopJob
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

        // Skip animation if window is coming from off-screen (hidden corner)
        // This prevents animation during workspace switches
        if isOffScreen(currentTopLeft, currentSize) {
            if let topLeft = targetTopLeft { window.set(Ax.topLeftCornerAttr, topLeft) }
            if let size = targetSize { window.set(Ax.sizeAttr, size) }
            return
        }

        animations[windowId] = WindowAnimation(
            window: window,
            startTopLeft: currentTopLeft,
            startSize: currentSize,
            targetTopLeft: finalTargetTopLeft,
            targetSize: finalTargetSize,
            startTime: CACurrentMediaTime(),
            duration: duration,
            job: job
        )

        if !isRunning {
            isRunning = true
            runAnimationLoop()
        }
    }

    func cancelAnimation(windowId: UInt32) {
        animations.removeValue(forKey: windowId)
    }

    private func runAnimationLoop() {
        var lastFrameTime = CACurrentMediaTime()

        while !animations.isEmpty {
            let now = CACurrentMediaTime()
            var completedIds: [UInt32] = []

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

                anim.window.set(Ax.sizeAttr, CGSize(width: w, height: h))
                anim.window.set(Ax.topLeftCornerAttr, CGPoint(x: x, y: y))

                if progress >= 1.0 {
                    completedIds.append(windowId)
                }
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
