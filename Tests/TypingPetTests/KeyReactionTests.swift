import CoreGraphics
import XCTest
@testable import TypingPet

final class KeyReactionTests: XCTestCase {
    func testNormalizesOnlySupportedModifierFlags() {
        let modifiers = KeyModifiers(eventFlags: [.maskCommand, .maskShift, .maskAlphaShift])
        XCTAssertEqual(modifiers, [.command, .shift])
        XCTAssertEqual(modifiers.displayPrefix, "⇧⌘")
    }

    func testSameKeyWithDifferentModifiersIsDifferentStroke() {
        let plain = KeyStroke(keyCode: 40, modifiers: [])
        let command = KeyStroke(keyCode: 40, modifiers: [.command])
        XCTAssertNotEqual(plain, command)
        XCTAssertEqual(command.displayName, "⌘K")
    }

    @MainActor
    func testRulePersistsAndMatchesExactly() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("TypingPetKeys-\(UUID())", isDirectory: true)
        let stored = root.appendingPathComponent("Rules", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let image = packageRoot.appendingPathComponent("Sources/TypingPet/Resources/pet-left.png")
        let suite = "TypingPetKeyTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let stroke = KeyStroke(keyCode: 40, modifiers: [.command])
        let store = KeyReactionStore(fileManager: fileManager, defaults: defaults, directory: stored)
        try store.setRule(for: stroke, image: image)
        XCTAssertNotNil(store.imageURL(matching: stroke))
        XCTAssertNil(store.imageURL(matching: KeyStroke(keyCode: 40, modifiers: [])))

        let restored = KeyReactionStore(fileManager: fileManager, defaults: defaults, directory: stored)
        XCTAssertEqual(restored.rules.count, 1)
        XCTAssertNotNil(restored.imageURL(matching: stroke))
    }
}
