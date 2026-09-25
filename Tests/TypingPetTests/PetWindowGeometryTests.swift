import XCTest
@testable import TypingPet

final class PetWindowGeometryTests: XCTestCase {
    func testProximityOpacityFadesSmoothlyTowardPet() {
        let frame = CGRect(x: 100, y: 100, width: 200, height: 100)

        XCTAssertEqual(
            PetProximityOpacity.opacity(
                mouseLocation: CGPoint(x: 200, y: 150),
                petFrame: frame
            ),
            0.3,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PetProximityOpacity.opacity(
                mouseLocation: CGPoint(x: 440, y: 150),
                petFrame: frame
            ),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PetProximityOpacity.opacity(
                mouseLocation: CGPoint(x: 370, y: 150),
                petFrame: frame
            ),
            0.65,
            accuracy: 0.0001
        )
    }

    func testProximityDistanceUsesNearestCorner() {
        let distance = PetProximityOpacity.distance(
            from: CGPoint(x: 30, y: 40),
            to: CGRect(x: 0, y: 0, width: 10, height: 10)
        )
        XCTAssertEqual(distance, hypot(20, 30), accuracy: 0.0001)
    }

    func testReleaseVelocityUsesRecentPointerMovement() {
        let velocity = PetMotionPhysics.releaseVelocity(samples: [
            PetDragSample(point: CGPoint(x: 0, y: 0), timestamp: 1.0),
            PetDragSample(point: CGPoint(x: 10, y: 5), timestamp: 1.1),
            PetDragSample(point: CGPoint(x: 40, y: 20), timestamp: 1.2),
        ])

        XCTAssertEqual(velocity.dx, 300, accuracy: 0.001)
        XCTAssertEqual(velocity.dy, 150, accuracy: 0.001)
    }

    func testReleaseVelocityIsCapped() {
        let velocity = PetMotionPhysics.releaseVelocity(samples: [
            PetDragSample(point: .zero, timestamp: 1),
            PetDragSample(point: CGPoint(x: 1_000, y: 0), timestamp: 1.01),
        ])

        XCTAssertEqual(hypot(velocity.dx, velocity.dy), 900, accuracy: 0.001)
    }

    func testMotionDecaysAndStaysInsideVisibleBounds() {
        let freeStep = PetMotionPhysics.advance(
            origin: CGPoint(x: 100, y: 100),
            size: CGSize(width: 100, height: 100),
            velocity: CGVector(dx: 600, dy: 300),
            elapsed: 0.1,
            bounds: CGRect(x: 0, y: 0, width: 500, height: 500)
        )
        XCTAssertEqual(freeStep.origin.x, 160, accuracy: 0.001)
        XCTAssertEqual(freeStep.origin.y, 130, accuracy: 0.001)
        XCTAssertLessThan(freeStep.velocity.dx, 600)

        let edgeStep = PetMotionPhysics.advance(
            origin: CGPoint(x: 390, y: 100),
            size: CGSize(width: 100, height: 100),
            velocity: CGVector(dx: 600, dy: 0),
            elapsed: 0.1,
            bounds: CGRect(x: 0, y: 0, width: 500, height: 500)
        )
        XCTAssertEqual(edgeStep.origin.x, 400, accuracy: 0.001)
        XCTAssertLessThan(edgeStep.velocity.dx, 0)
    }

    func testHorizontalResizeUsesWidthAndPreservesScaleRelationship() {
        let scale = PetResizeGeometry.scale(
            initialScale: 0.5,
            initialSize: CGSize(width: 200, height: 100),
            dragDelta: CGPoint(x: 100, y: 0)
        )
        XCTAssertEqual(scale, 0.75, accuracy: 0.0001)
    }

    func testVerticalResizeUsesHeight() {
        let scale = PetResizeGeometry.scale(
            initialScale: 0.5,
            initialSize: CGSize(width: 200, height: 100),
            dragDelta: CGPoint(x: 0, y: 50)
        )
        XCTAssertEqual(scale, 0.75, accuracy: 0.0001)
    }

    func testResizeClampsToSupportedRange() {
        XCTAssertEqual(
            PetResizeGeometry.scale(
                initialScale: 0.5,
                initialSize: CGSize(width: 200, height: 100),
                dragDelta: CGPoint(x: -500, y: 0)
            ),
            0.35
        )
        XCTAssertEqual(
            PetResizeGeometry.scale(
                initialScale: 1,
                initialSize: CGSize(width: 200, height: 100),
                dragDelta: CGPoint(x: 500, y: 0)
            ),
            1.25
        )
    }
}
