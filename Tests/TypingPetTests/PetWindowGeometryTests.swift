import XCTest
@testable import TypingPet

final class PetWindowGeometryTests: XCTestCase {
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
