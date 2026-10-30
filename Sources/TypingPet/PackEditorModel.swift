import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum PackEditorTarget: Hashable {
    case key(KeyStroke), unassigned, idle
    var title: String {
        switch self {
        case .key(let stroke):
            stroke.modifiers.displayPrefix + (stroke.keyCode == 49 ? L("Space") : stroke.keyCode == 36 ? L("Enter") : KeyCodeNames.name(for: stroke.keyCode))
        case .unassigned: L("Unassigned")
        case .idle: L("When Resting")
        }
    }
}

@MainActor
final class PackEditorModel: ObservableObject {
    let store: PetPackStore
    @Published private(set) var sets: [PetImageSet]
    @Published private(set) var selectedSetID: UUID
    @Published private(set) var activeSetID: UUID
    @Published private(set) var draft: PetPackConfiguration
    @Published var selectedPresetID: String
    @Published var modifiers: KeyModifiers = []
    @Published var expandedTarget: PackEditorTarget?
    @Published var errorMessage: String?
    @Published private(set) var statusMessage = ""
    private let onChange: (Bool) -> Void
    var onSelectionChanged: ((UUID) -> Void)?

    init(store: PetPackStore, onChange: @escaping (Bool) -> Void = { _ in }) {
        self.store = store
        self.onChange = onChange
        sets = store.library.imageSets
        selectedSetID = store.library.activeSetID
        activeSetID = store.library.activeSetID
        let initialPack = store.activeConfiguration
        draft = initialPack
        selectedPresetID = initialPack.presets.first?.id ?? ""
        errorMessage = store.loadError?.localizedDescription
    }

    var selectedSet: PetImageSet { sets.first { $0.id == selectedSetID } ?? store.library.activeSet }
    var isActive: Bool { selectedSetID == activeSetID }
    var canEdit: Bool { store.loadError == nil }
    var canEditPresets: Bool { canEdit && !selectedSet.isBuiltIn }
    var selectedPreset: PetImagePreset? { draft.presets.first { $0.id == selectedPresetID } }
    var displayConfiguration: PetPackConfiguration { store.displayConfiguration(draft, for: selectedSet) }

    func refresh() {
        sets = store.library.imageSets
        activeSetID = store.library.activeSetID
        if !sets.contains(where: { $0.id == selectedSetID }) { selectedSetID = activeSetID }
        draft = store.configuration(for: selectedSet)
        if selectedPreset == nil { selectedPresetID = draft.presets.first?.id ?? "" }
    }

    func selectSet(_ set: PetImageSet) {
        guard selectedSetID != set.id else { return }
        selectedSetID = set.id
        draft = store.configuration(for: set)
        selectedPresetID = draft.presets.first?.id ?? ""
        expandedTarget = nil
        statusMessage = ""
        onSelectionChanged?(set.id)
    }

    func configuration(for set: PetImageSet) -> PetPackConfiguration {
        set.id == selectedSetID ? displayConfiguration : store.configuration(for: set)
    }

    func image(for preset: PetImagePreset, in set: PetImageSet? = nil) -> NSImage? {
        store.imageURL(for: preset, in: set ?? selectedSet).flatMap { store.library.image(for: $0) }
    }
    func image(id: String?) -> NSImage? {
        id.flatMap { value in draft.presets.first { $0.id == value } }.flatMap { image(for: $0) }
    }
    func cover(for set: PetImageSet) -> NSImage? {
        let pack = set.id == selectedSetID ? draft : store.rawConfiguration(for: set)
        return pack.presets.first(where: { $0.id == pack.idle.presetIDs.first }).flatMap { image(for: $0, in: set) }
    }
    func name(id: String) -> String { displayConfiguration.presets.first { $0.id == id }?.name ?? "" }

    func selection(for target: PackEditorTarget) -> PresetSelection {
        switch target {
        case .unassigned: draft.unassigned
        case .idle: draft.idle
        case .key(let stroke): draft.mappings.first { $0.stroke == stroke }?.selection ?? PresetSelection(presetIDs: [])
        }
    }

    @discardableResult
    private func commit(_ pack: PetPackConfiguration) -> Bool {
        do {
            try store.save(pack, for: selectedSet)
            draft = pack
            statusMessage = L("Changes saved automatically.")
            onChange(isActive)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func update(_ selection: PresetSelection, for target: PackEditorTarget) {
        var next = draft
        switch target {
        case .unassigned: next.unassigned = selection
        case .idle: next.idle = selection
        case .key(let stroke):
            if let index = next.mappings.firstIndex(where: { $0.stroke == stroke }) {
                if selection.presetIDs.isEmpty { next.mappings.remove(at: index) }
                else { next.mappings[index].selection = selection }
            } else if !selection.presetIDs.isEmpty {
                next.mappings.append(PresetKeyMapping(stroke: stroke, selection: selection))
            }
        }
        commit(next)
    }

    func toggle(_ target: PackEditorTarget) { expandedTarget = expandedTarget == target ? nil : target }
    func toggleModifier(_ modifier: KeyModifiers) {
        if modifiers.contains(modifier) { modifiers.remove(modifier) } else { modifiers.insert(modifier) }
        if case .key(let old) = expandedTarget { expandedTarget = .key(KeyStroke(keyCode: old.keyCode, modifiers: modifiers)) }
    }
    func togglePreset(_ id: String, for target: PackEditorTarget) {
        var value = selection(for: target)
        if value.presetIDs.contains(id) {
            if value.presetIDs.count == 1, target == .idle || target == .unassigned {
                statusMessage = L("Choose at least one preset.")
                return
            }
            value.presetIDs.removeAll { $0 == id }
        } else { value.presetIDs.append(id) }
        update(value, for: target)
    }
    func setMode(_ mode: PresetPlaybackMode, for target: PackEditorTarget) {
        var value = selection(for: target)
        value.mode = mode
        update(value, for: target)
    }
    func movePreset(_ id: String, by offset: Int, for target: PackEditorTarget) {
        var value = selection(for: target)
        guard let index = value.presetIDs.firstIndex(of: id), value.presetIDs.indices.contains(index + offset) else { return }
        value.presetIDs.swapAt(index, index + offset)
        update(value, for: target)
    }
    func unassign(_ target: PackEditorTarget) { if case .key = target { update(PresetSelection(presetIDs: []), for: target) } }
    func assignPreset(_ id: String, to stroke: KeyStroke) {
        guard draft.presets.contains(where: { $0.id == id }) else { return }
        update(PresetSelection(presetIDs: [id]), for: .key(stroke))
        expandedTarget = .key(stroke)
    }
    func renamePreset(_ value: String) {
        guard canEditPresets, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let index = draft.presets.firstIndex(where: { $0.id == selectedPresetID }), value != draft.presets[index].name else { return }
        var next = draft
        next.presets[index].name = value
        commit(next)
    }

    func createPack(name: String) throws {
        let set = try store.createPack(name: name)
        sets = store.library.imageSets
        selectSet(set)
        onChange(false)
    }
    func duplicatePack() throws {
        let set = try store.duplicatePack(selectedSet)
        sets = store.library.imageSets
        selectSet(set)
        onChange(false)
    }
    func activate(_ set: PetImageSet) {
        do {
            try store.activate(set)
            activeSetID = set.id
            statusMessage = L("Using %1$@", configuration(for: set).name)
            onChange(true)
        } catch { errorMessage = error.localizedDescription }
    }
    func moveSet(id: UUID, before target: UUID) {
        store.library.moveSet(id: id, before: target)
        sets = store.library.imageSets
        onChange(false)
    }

    func addPresets() {
        guard canEditPresets else { return }
        let panel = NSOpenPanel()
        panel.title = L("Add Preset Images")
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addPresets(from: panel.urls)
    }
    func addPresets(from urls: [URL]) {
        guard canEditPresets else { return }
        do {
            let imported = try store.importPresets(urls, into: selectedSet)
            guard !imported.isEmpty else { return }
            var next = draft
            if next.presets.isEmpty {
                next.idle.presetIDs = [imported[0].id]
                next.unassigned.presetIDs = [imported[0].id]
            }
            next.presets.append(contentsOf: imported)
            if commit(next) { selectedPresetID = imported[0].id }
        } catch { errorMessage = error.localizedDescription }
    }
    func replacePresetImage() {
        guard canEditPresets, let index = draft.presets.firstIndex(where: { $0.id == selectedPresetID }) else { return }
        let panel = NSOpenPanel()
        panel.title = L("Replace Preset Image")
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let replacement = try store.importPresets([url], into: selectedSet).first else { return }
            var next = draft
            next.presets[index].fileName = replacement.fileName
            next.presets[index].source = replacement.source
            commit(next)
        } catch { errorMessage = error.localizedDescription }
    }

    func removeSelectedPreset() {
        guard canEditPresets, let preset = selectedPreset else { return }
        let remaining = draft.presets.filter { $0.id != preset.id }
        if isActive && remaining.isEmpty { errorMessage = PetPackError.activePackNeedsImage.localizedDescription; return }
        expandedTarget = nil
        let affectedKeys = draft.mappings.filter { $0.selection.presetIDs.contains(preset.id) }.count
        let targets: [String] = [draft.idle.presetIDs == [preset.id] ? L("When Resting") : nil,
                                  draft.unassigned.presetIDs == [preset.id] ? L("Unassigned") : nil].compactMap { $0 }
        let alert = NSAlert()
        alert.messageText = L("Delete preset “%1$@”?", preset.name)
        alert.informativeText = L("It will be removed from %1$@ key mappings. Keys with no remaining presets will use Unassigned. Original image files will not be changed.", affectedKeys)
        let replacement = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        if !remaining.isEmpty && !targets.isEmpty {
            replacement.addItems(withTitles: remaining.map(\.name))
            let stack = NSStackView(views: [NSTextField(labelWithString: L("Replacement for %1$@", targets.joined(separator: " · "))), replacement])
            stack.orientation = .vertical
            stack.alignment = .leading
            alert.accessoryView = stack
        }
        alert.addButton(withTitle: L("Delete Image"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let replacementID = !remaining.isEmpty && !targets.isEmpty ? remaining[replacement.indexOfSelectedItem].id : nil
            let next = try store.removingPreset(id: preset.id, from: draft, in: selectedSet, replacementID: replacementID)
            if commit(next) { selectedPresetID = next.presets.first?.id ?? "" }
        } catch { errorMessage = error.localizedDescription }
    }

    func removePack(_ set: PetImageSet) {
        guard !set.isBuiltIn else { return }
        let wasActive = set.id == activeSetID
        let replacementSet: PetImageSet? = {
            guard wasActive, let index = sets.firstIndex(where: { $0.id == set.id }) else { return nil }
            if index > 0 { return sets[index - 1] }
            return sets.first { $0.id != set.id }
        }()
        let alert = NSAlert()
        alert.messageText = L("Remove “%1$@” from the list?", configuration(for: set).name)
        alert.informativeText = if let replacementSet {
            L("Deleting the active set switches to “%1$@”. Original images will not be changed.", configuration(for: replacementSet).name)
        } else {
            L("Original images will not be changed.")
        }
        alert.addButton(withTitle: L("Remove"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.library.deleteSet(id: set.id)
            if let replacementSet { try store.library.activateSet(id: replacementSet.id) }
            activeSetID = store.library.activeSetID
            sets = store.library.imageSets
            if selectedSetID == set.id { selectSet(replacementSet ?? store.library.activeSet) }
            onChange(wasActive)
        } catch { errorMessage = error.localizedDescription }
    }
    func renamePack(_ set: PetImageSet) {
        var pack = configuration(for: set)
        let field = NSTextField(string: pack.name)
        field.frame = NSRect(x: 0, y: 0, width: 270, height: 24)
        let alert = NSAlert()
        alert.messageText = L("Pack Name")
        alert.accessoryView = field
        alert.addButton(withTitle: L("Rename"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        pack.name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try store.save(pack, for: set)
            if selectedSetID == set.id { draft = pack }
            onChange(false)
        } catch { errorMessage = error.localizedDescription }
    }
}
struct KeyboardLayoutKey: Identifiable {
    var code: UInt16?
    var label: String
    var width: CGFloat = 1
    var isHardwareKey = false
    var id: String { "\(code.map(String.init) ?? label)-\(label)" }
    static let rows: [[KeyboardLayoutKey]] = [
        [Self(code: 53, label: "esc")] + zip([122,120,99,118,96,97,98,100,101,109,103,111], 1...12).map { Self(code: UInt16($0.0), label: "F\($0.1)") } + [Self(code: nil, label: "Touch ID", isHardwareKey: true)],
        [Self(code:50,label:"`"),Self(code:18,label:"1"),Self(code:19,label:"2"),Self(code:20,label:"3"),Self(code:21,label:"4"),Self(code:23,label:"5"),Self(code:22,label:"6"),Self(code:26,label:"7"),Self(code:28,label:"8"),Self(code:25,label:"9"),Self(code:29,label:"0"),Self(code:27,label:"−"),Self(code:24,label:"="),Self(code:51,label:"⌫",width:1.5)],
        [Self(code:48,label:"⇥",width:1.5),Self(code:12,label:"Q"),Self(code:13,label:"W"),Self(code:14,label:"E"),Self(code:15,label:"R"),Self(code:17,label:"T"),Self(code:16,label:"Y"),Self(code:32,label:"U"),Self(code:34,label:"I"),Self(code:31,label:"O"),Self(code:35,label:"P"),Self(code:33,label:"["),Self(code:30,label:"]"),Self(code:42,label:"\\")],
        [Self(code:nil,label:"caps",width:1.8),Self(code:0,label:"A"),Self(code:1,label:"S"),Self(code:2,label:"D"),Self(code:3,label:"F"),Self(code:5,label:"G"),Self(code:4,label:"H"),Self(code:38,label:"J"),Self(code:40,label:"K"),Self(code:37,label:"L"),Self(code:41,label:";"),Self(code:39,label:"'"),Self(code:36,label:"↩",width:1.8)],
        [Self(code:nil,label:"⇧L",width:2.2),Self(code:6,label:"Z"),Self(code:7,label:"X"),Self(code:8,label:"C"),Self(code:9,label:"V"),Self(code:11,label:"B"),Self(code:45,label:"N"),Self(code:46,label:"M"),Self(code:43,label:","),Self(code:47,label:"."),Self(code:44,label:"/"),Self(code:nil,label:"⇧R",width:2.2)],
        [Self(code:nil,label:"fn"),Self(code:nil,label:"⌃"),Self(code:nil,label:"⌥L"),Self(code:nil,label:"⌘L",width:1.3),Self(code:49,label:"space",width:5),Self(code:nil,label:"⌘R",width:1.3),Self(code:nil,label:"⌥R"),Self(code:123,label:"←"),Self(code:126,label:"↑"),Self(code:125,label:"↓"),Self(code:124,label:"→")]
    ]
}
