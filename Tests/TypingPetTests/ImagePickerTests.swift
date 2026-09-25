import XCTest
@testable import TypingPet

final class ImagePickerTests: XCTestCase {
    func testPickerExcludesCurrentImage() {
        let picker = ImagePicker(names: ["left", "right", "question"])
        let result = picker.next(excluding: "left") { _ in 0 }
        XCTAssertEqual(result, "right")
    }

    func testPickerReturnsOnlyImageWhenNoAlternativeExists() {
        let picker = ImagePicker(names: ["left"])
        let result = picker.next(excluding: "left") { _ in 0 }
        XCTAssertEqual(result, "left")
    }

    func testEmptyPickerReturnsNil() {
        let picker = ImagePicker(names: [])
        XCTAssertNil(picker.next(excluding: nil) { _ in 0 })
    }
}
