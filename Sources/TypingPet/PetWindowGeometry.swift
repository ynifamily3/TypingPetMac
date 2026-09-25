import Foundation

struct PetProximityOpacity {
    static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let horizontal = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let vertical = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(horizontal, vertical)
    }

    static func opacity(
        mouseLocation: CGPoint,
        petFrame: CGRect,
        proximityRadius: CGFloat = 140,
        minimumOpacity: CGFloat = 0.3
    ) -> CGFloat {
        guard proximityRadius > 0 else { return 1 }
        let normalizedDistance = min(
            max(distance(from: mouseLocation, to: petFrame) / proximityRadius, 0),
            1
        )
        let easedDistance = normalizedDistance * normalizedDistance * (3 - 2 * normalizedDistance)
        return minimumOpacity + (1 - minimumOpacity) * easedDistance
    }
}

struct PetDragSample {
    let point: CGPoint
    let timestamp: TimeInterval
}

struct PetMotionStep {
    let origin: CGPoint
    let velocity: CGVector
}

struct PetMotionPhysics {
    static func releaseVelocity(
        samples: [PetDragSample],
        lookback: TimeInterval = 0.12,
        maximumSpeed: CGFloat = 900
    ) -> CGVector {
        guard let last = samples.last else { return .zero }
        let cutoff = last.timestamp - lookback
        guard let first = samples.first(where: { $0.timestamp >= cutoff }),
              last.timestamp > first.timestamp else { return .zero }

        let elapsed = CGFloat(last.timestamp - first.timestamp)
        var velocity = CGVector(
            dx: (last.point.x - first.point.x) / elapsed,
            dy: (last.point.y - first.point.y) / elapsed
        )
        let speed = hypot(velocity.dx, velocity.dy)
        if speed > maximumSpeed {
            let factor = maximumSpeed / speed
            velocity.dx *= factor
            velocity.dy *= factor
        }
        return velocity
    }

    static func advance(
        origin: CGPoint,
        size: CGSize,
        velocity: CGVector,
        elapsed: TimeInterval,
        bounds: CGRect,
        velocityRetentionPerSecond: CGFloat = 0.004,
        edgeRestitution: CGFloat = 0.14
    ) -> PetMotionStep {
        let delta = CGFloat(max(0, elapsed))
        var nextOrigin = CGPoint(
            x: origin.x + velocity.dx * delta,
            y: origin.y + velocity.dy * delta
        )
        let decay = pow(velocityRetentionPerSecond, delta)
        var nextVelocity = CGVector(
            dx: velocity.dx * decay,
            dy: velocity.dy * decay
        )

        let maximumX = max(bounds.minX, bounds.maxX - size.width)
        let maximumY = max(bounds.minY, bounds.maxY - size.height)
        if nextOrigin.x < bounds.minX {
            nextOrigin.x = bounds.minX
            nextVelocity.dx = abs(nextVelocity.dx) * edgeRestitution
        } else if nextOrigin.x > maximumX {
            nextOrigin.x = maximumX
            nextVelocity.dx = -abs(nextVelocity.dx) * edgeRestitution
        }
        if nextOrigin.y < bounds.minY {
            nextOrigin.y = bounds.minY
            nextVelocity.dy = abs(nextVelocity.dy) * edgeRestitution
        } else if nextOrigin.y > maximumY {
            nextOrigin.y = maximumY
            nextVelocity.dy = -abs(nextVelocity.dy) * edgeRestitution
        }

        return PetMotionStep(origin: nextOrigin, velocity: nextVelocity)
    }
}

struct PetResizeGeometry {
    static func scale(
        initialScale: CGFloat,
        initialSize: CGSize,
        dragDelta: CGPoint,
        minimumScale: CGFloat = 0.35,
        maximumScale: CGFloat = 1.25
    ) -> CGFloat {
        guard initialSize.width > 0, initialSize.height > 0 else {
            return min(max(initialScale, minimumScale), maximumScale)
        }

        let horizontalFactor = (initialSize.width + dragDelta.x) / initialSize.width
        let verticalFactor = (initialSize.height + dragDelta.y) / initialSize.height
        let normalizedHorizontalDrag = abs(dragDelta.x / initialSize.width)
        let normalizedVerticalDrag = abs(dragDelta.y / initialSize.height)
        let factor = normalizedHorizontalDrag >= normalizedVerticalDrag
            ? horizontalFactor
            : verticalFactor

        return min(max(initialScale * factor, minimumScale), maximumScale)
    }
}
