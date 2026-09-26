import XCTest
@testable import TypingPet

final class PetWindowGeometryTests: XCTestCase {
    func testInputMonitoringGuideConvertsQuartzWindowCoordinates() {
        let frame = InputMonitoringGuidePlacement.appKitFrame(
            fromQuartzFrame: CGRect(x: 120, y: 180, width: 740, height: 522),
            primaryScreenMaxY: 1_440
        )

        XCTAssertEqual(frame, CGRect(x: 120, y: 738, width: 740, height: 522))
    }

    func testInputMonitoringGuidePrefersRightSideOfSettingsWindow() {
        let origin = InputMonitoringGuidePlacement.origin(
            panelSize: CGSize(width: 404, height: 336),
            beside: CGRect(x: 400, y: 300, width: 740, height: 522),
            in: CGRect(x: 0, y: 40, width: 1_800, height: 1_060)
        )

        XCTAssertEqual(origin, CGPoint(x: 1_152, y: 486))
    }

    func testInputMonitoringGuideUsesLeftSideWhenRightSideIsTooNarrow() {
        let origin = InputMonitoringGuidePlacement.origin(
            panelSize: CGSize(width: 404, height: 336),
            beside: CGRect(x: 1_458, y: 766, width: 740, height: 522),
            in: CGRect(x: 0, y: 87, width: 2_560, height: 1_323)
        )

        XCTAssertEqual(origin, CGPoint(x: 1_042, y: 952))
    }

    func testInputMonitoringGuideStaysInsideVisibleFrameWhenBothSidesAreNarrow() {
        let origin = InputMonitoringGuidePlacement.origin(
            panelSize: CGSize(width: 404, height: 336),
            beside: CGRect(x: 260, y: 220, width: 920, height: 650),
            in: CGRect(x: 0, y: 40, width: 1_440, height: 860)
        )

        XCTAssertEqual(origin, CGPoint(x: 1_024, y: 534))
    }

    func testDetectsApplicationsFolderLocationsForPermissionGuide() {
        XCTAssertEqual(
            TypingPetAppLocation.detect(
                appURL: URL(fileURLWithPath: "/Applications/TypingPet.app"),
                homeDirectory: URL(fileURLWithPath: "/Users/test")
            ),
            .applications
        )
        XCTAssertEqual(
            TypingPetAppLocation.detect(
                appURL: URL(fileURLWithPath: "/Users/test/Applications/TypingPet.app"),
                homeDirectory: URL(fileURLWithPath: "/Users/test")
            ),
            .applications
        )
    }

    func testDetectsUnsafePermissionGuideLocations() {
        XCTAssertEqual(
            TypingPetAppLocation.detect(
                appURL: URL(fileURLWithPath: "/Users/test/Downloads/TypingPet.app"),
                homeDirectory: URL(fileURLWithPath: "/Users/test")
            ),
            .outsideApplications
        )
        XCTAssertEqual(
            TypingPetAppLocation.detect(
                appURL: URL(fileURLWithPath: "/private/var/folders/AppTranslocation/TypingPet.app"),
                homeDirectory: URL(fileURLWithPath: "/Users/test")
            ),
            .translocated
        )
    }

    func testPointerAvoidanceMovesAwayFromNearbyPointer() {
        let frame = CGRect(x: 100, y: 100, width: 100, height: 100)
        let mouse = CGPoint(x: 80, y: 150)
        let target = PetPointerAvoidance.targetOrigin(
            mouseLocation: mouse,
            petFrame: frame,
            bounds: CGRect(x: 0, y: 0, width: 500, height: 500)
        )

        XCTAssertNotNil(target)
        XCTAssertGreaterThan(target!.x, frame.origin.x)
        XCTAssertGreaterThan(
            PetPointerAvoidance.distance(from: mouse, to: CGRect(origin: target!, size: frame.size)),
            PetPointerAvoidance.distance(from: mouse, to: frame)
        )
    }

    func testPointerAvoidanceCanChooseDiagonalEscapeForHorizontalApproach() {
        let frame = CGRect(x: 180, y: 180, width: 100, height: 100)
        let target = PetPointerAvoidance.targetOrigin(
            mouseLocation: CGPoint(x: 160, y: 230),
            petFrame: frame,
            bounds: CGRect(x: 0, y: 0, width: 500, height: 500)
        )

        XCTAssertNotNil(target)
        XCTAssertGreaterThan(target!.x, frame.origin.x)
        XCTAssertNotEqual(target!.y, frame.origin.y, accuracy: 0.001)
    }

    func testPointerAvoidanceDoesNothingWhenPointerIsFarAway() {
        XCTAssertNil(PetPointerAvoidance.targetOrigin(
            mouseLocation: CGPoint(x: 0, y: 0),
            petFrame: CGRect(x: 300, y: 300, width: 100, height: 100),
            bounds: CGRect(x: 0, y: 0, width: 500, height: 500)
        ))
    }

    func testPointerAvoidanceChoosesAnAvailableDirectionAtScreenEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 500)
        let frame = CGRect(x: 0, y: 180, width: 100, height: 100)
        let target = PetPointerAvoidance.targetOrigin(
            mouseLocation: CGPoint(x: 60, y: 230),
            petFrame: frame,
            bounds: bounds
        )

        XCTAssertNotNil(target)
        XCTAssertNotEqual(target!, frame.origin)
        XCTAssertGreaterThanOrEqual(target!.x, bounds.minX)
        XCTAssertGreaterThanOrEqual(target!.y, bounds.minY)
        XCTAssertLessThanOrEqual(target!.x + frame.width, bounds.maxX)
        XCTAssertLessThanOrEqual(target!.y + frame.height, bounds.maxY)
    }

    func testOpacitySelectsRestingAndHoverValuesImmediately() {
        XCTAssertEqual(
            PetOpacityBehavior.opacity(
                isHovering: false,
                restingOpacity: 1,
                hoverOpacity: 0.3
            ),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PetOpacityBehavior.opacity(
                isHovering: true,
                restingOpacity: 1,
                hoverOpacity: 0.3
            ),
            0.3,
            accuracy: 0.0001
        )
    }

    func testOpacityValuesAreClampedToValidRange() {
        XCTAssertEqual(
            PetOpacityBehavior.opacity(
                isHovering: false,
                restingOpacity: 1.4,
                hoverOpacity: 0.3
            ),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PetOpacityBehavior.opacity(
                isHovering: true,
                restingOpacity: 1,
                hoverOpacity: -0.2
            ),
            0,
            accuracy: 0.0001
        )
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
