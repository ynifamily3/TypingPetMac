import AppKit
import XCTest
@testable import TypingPet

final class PetPackTests: XCTestCase {
    @MainActor
    func testBuiltInNamesFollowLanguageWithoutChangingMappingsOrStoredData() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let localization = AppLocalization(defaults: f.defaults)
        localization.setMode(.korean)
        let store = PetPackStore(library: f.library, keyStore: f.keys, localization: localization)
        let editor = PackEditorModel(store: store)
        let original = store.activeConfiguration
        let bytes = try Data(contentsOf: f.library.packConfigurationsURL)
        for mode in AppLanguageMode.allCases where mode != .system {
            localization.setMode(mode)
            let language = mode.resolvedLanguage()
            let displayed = editor.displayConfiguration
            XCTAssertEqual(displayed.name, AppLocalization.string("Default Set", language: language))
            XCTAssertEqual(displayed.mappings, original.mappings)
            XCTAssertEqual(displayed.presets.map(\.id), original.presets.map(\.id))
            for preset in displayed.presets {
                let key = try XCTUnwrap(PetImagePreset.builtInNameKey(fileName: preset.fileName))
                XCTAssertEqual(preset.name, AppLocalization.string(key, language: language))
            }
            XCTAssertEqual(try Data(contentsOf: f.library.packConfigurationsURL), bytes)
        }
        // A draft created in Korean can still save mapping changes after choosing another language.
        XCTAssertNoThrow(try store.save(original, for: f.library.activeSet))

        let custom = try store.createPack(name: "내 세트 그대로")
        editor.refresh()
        editor.selectSet(custom)
        localization.setMode(.english)
        XCTAssertEqual(editor.displayConfiguration.name, "내 세트 그대로")
    }

    @MainActor private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        let library: PetImageLibrary
        let keys: KeyReactionStore
        var image: URL {
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/TypingPet/Resources/pet-left.png")
        }
        var sampleImages: [URL] {
            ["pet-idle.png", "pet-left.png", "pet-right.png"].map { image.deletingLastPathComponent().appendingPathComponent($0) }
        }
        init() throws {
            suite = "TypingPetPacks.\(UUID())"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            library = PetImageLibrary(defaults: defaults, imagesDirectory: root.appendingPathComponent("Images"))
            keys = KeyReactionStore(defaults: defaults, directory: root.appendingPathComponent("Keys"))
        }
        func store() -> PetPackStore { PetPackStore(library: library, keyStore: keys) }
        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor func testMigratesExistingGlobalRulesWithoutMovingImagesAndNewPacksStartClean() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let imported = try f.library.addSet(from: [f.image], name: "Existing")
        let stroke = KeyStroke(keyCode: 0, modifiers: [.command, .shift])
        try f.keys.setRule(for: stroke, image: f.image)
        let oldURL = try XCTUnwrap(f.keys.imageURL(matching: stroke))
        let store = f.store()
        XCTAssertNil(store.loadError)
        for set in f.library.imageSets {
            let pack = store.configuration(for: set)
            XCTAssertEqual(pack.mappings.map(\.stroke), [stroke])
            let id = try XCTUnwrap(pack.mappings.first?.selection.presetIDs.first)
            XCTAssertEqual(store.imageURL(id: id, in: pack, set: set), oldURL)
        }
        XCTAssertEqual(store.configuration(for: imported).idle.presetIDs.count, 1)
        let new = try f.library.addSet(from: [f.image], name: "New")
        XCTAssertTrue(store.configuration(for: new).mappings.isEmpty)
        XCTAssertEqual(store.configuration(for: new).presets.count, 1, "A single imported image is shared by IDLE and Unassigned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
        try store.resetToDefaults()
        XCTAssertEqual(store.activeConfiguration.presets.count, 5, "Explicit reset can restore the bundled images after legacy migration")
        XCTAssertTrue(store.activeConfiguration.mappings.isEmpty)
    }

    @MainActor func testRoundTripKeepsPerPackSelectionsModesNamesAndModifierCombinations() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = f.store()
        let set = try f.library.addSet(from: f.sampleImages, name: "Editable")
        var pack = store.configuration(for: set)
        let ids = Array(pack.presets.prefix(3).map(\.id))
        pack.name = "자유로운 팩 이름"
        pack.presets[0].name = "자유로운 표정"
        pack.idle = PresetSelection(presetIDs: Array(ids.reversed()), mode: .cycle)
        pack.unassigned = PresetSelection(presetIDs: ids, mode: .random)
        pack.mappings = [PresetKeyMapping(stroke: KeyStroke(keyCode: 40, modifiers: [.control, .option, .shift, .command]), selection: PresetSelection(presetIDs: ids, mode: .cycle))]
        try store.save(pack, for: set)
        let second = try f.library.addSet(from: [f.image], name: "Separate")
        let restored = f.store()
        XCTAssertEqual(restored.configuration(for: set), pack)
        XCTAssertTrue(restored.configuration(for: second).mappings.isEmpty)
        XCTAssertNotEqual(restored.configuration(for: second).name, pack.name)
    }

    @MainActor func testInvalidSelectionsCannotOverwriteSavedPack() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = f.store()
        let set = f.library.activeSet
        let original = store.activeConfiguration
        let bytes = try Data(contentsOf: f.library.packConfigurationsURL)
        var invalid = original
        invalid.idle.presetIDs = []
        XCTAssertThrowsError(try store.save(invalid, for: set))
        invalid = original
        invalid.unassigned.presetIDs = ["missing"]
        XCTAssertThrowsError(try store.save(invalid, for: set))
        invalid = original
        let mapping = PresetKeyMapping(stroke: KeyStroke(keyCode: 0, modifiers: []), selection: original.idle)
        invalid.mappings = [mapping, mapping]
        XCTAssertThrowsError(try store.save(invalid, for: set))
        XCTAssertEqual(try Data(contentsOf: f.library.packConfigurationsURL), bytes)
        XCTAssertEqual(store.activeConfiguration, original)
    }

    @MainActor func testUnreadableAndFutureDocumentsArePreserved() throws {
        let f = try Fixture(); defer { f.cleanup() }
        _ = f.store()
        for text in ["broken document", "{\"version\":99,\"packs\":{}}"] {
            let bytes = Data(text.utf8)
            try bytes.write(to: f.library.packConfigurationsURL)
            let store = f.store()
            XCTAssertNotNil(store.loadError)
            XCTAssertThrowsError(try store.save(store.activeConfiguration, for: f.library.activeSet))
            XCTAssertEqual(try Data(contentsOf: f.library.packConfigurationsURL), bytes)
        }
    }

    @MainActor func testImportedPresetIsIndependentOfOriginalAndCanBeSavedInCustomPack() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = f.store()
        _ = try f.library.addSet(from: [f.image], name: "Editable")
        let source = f.root.appendingPathComponent("my-expression.png")
        try FileManager.default.copyItem(at: f.image, to: source)
        let preset = try XCTUnwrap(store.importPresets([source], into: f.library.activeSet).first)
        let copy = try XCTUnwrap(store.imageURL(for: preset, in: f.library.activeSet))
        XCTAssertNotEqual(source, copy)
        try FileManager.default.removeItem(at: source)
        XCTAssertNotNil(NSImage(contentsOf: copy))
        var pack = store.activeConfiguration
        pack.presets.append(preset)
        pack.idle.presetIDs = [preset.id]
        try store.save(pack, for: f.library.activeSet)
        XCTAssertEqual(f.store().idleURL, copy)
    }

    func testPlaybackUsesExactModifiersAndIndependentKeyFallbackAndIdleCycles() {
        var pack = samplePack()
        let plain = KeyStroke(keyCode: 0, modifiers: [])
        let combo = KeyStroke(keyCode: 0, modifiers: [.command, .shift])
        pack.mappings = [PresetKeyMapping(stroke: combo, selection: PresetSelection(presetIDs: ["c", "d"], mode: .cycle))]
        var cursor = PresetPlaybackCursor()
        XCTAssertEqual(cursor.reaction(for: combo, in: pack), "c")
        XCTAssertEqual(cursor.reaction(for: plain, in: pack), "a")
        XCTAssertEqual(cursor.idle(in: pack), "e")
        XCTAssertEqual(cursor.reaction(for: combo, in: pack), "d")
        XCTAssertEqual(cursor.reaction(for: KeyStroke(keyCode: 1, modifiers: []), in: pack), "b")
        XCTAssertEqual(cursor.idle(in: pack), "f")
        XCTAssertEqual(cursor.reaction(for: combo, in: pack), "c")
        pack.idle.presetIDs.reverse()
        XCTAssertEqual(cursor.idle(in: pack), "f", "Changing a selection starts its new cycle at the first image")
    }

    func testRandomPlaybackAvoidsImmediateRepeats() {
        var cursor = PresetPlaybackCursor()
        let selection = PresetSelection(presetIDs: ["a", "b", "c"])
        var previous: String?
        for _ in 0..<20 {
            let next = cursor.next(in: selection, channel: "random", randomIndex: { _ in 0 })
            XCTAssertNotNil(next)
            XCTAssertNotEqual(previous, next)
            previous = next
        }
    }

    @MainActor func testEditorAutosavesExactModifierMappingAndOpensOnlyOneTarget() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var reloads: [Bool] = []
        let editor = PackEditorModel(store: f.store(), onChange: { reloads.append($0) })
        let stroke = KeyStroke(keyCode: 0, modifiers: [.command, .option])
        editor.toggle(.unassigned)
        editor.toggle(.idle)
        XCTAssertEqual(editor.expandedTarget, .idle)
        editor.toggle(.idle)
        XCTAssertNil(editor.expandedTarget)
        let ids = editor.draft.presets.map(\.id)
        editor.assignPreset(ids[1], to: stroke)
        editor.togglePreset(ids[2], for: .key(stroke))
        editor.setMode(.cycle, for: .key(stroke))
        let saved = try XCTUnwrap(f.store().activeConfiguration.mappings.first)
        XCTAssertEqual(saved.stroke, stroke)
        XCTAssertEqual(saved.selection, PresetSelection(presetIDs: [ids[1], ids[2]], mode: .cycle))
        XCTAssertEqual(reloads, [true, true, true])
        editor.unassign(.key(stroke))
        XCTAssertTrue(f.store().activeConfiguration.mappings.isEmpty)
    }

    @MainActor func testEmptyPackCreationAndInactiveEditsNeverSwitchActivePet() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = f.store()
        let original = store.activeConfiguration
        let originalID = f.library.activeSetID
        var reloads: [Bool] = []
        let editor = PackEditorModel(store: store, onChange: { reloads.append($0) })
        try editor.createPack(name: "My empty pack")
        let set = editor.selectedSet
        XCTAssertTrue(editor.draft.presets.isEmpty)
        XCTAssertFalse(editor.draft.isUsable)
        XCTAssertEqual(f.library.activeSetID, originalID)
        XCTAssertThrowsError(try store.activate(set))
        XCTAssertThrowsError(try store.createPack(name: "  my EMPTY pack  "))
        editor.addPresets(from: [f.image])
        XCTAssertEqual(editor.draft.presets.count, 1)
        XCTAssertEqual(editor.draft.idle.presetIDs, editor.draft.unassigned.presetIDs)
        XCTAssertTrue(editor.draft.isUsable)
        XCTAssertEqual(store.activeConfiguration, original)
        XCTAssertEqual(reloads, [false, false])
        editor.activate(set)
        XCTAssertEqual(f.library.activeSetID, set.id)
        XCTAssertEqual(reloads.last, true)
        let restoredLibrary = PetImageLibrary(defaults: f.defaults, imagesDirectory: f.root.appendingPathComponent("Images"))
        let restored = PetPackStore(library: restoredLibrary, keyStore: f.keys)
        XCTAssertEqual(restoredLibrary.activeSetID, set.id)
        XCTAssertEqual(restored.activeConfiguration, editor.draft)
    }

    @MainActor func testDeletingPresetRequiresFallbackReplacementAndRemovesEmptyKeyMapping() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = f.store()
        let set = try f.library.addSet(from: f.sampleImages, name: "Editable")
        var pack = store.activeConfiguration
        let removed = pack.idle.presetIDs[0]
        let replacement = try XCTUnwrap(pack.presets.first { $0.id != removed }?.id)
        pack.unassigned.presetIDs = [removed]
        pack.mappings = [PresetKeyMapping(stroke: KeyStroke(keyCode: 0, modifiers: []), selection: PresetSelection(presetIDs: [removed]))]
        try store.save(pack, for: set)
        XCTAssertThrowsError(try store.removingPreset(id: removed, from: pack, in: set, replacementID: nil))
        let result = try store.removingPreset(id: removed, from: pack, in: set, replacementID: replacement)
        try store.save(result, for: set)
        XCTAssertEqual(result.idle.presetIDs, [replacement])
        XCTAssertEqual(result.unassigned.presetIDs, [replacement])
        XCTAssertTrue(result.mappings.isEmpty)
        XCTAssertFalse(result.presets.contains { $0.id == removed })
        XCTAssertNotNil(store.imageURL(id: removed, in: pack, set: set), "Deleting a preset retains the source image")
        XCTAssertEqual(f.store().activeConfiguration, result)
    }

    @MainActor func testBuiltInPresetsRejectChangesButAllowMappingAndPlaybackEdits() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = f.store()
        let set = f.library.activeSet
        let original = store.activeConfiguration
        let bytes = try Data(contentsOf: f.library.packConfigurationsURL)
        var renamed = original
        renamed.presets[0].name = "Changed"
        var replaced = original
        replaced.presets[0].fileName = original.presets[1].fileName
        var removed = original
        removed.presets.removeLast()
        var added = original
        var extra = original.presets[0]
        extra.id = UUID().uuidString
        added.presets.append(extra)
        for edited in [renamed, replaced, removed, added] {
            XCTAssertThrowsError(try store.save(edited, for: set)) { error in
                guard case PetPackError.builtInPresetsReadOnly = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        XCTAssertThrowsError(try store.importPresets([f.image], into: set))
        XCTAssertThrowsError(try store.removingPreset(id: original.presets[0].id, from: original, in: set, replacementID: nil))
        XCTAssertThrowsError(try store.replaceIdle(with: f.image))
        XCTAssertThrowsError(try store.replaceUnassigned(with: [f.image]))
        XCTAssertEqual(try Data(contentsOf: f.library.packConfigurationsURL), bytes)

        let editor = PackEditorModel(store: store)
        XCTAssertFalse(editor.canEditPresets)
        editor.renamePreset("Changed")
        editor.addPresets(from: [f.image])
        editor.replacePresetImage()
        editor.removeSelectedPreset()
        XCTAssertEqual(editor.draft, original)
        let stroke = KeyStroke(keyCode: 0, modifiers: [.command, .shift])
        editor.assignPreset(original.presets[1].id, to: stroke)
        editor.setMode(.cycle, for: .unassigned)
        editor.togglePreset(original.presets[1].id, for: .idle)
        let restored = f.store().activeConfiguration
        XCTAssertEqual(restored.presets, original.presets)
        XCTAssertEqual(restored.mappings.first?.stroke, stroke)
        XCTAssertEqual(restored.unassigned.mode, .cycle)
        XCTAssertEqual(restored.idle.presetIDs.count, 2)
        try editor.createPack(name: "My editable pack")
        XCTAssertTrue(editor.canEditPresets)
        editor.addPresets(from: [f.image])
        editor.renamePreset("My image")
        XCTAssertEqual(editor.draft.presets.first?.name, "My image")
    }

    @MainActor func testLastImageCanOnlyBeRemovedFromInactivePackAndOrderPersists() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = f.store()
        let editor = PackEditorModel(store: store)
        try editor.createPack(name: "One image")
        editor.addPresets(from: [f.image])
        let set = editor.selectedSet
        let pack = editor.draft
        let id = try XCTUnwrap(pack.presets.first?.id)
        let empty = try store.removingPreset(id: id, from: pack, in: set, replacementID: nil)
        XCTAssertTrue(empty.presets.isEmpty)
        editor.activate(set)
        XCTAssertThrowsError(try store.removingPreset(id: id, from: pack, in: set, replacementID: nil))
        editor.moveSet(id: set.id, before: PetImageLibrary.builtInID)
        let library = PetImageLibrary(defaults: f.defaults, imagesDirectory: f.root.appendingPathComponent("Images"))
        XCTAssertEqual(library.imageSets.first?.id, set.id)
        try store.activate(try XCTUnwrap(library.imageSets.first { $0.isBuiltIn }))
        try store.save(empty, for: set)
        XCTAssertTrue(f.store().configuration(for: set).presets.isEmpty)
    }

    @MainActor func testDuplicateCopiesImagesAndMappingsWithoutActivatingOrSharingEdits() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = f.store()
        let basic = f.library.activeSet
        var original = store.configuration(for: basic)
        original.idle.mode = .cycle
        original.mappings = [PresetKeyMapping(stroke: KeyStroke(keyCode: 49, modifiers: [.command, .shift]), selection: original.unassigned)]
        try store.save(original, for: basic)
        let copy = try store.duplicatePack(basic)
        var copied = store.configuration(for: copy)
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertEqual(f.library.activeSetID, basic.id)
        XCTAssertEqual(copied.idle, original.idle)
        XCTAssertEqual(copied.unassigned, original.unassigned)
        XCTAssertEqual(copied.mappings.first?.stroke, original.mappings.first?.stroke)
        XCTAssertNotEqual(copied.mappings.first?.id, original.mappings.first?.id)
        for (source, destination) in zip(original.presets, copied.presets) {
            let sourceURL = try XCTUnwrap(store.imageURL(for: source, in: basic))
            let copiedURL = try XCTUnwrap(store.imageURL(for: destination, in: copy))
            XCTAssertNotEqual(sourceURL, copiedURL)
            XCTAssertEqual(try Data(contentsOf: sourceURL), try Data(contentsOf: copiedURL))
            XCTAssertEqual(source.id, destination.id)
        }
        copied.presets[0].name = "Only in the copy"
        try store.save(copied, for: copy)
        XCTAssertEqual(store.configuration(for: basic), original)
        XCTAssertEqual(f.store().configuration(for: copy), copied)
        let second = try store.duplicatePack(basic)
        XCTAssertNotEqual(store.configuration(for: second).name, copied.name)
        XCTAssertEqual(f.library.activeSetID, basic.id)
    }

    @MainActor func testDuplicatePreservesMigratedKeyImagesAndSupportsEmptySets() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.keys.setRule(for: KeyStroke(keyCode: 36, modifiers: [.option]), image: f.image)
        let store = f.store()
        let source = store.activeConfiguration
        let copy = try store.duplicatePack(f.library.activeSet)
        let pack = store.configuration(for: copy)
        XCTAssertTrue(pack.presets.allSatisfy { $0.source == .imageSet })
        XCTAssertEqual(pack.mappings.map(\.selection), source.mappings.map(\.selection))
        for p in pack.presets { XCTAssertNotNil(store.imageURL(for: p, in: copy)) }
        let empty = try store.createPack(name: "Empty")
        let emptyCopy = try store.duplicatePack(empty)
        XCTAssertTrue(store.configuration(for: emptyCopy).presets.isEmpty)
        XCTAssertFalse(store.configuration(for: emptyCopy).isUsable)
    }

    @MainActor func testPackEditorAndLibraryShareImageCacheAndInvalidateOnDeletion() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let store = f.store()
        let editor = PackEditorModel(store: store)
        let preset = try XCTUnwrap(editor.draft.presets.first)
        let url = try XCTUnwrap(store.imageURL(for: preset, in: editor.selectedSet))

        let editorImage = try XCTUnwrap(editor.image(for: preset))
        let libraryImage = try XCTUnwrap(f.library.image(for: url))
        XCTAssertTrue(editorImage === libraryImage)

        f.library.clearCache()
        let reloadedImage = try XCTUnwrap(editor.image(for: preset))
        XCTAssertFalse(reloadedImage === editorImage)
    }

    private func samplePack() -> PetPackConfiguration {
        PetPackConfiguration(name: "Test", presets: [],
            unassigned: PresetSelection(presetIDs: ["a", "b"], mode: .cycle),
            idle: PresetSelection(presetIDs: ["e", "f"], mode: .cycle))
    }
}
