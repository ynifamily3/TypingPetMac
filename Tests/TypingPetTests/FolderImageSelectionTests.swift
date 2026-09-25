import XCTest
@testable import TypingPet

final class FolderImageSelectionTests: XCTestCase {
    func testRecognizesPetIdleAndSortsReactionImages() {
        let urls = [
            URL(fileURLWithPath: "/set/z-last.webp"),
            URL(fileURLWithPath: "/set/pet-idle.png"),
            URL(fileURLWithPath: "/set/a-first.gif"),
            URL(fileURLWithPath: "/set/readme.txt")
        ]

        let selection = FolderImageSelection.make(from: urls)

        XCTAssertEqual(selection.idleURL?.lastPathComponent, "pet-idle.png")
        XCTAssertEqual(
            selection.reactionURLs.map(\.lastPathComponent),
            ["a-first.gif", "z-last.webp"]
        )
    }

    func testKeepsAllImagesAsReactionsWhenIdleIsMissing() {
        let urls = [
            URL(fileURLWithPath: "/set/left.png"),
            URL(fileURLWithPath: "/set/right.jpg")
        ]

        let selection = FolderImageSelection.make(from: urls)

        XCTAssertNil(selection.idleURL)
        XCTAssertEqual(selection.reactionURLs.count, 2)
    }

    func testIdleNameIsCaseInsensitive() {
        let selection = FolderImageSelection.make(from: [
            URL(fileURLWithPath: "/set/IDLE.HEIC")
        ])

        XCTAssertEqual(selection.idleURL?.lastPathComponent, "IDLE.HEIC")
        XCTAssertTrue(selection.reactionURLs.isEmpty)
    }

    @MainActor
    func testLibraryCopiesSelectedImagesAndPersistsTheSelection() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("TypingPetTests-\(UUID().uuidString)", isDirectory: true)
        let inputDirectory = temporaryRoot.appendingPathComponent("Input", isDirectory: true)
        let storedDirectory = temporaryRoot.appendingPathComponent("Stored", isDirectory: true)
        try fileManager.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceImage = packageRoot
            .appendingPathComponent("Sources/TypingPet/Resources/pet-idle.png")
        let selectedImage = inputDirectory.appendingPathComponent("my-idle.png")
        try fileManager.copyItem(at: sourceImage, to: selectedImage)

        let suiteName = "TypingPetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let library = PetImageLibrary(
            fileManager: fileManager,
            defaults: defaults,
            imagesDirectory: storedDirectory
        )
        try library.replaceIdle(with: selectedImage)

        let copiedURL = try XCTUnwrap(library.idleURL)
        XCTAssertTrue(copiedURL.path.hasPrefix(storedDirectory.appendingPathComponent("Sets").path))
        XCTAssertTrue(fileManager.fileExists(atPath: copiedURL.path))
        XCTAssertTrue(library.usesCustomImages)

        let restored = PetImageLibrary(
            fileManager: fileManager,
            defaults: defaults,
            imagesDirectory: storedDirectory
        )
        XCTAssertEqual(restored.activeSetID, library.activeSetID)
        XCTAssertEqual(restored.imageSets.count, 2)
        XCTAssertEqual(restored.idleURL?.path, copiedURL.path)
    }

    @MainActor
    func testFolderImportCreatesSelectableGallerySet() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("TypingPetGallery-\(UUID())", isDirectory: true)
        let input = root.appendingPathComponent("Happy Cat", isDirectory: true)
        let stored = root.appendingPathComponent("Stored", isDirectory: true)
        try fileManager.createDirectory(at: input, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = packageRoot.appendingPathComponent("Sources/TypingPet/Resources", isDirectory: true)
        try fileManager.copyItem(at: resources.appendingPathComponent("pet-idle.png"), to: input.appendingPathComponent("idle.png"))
        try fileManager.copyItem(at: resources.appendingPathComponent("pet-left.png"), to: input.appendingPathComponent("wave.png"))

        let suite = "TypingPetGalleryTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = PetImageLibrary(fileManager: fileManager, defaults: defaults, imagesDirectory: stored)
        let imported = try library.addSet(from: input)

        XCTAssertEqual(imported.name, "Happy Cat")
        XCTAssertEqual(library.imageSets.count, 2)
        XCTAssertEqual(library.activeSetID, imported.id)
        XCTAssertEqual(library.reactionURLs.count, 1)
        try library.activateSet(id: PetImageLibrary.builtInID)
        XCTAssertEqual(library.activeSetID, PetImageLibrary.builtInID)
    }

    @MainActor
    func testMigratesLegacyImageSelectionIntoGallery() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("TypingPetMigration-\(UUID())", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resource = packageRoot.appendingPathComponent("Sources/TypingPet/Resources/pet-idle.png")
        let legacyImage = root.appendingPathComponent("legacy.png")
        try fileManager.copyItem(at: resource, to: legacyImage)

        let suite = "TypingPetMigrationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy.png", forKey: "customIdleImageFile")
        defaults.set(["legacy.png"], forKey: "customReactionImageFiles")

        let library = PetImageLibrary(fileManager: fileManager, defaults: defaults, imagesDirectory: root)
        XCTAssertEqual(library.imageSets.count, 2)
        XCTAssertEqual(library.activeSet.name, "기존 사용자 세트")
        XCTAssertEqual(library.idleURL?.path, legacyImage.path)

        try library.replaceIdle(with: resource)
        XCTAssertTrue(library.idleURL?.path.contains("/Sets/") == true)
    }
}
