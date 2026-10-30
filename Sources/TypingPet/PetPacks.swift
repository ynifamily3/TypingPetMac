import AppKit
import Foundation

enum PresetPlaybackMode: String, Codable, CaseIterable {
    case random, cycle
    var title: String { self == .random ? L("Random") : L("Sequential") }
}

enum PresetImageSource: String, Codable { case imageSet, keyReaction }

struct PetImagePreset: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var fileName: String
    var source: PresetImageSource = .imageSet

    static func builtInNameKey(fileName: String) -> String? {
        switch fileName {
        case "pet-idle.png": "Basic Expression"
        case "pet-left.png": "Left Hand"
        case "pet-right.png": "Right Hand"
        case "pet-question.png": "Curious"
        case "pet-exclamation.png": "Surprised"
        default: nil
        }
    }
}

struct PresetSelection: Codable, Equatable {
    var presetIDs: [String]
    var mode: PresetPlaybackMode = .random
}

struct PresetKeyMapping: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var stroke: KeyStroke
    var selection: PresetSelection
}

struct PetPackConfiguration: Codable, Equatable {
    var name: String
    var presets: [PetImagePreset]
    var unassigned: PresetSelection
    var idle: PresetSelection
    var mappings: [PresetKeyMapping] = []

    var isUsable: Bool { !presets.isEmpty && !idle.presetIDs.isEmpty && !unassigned.presetIDs.isEmpty }

    func selection(for stroke: KeyStroke?) -> PresetSelection {
        stroke.flatMap { key in mappings.first { $0.stroke == key }?.selection } ?? unassigned
    }

    func localizingBuiltInNames(language: String) -> Self {
        var result = self
        result.name = AppLocalization.string("Default Set", language: language)
        for index in result.presets.indices {
            let preset = result.presets[index]
            if preset.source == .imageSet, let key = PetImagePreset.builtInNameKey(fileName: preset.fileName) {
                result.presets[index].name = AppLocalization.string(key, language: language)
            }
        }
        return result
    }
}

enum PetPackError: LocalizedError {
    case invalidSelection, invalidPreset, invalidName, unreadableConfiguration, emptyPack, activePackNeedsImage, duplicateName, builtInPresetsReadOnly
    var errorDescription: String? {
        switch self {
        case .invalidSelection: L("Choose at least one preset for Unassigned and IDLE.")
        case .invalidPreset: L("A preset image is missing or cannot be read.")
        case .invalidName: L("Enter a name for the pack and each preset.")
        case .unreadableConfiguration: L("Could not read saved packs. The original file has been preserved.")
        case .emptyPack: L("Add an image before using this pack.")
        case .activePackNeedsImage: L("Use another pack before deleting the last image in the active pack.")
        case .duplicateName: L("A pack with this name already exists.")
        case .builtInPresetsReadOnly: L("Built-in presets are read-only. Create a pack to use your own images.")
        }
    }
}

/// Playback positions are independent for each mapped key, Unassigned, and IDLE.
struct PresetPlaybackCursor {
    private struct Position {
        var selection: PresetSelection
        var index = -1
        var previous: String?
    }
    private var positions: [String: Position] = [:]

    mutating func next(in selection: PresetSelection, channel: String, randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }) -> String? {
        guard !selection.presetIDs.isEmpty else { return nil }
        var position = positions[channel] ?? Position(selection: selection)
        if position.selection != selection { position = Position(selection: selection) }
        let chosen: String?
        switch selection.mode {
        case .cycle:
            position.index = (position.index + 1) % selection.presetIDs.count
            chosen = selection.presetIDs[position.index]
        case .random:
            chosen = ImagePicker(names: selection.presetIDs).next(excluding: position.previous, randomIndex: randomIndex)
        }
        position.previous = chosen
        positions[channel] = position
        return chosen
    }

    mutating func reaction(for stroke: KeyStroke?, in pack: PetPackConfiguration) -> String? {
        if let stroke, let rule = pack.mappings.first(where: { $0.stroke == stroke }) {
            return next(in: rule.selection, channel: "key:\(stroke.keyCode):\(stroke.modifiers.rawValue)")
        }
        return next(in: pack.unassigned, channel: "unassigned")
    }

    mutating func idle(in pack: PetPackConfiguration) -> String? { next(in: pack.idle, channel: "idle") }
}

@MainActor
final class PetPackStore {
    private struct Document: Codable {
        var version = 1
        var packs: [String: PetPackConfiguration]
    }
    private static let builtInKeyboardDefaultsAppliedKey = "builtInKeyboardDefaultsApplied-v1"
    let library: PetImageLibrary
    private let legacyKeys: KeyReactionStore
    private let fileManager: FileManager
    private let localization: AppLocalization
    private var configurations: [String: PetPackConfiguration] = [:]
    private(set) var loadError: Error?

    init(library: PetImageLibrary, keyStore: KeyReactionStore, fileManager: FileManager = .default, localization: AppLocalization = .shared) {
        self.library = library
        legacyKeys = keyStore
        self.fileManager = fileManager
        self.localization = localization
        let url = library.packConfigurationsURL
        if fileManager.fileExists(atPath: url.path) {
            do {
                let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
                guard document.version == 1 else { throw PetPackError.unreadableConfiguration }
                configurations = document.packs
            } catch { loadError = PetPackError.unreadableConfiguration }
        } else {
            // Preserve the old global key rules in every existing pack. New packs start clean.
            for set in library.imageSets { configurations[set.id.uuidString] = makeConfiguration(for: set, includeLegacyKeys: true) }
            do { try persist(configurations) } catch { loadError = error }
        }
    }

    func rawConfiguration(for set: PetImageSet) -> PetPackConfiguration {
        configurations[set.id.uuidString] ?? makeConfiguration(for: set, includeLegacyKeys: loadError != nil)
    }
    func configuration(for set: PetImageSet) -> PetPackConfiguration {
        displayConfiguration(rawConfiguration(for: set), for: set)
    }
    func displayConfiguration(_ pack: PetPackConfiguration, for set: PetImageSet) -> PetPackConfiguration {
        set.isBuiltIn ? pack.localizingBuiltInNames(language: localization.language) : pack
    }
    var activeConfiguration: PetPackConfiguration { configuration(for: library.activeSet) }

    func imageURL(for preset: PetImagePreset, in set: PetImageSet) -> URL? {
        switch preset.source {
        case .imageSet: library.presetImageURL(fileName: preset.fileName, in: set)
        case .keyReaction: legacyKeys.imageURL(fileName: preset.fileName)
        }
    }
    func imageURL(id: String, in pack: PetPackConfiguration, set: PetImageSet) -> URL? {
        pack.presets.first { $0.id == id }.flatMap { imageURL(for: $0, in: set) }
    }
    var idleURL: URL? {
        let set = library.activeSet
        let pack = rawConfiguration(for: set)
        return pack.idle.presetIDs.first.flatMap { imageURL(id: $0, in: pack, set: set) }
    }

    func save(_ pack: PetPackConfiguration, for set: PetImageSet) throws {
        let displayed = displayConfiguration(pack, for: set)
        if set.isBuiltIn {
            let namesAreUnchanged = pack.presets.allSatisfy { preset in
                guard preset.source == .imageSet, let key = PetImagePreset.builtInNameKey(fileName: preset.fileName) else {
                    return configuration(for: set).presets.first(where: { $0.id == preset.id })?.name == preset.name
                }
                return AppLanguageMode.supportedLanguages.contains { AppLocalization.string(key, language: $0) == preset.name }
            }
            guard namesAreUnchanged, displayed.presets == configuration(for: set).presets else {
                throw PetPackError.builtInPresetsReadOnly
            }
        }
        try persistConfiguration(displayed, for: set)
    }

    private func persistConfiguration(_ pack: PetPackConfiguration, for set: PetImageSet) throws {
        guard loadError == nil else { throw PetPackError.unreadableConfiguration }
        try validate(pack, in: set)
        var updated = configurations
        updated[set.id.uuidString] = pack
        try persist(updated)
        configurations = updated
    }

    func activate(_ set: PetImageSet) throws {
        let pack = configuration(for: set)
        guard pack.isUsable else { throw PetPackError.emptyPack }
        try validate(pack, in: set)
        try library.activateSet(id: set.id)
    }

    func applyBuiltInKeyboardDefaultsIfNeeded() {
        let defaults = AppEnvironment.defaults
        guard !defaults.bool(forKey: Self.builtInKeyboardDefaultsAppliedKey),
              loadError == nil,
              let builtIn = library.imageSets.first(where: \.isBuiltIn) else { return }
        let pack = applyingBuiltInKeyboardDefaults(to: configuration(for: builtIn))
        do {
            try save(pack, for: builtIn)
            defaults.set(true, forKey: Self.builtInKeyboardDefaultsAppliedKey)
        } catch {
            // Keep the migration eligible for the next launch if the saved pack cannot be updated.
        }
    }

    func createPack(name: String) throws -> PetImageSet {
        guard loadError == nil else { throw PetPackError.unreadableConfiguration }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PetPackError.invalidName }
        guard !library.imageSets.contains(where: { configuration(for: $0).name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw PetPackError.duplicateName }
        let set = try library.addEmptySet(name: name)
        do {
            try save(PetPackConfiguration(name: name, presets: [], unassigned: PresetSelection(presetIDs: []), idle: PresetSelection(presetIDs: [])), for: set)
            return set
        } catch {
            try? library.deleteSet(id: set.id)
            throw error
        }
    }

    /// Copy every image into the new set, including migrated key-reaction images.
    /// Selecting a copy never changes the active desktop pet.
    func duplicatePack(_ original: PetImageSet) throws -> PetImageSet {
        guard loadError == nil else { throw PetPackError.unreadableConfiguration }
        let source = configuration(for: original)
        let base = L("%1$@ Copy", source.name)
        var name = base
        var suffix = 2
        while library.imageSets.contains(where: { configuration(for: $0).name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        let copy = try createPack(name: name)
        do {
            var pack = source
            pack.name = name
            pack.presets = try source.presets.map { preset in
                guard let url = imageURL(for: preset, in: original) else { throw PetPackError.invalidPreset }
                var copied = preset
                copied.fileName = try library.importPresetImage(from: url, into: copy)
                copied.source = .imageSet
                return copied
            }
            pack.mappings = pack.mappings.map { mapping in
                var copied = mapping
                copied.id = UUID()
                return copied
            }
            try save(pack, for: copy)
            return copy
        } catch {
            try? library.deleteSet(id: copy.id)
            throw error
        }
    }

    func removingPreset(id: String, from pack: PetPackConfiguration, in set: PetImageSet, replacementID: String?) throws -> PetPackConfiguration {
        guard !set.isBuiltIn else { throw PetPackError.builtInPresetsReadOnly }
        var result = pack
        result.presets.removeAll { $0.id == id }
        if result.presets.isEmpty && set.id == library.activeSetID { throw PetPackError.activePackNeedsImage }
        let validReplacement = replacementID.flatMap { candidate in result.presets.contains { $0.id == candidate } ? candidate : nil }
        func remove(_ selection: PresetSelection, fallback: Bool) -> PresetSelection {
            var value = selection
            value.presetIDs.removeAll { $0 == id }
            if fallback && value.presetIDs.isEmpty, let validReplacement { value.presetIDs = [validReplacement] }
            return value
        }
        result.idle = remove(result.idle, fallback: true)
        result.unassigned = remove(result.unassigned, fallback: true)
        result.mappings = result.mappings.compactMap { mapping in
            var mapping = mapping
            mapping.selection = remove(mapping.selection, fallback: false)
            return mapping.selection.presetIDs.isEmpty ? nil : mapping
        }
        try validate(result, in: set)
        return result
    }

    func importPresets(_ urls: [URL], into set: PetImageSet) throws -> [PetImagePreset] {
        guard !set.isBuiltIn else { throw PetPackError.builtInPresetsReadOnly }
        return try urls.map { url in
            let fileName = try library.importPresetImage(from: url, into: set)
            return PetImagePreset(id: UUID().uuidString, name: url.deletingPathExtension().lastPathComponent, fileName: fileName)
        }
    }

    func replaceIdle(with url: URL) throws {
        let set = library.activeSet
        var pack = configuration(for: set)
        let imported = try importPresets([url], into: set)
        pack.presets.append(contentsOf: imported)
        pack.idle = PresetSelection(presetIDs: imported.map(\.id))
        try save(pack, for: set)
    }

    func replaceUnassigned(with urls: [URL]) throws {
        guard !urls.isEmpty else { throw PetPackError.invalidSelection }
        let set = library.activeSet
        var pack = configuration(for: set)
        let imported = try importPresets(urls, into: set)
        pack.presets.append(contentsOf: imported)
        pack.unassigned = PresetSelection(presetIDs: imported.map(\.id))
        try save(pack, for: set)
    }

    func resetToDefaults() throws {
        guard let builtIn = library.imageSets.first(where: { $0.id == PetImageLibrary.builtInID }) else { return }
        // This explicit reset restores bundled defaults; ordinary edits cannot change their images.
        try persistConfiguration(makeConfiguration(for: builtIn, includeLegacyKeys: false), for: builtIn)
        library.resetToDefaults()
    }

    private func validate(_ pack: PetPackConfiguration, in set: PetImageSet) throws {
        guard !pack.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pack.presets.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw PetPackError.invalidName }
        let ids = Set(pack.presets.map(\.id))
        if pack.presets.isEmpty {
            guard set.id != library.activeSetID else { throw PetPackError.activePackNeedsImage }
            guard pack.idle.presetIDs.isEmpty, pack.unassigned.presetIDs.isEmpty, pack.mappings.isEmpty else { throw PetPackError.invalidSelection }
            return
        }
        let selections = [pack.idle, pack.unassigned] + pack.mappings.map(\.selection)
        guard ids.count == pack.presets.count, !ids.isEmpty,
              selections.allSatisfy({ !$0.presetIDs.isEmpty && Set($0.presetIDs).count == $0.presetIDs.count && Set($0.presetIDs).isSubset(of: ids) }),
              Set(pack.mappings.map(\.stroke)).count == pack.mappings.count else { throw PetPackError.invalidSelection }
        for preset in pack.presets {
            guard let url = imageURL(for: preset, in: set), library.image(for: url) != nil else { throw PetPackError.invalidPreset }
        }
    }

    private func persist(_ packs: [String: PetPackConfiguration]) throws {
        let url = library.packConfigurationsURL
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(packs: packs)).write(to: url, options: .atomic)
    }

    private func makeConfiguration(for set: PetImageSet, includeLegacyKeys: Bool) -> PetPackConfiguration {
        if set.idleFileName.isEmpty && set.reactionFileNames.isEmpty {
            return PetPackConfiguration(name: set.name, presets: [], unassigned: PresetSelection(presetIDs: []), idle: PresetSelection(presetIDs: []))
        }
        let fileNames = [set.idleFileName] + set.reactionFileNames
        var seen = Set<String>()
        let presets = fileNames.filter { seen.insert($0).inserted }.map { fileName in
            PetImagePreset(id: fileName, name: Self.presetName(fileName), fileName: fileName)
        }
        var reactionNames = Set<String>()
        let reactions = set.reactionFileNames.filter { reactionNames.insert($0).inserted }
        var pack = PetPackConfiguration(name: set.name, presets: presets,
            unassigned: PresetSelection(presetIDs: reactions.isEmpty ? [set.idleFileName] : reactions),
            idle: PresetSelection(presetIDs: [set.idleFileName]))
        if includeLegacyKeys {
            for rule in legacyKeys.rules where legacyKeys.imageURL(for: rule) != nil {
                let id = "key-" + rule.id.uuidString
                pack.presets.append(PetImagePreset(id: id, name: rule.stroke.displayName, fileName: rule.imageFileName, source: .keyReaction))
                pack.mappings.append(PresetKeyMapping(stroke: rule.stroke, selection: PresetSelection(presetIDs: [id])))
            }
        }
        return pack
    }

    private func applyingBuiltInKeyboardDefaults(to original: PetPackConfiguration) -> PetPackConfiguration {
        var pack = original
        let idle = "pet-idle.png"
        let typingPresets = [idle, "pet-left.png", "pet-right.png"]
        let surprised = "pet-exclamation.png"
        guard typingPresets.allSatisfy({ id in pack.presets.contains(where: { $0.id == id }) }),
              pack.presets.contains(where: { $0.id == surprised }) else { return pack }

        pack.idle = PresetSelection(presetIDs: [idle], mode: .cycle)
        pack.unassigned = PresetSelection(presetIDs: typingPresets, mode: .cycle)

        let space = KeyStroke(keyCode: 49, modifiers: [])
        let enter = KeyStroke(keyCode: 36, modifiers: [])
        pack.mappings.removeAll()
        for stroke in [space, enter] {
            pack.mappings.append(PresetKeyMapping(
                stroke: stroke,
                selection: PresetSelection(presetIDs: [surprised], mode: .cycle)
            ))
        }
        return pack
    }

    private static func presetName(_ fileName: String) -> String {
        if let key = PetImagePreset.builtInNameKey(fileName: fileName) { return L(key) }
        let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        return base.count > 37 && UUID(uuidString: String(base.prefix(36))) != nil ? String(base.dropFirst(37)) : base
    }
}
