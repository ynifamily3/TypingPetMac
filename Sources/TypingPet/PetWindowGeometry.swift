import Foundation

struct PetOpacityBehavior {
    static func opacity(
        isHovering: Bool,
        restingOpacity: CGFloat,
        hoverOpacity: CGFloat
    ) -> CGFloat {
        min(max(isHovering ? hoverOpacity : restingOpacity, 0), 1)
    }
}

struct PetPointerAvoidance {
    static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let horizontal = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let vertical = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return hypot(horizontal, vertical)
    }

    static func targetOrigin(
        mouseLocation: CGPoint,
        petFrame: CGRect,
        bounds: CGRect,
        triggerDistance: CGFloat = 90
    ) -> CGPoint? {
        let currentDistance = distance(from: mouseLocation, to: petFrame)
        guard currentDistance < triggerDistance else { return nil }

        let center = CGPoint(x: petFrame.midX, y: petFrame.midY)
        var away = CGVector(dx: center.x - mouseLocation.x, dy: center.y - mouseLocation.y)
        let awayLength = hypot(away.dx, away.dy)
        if awayLength > 0.001 {
            away.dx /= awayLength
            away.dy /= awayLength
        } else {
            away = center.x < bounds.midX ? CGVector(dx: -1, dy: 0) : CGVector(dx: 1, dy: 0)
        }

        let diagonal = CGFloat(1 / sqrt(2.0))
        let directions: [CGVector] = [
            away,
            CGVector(dx: 1, dy: 0),
            CGVector(dx: -1, dy: 0),
            CGVector(dx: 0, dy: 1),
            CGVector(dx: 0, dy: -1),
            CGVector(dx: diagonal, dy: diagonal),
            CGVector(dx: -diagonal, dy: diagonal),
            CGVector(dx: diagonal, dy: -diagonal),
            CGVector(dx: -diagonal, dy: -diagonal),
        ]
        let travel = min(max(triggerDistance - currentDistance + 46, 46), 130)

        return directions.compactMap { direction -> (CGPoint, CGFloat)? in
            let proposed = CGPoint(
                x: petFrame.origin.x + direction.dx * travel,
                y: petFrame.origin.y + direction.dy * travel
            )
            let origin = clampedOrigin(proposed, size: petFrame.size, bounds: bounds)
            let movedFrame = CGRect(origin: origin, size: petFrame.size)
            let alignment = direction.dx * away.dx + direction.dy * away.dy
            let score = distance(from: mouseLocation, to: movedFrame) + alignment * 2
            return (origin, score)
        }
        .max(by: { $0.1 < $1.1 })?
        .0
    }

    static func clampedOrigin(_ origin: CGPoint, size: CGSize, bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width)),
            y: min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        )
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
