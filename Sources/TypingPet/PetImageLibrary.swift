import AppKit
import Foundation

struct FolderImageSelection {
    let idleURL: URL?
    let reactionURLs: [URL]

    static let supportedExtensions: Set<String> = [
        "png", "apng", "jpg", "jpeg", "gif",
        "tif", "tiff", "heic", "heif", "webp"
    ]

    static func make(from urls: [URL]) -> FolderImageSelection {
        let images = urls
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let idleURL = images.first {
            let name = $0.deletingPathExtension().lastPathComponent.lowercased()
            return name == "idle" || name == "pet-idle"
        }
        return FolderImageSelection(idleURL: idleURL, reactionURLs: images.filter { $0 != idleURL })
    }
}

struct PetImageSet: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var storageFolder: String?
    var idleFileName: String
    var reactionFileNames: [String]
    var isBuiltIn: Bool
}

struct FolderImportResult {
    let imageSet: PetImageSet
    let changedIdle: Bool
    let reactionCount: Int?
}

enum PetImageLibraryError: LocalizedError {
    case unsupportedFormat(String)
    case unreadableImage(String)
    case noImagesInFolder
    case noReactionImages
    case imageSetNotFound
    case cannotDeleteBuiltInSet

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let name): "지원하지 않는 이미지 형식입니다: \(name)"
        case .unreadableImage(let name): "이미지를 읽을 수 없습니다: \(name)"
        case .noImagesInFolder: "선택한 폴더에서 지원되는 이미지를 찾지 못했습니다."
        case .noReactionImages: "키 입력용 이미지를 한 장 이상 선택해 주세요."
        case .imageSetNotFound: "이미지 세트를 찾지 못했습니다."
        case .cannotDeleteBuiltInSet: "기본 이미지 세트는 삭제할 수 없습니다."
        }
    }
}

@MainActor
final class PetImageLibrary {
    private enum Keys {
        static let gallery = "imageGalleryData-v1"
        static let activeSetID = "activeImageSetID-v1"
        static let legacyIdleFile = "customIdleImageFile"
        static let legacyReactionFiles = "customReactionImageFiles"
    }

    static let builtInID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let defaultIdleName = "pet-idle.png"
    private static let defaultReactionNames = [
        "pet-left.png", "pet-right.png", "pet-question.png", "pet-exclamation.png"
    ]

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let imagesDirectory: URL
    private let setsDirectory: URL
    private var customSets: [PetImageSet]

    init(fileManager: FileManager = .default, defaults: UserDefaults = .standard, imagesDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.defaults = defaults
        if let imagesDirectory {
            self.imagesDirectory = imagesDirectory
        } else {
            self.imagesDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("TypingPet", isDirectory: true)
                .appendingPathComponent("Images", isDirectory: true)
        }
        setsDirectory = self.imagesDirectory.appendingPathComponent("Sets", isDirectory: true)
        if let data = defaults.data(forKey: Keys.gallery),
           let decoded = try? JSONDecoder().decode([PetImageSet].self, from: data) {
            customSets = decoded.filter { !$0.isBuiltIn }
        } else {
            customSets = []
        }
        migrateLegacySelectionIfNeeded()
        repairActiveSelection()
    }

    var imageSets: [PetImageSet] { [Self.builtInSet] + customSets }

    var activeSetID: UUID {
        get { UUID(uuidString: defaults.string(forKey: Keys.activeSetID) ?? "") ?? Self.builtInID }
        set { defaults.set(newValue.uuidString, forKey: Keys.activeSetID) }
    }

    var activeSet: PetImageSet { imageSets.first { $0.id == activeSetID } ?? Self.builtInSet }
    var idleURL: URL? { idleURL(for: activeSet) }
    var reactionURLs: [URL] { reactionURLs(for: activeSet) }
    var usesCustomImages: Bool { activeSetID != Self.builtInID }

    func idleURL(for set: PetImageSet) -> URL? { resolvedURL(fileName: set.idleFileName, set: set) }

    func reactionURLs(for set: PetImageSet) -> [URL] {
        set.reactionFileNames.compactMap { resolvedURL(fileName: $0, set: set) }
    }

    func activateSet(id: UUID) throws {
        guard imageSets.contains(where: { $0.id == id }) else { throw PetImageLibraryError.imageSetNotFound }
        activeSetID = id
    }

    @discardableResult
    func addSet(from folderURL: URL, name: String? = nil) throws -> PetImageSet {
        let contents = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let selection = FolderImageSelection.make(from: contents)
        let allImages = ([selection.idleURL].compactMap { $0 } + selection.reactionURLs)
        guard !allImages.isEmpty else { throw PetImageLibraryError.noImagesInFolder }

        let idleSource = selection.idleURL ?? allImages[0]
        var reactionSources = selection.reactionURLs.filter { $0 != idleSource }
        if reactionSources.isEmpty { reactionSources = [idleSource] }

        let id = UUID()
        let folderName = id.uuidString
        let destination = setsDirectory.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let idleName = try copyImage(from: idleSource, to: destination)
        let reactionNames = try reactionSources.map { try copyImage(from: $0, to: destination) }
        let requestedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (requestedName?.isEmpty == false ? requestedName! : folderURL.lastPathComponent)
        let set = PetImageSet(
            id: id,
            name: displayName,
            storageFolder: folderName,
            idleFileName: idleName,
            reactionFileNames: reactionNames,
            isBuiltIn: false
        )
        customSets.append(set)
        persistGallery()
        activeSetID = id
        return set
    }

    func deleteSet(id: UUID) throws {
        guard id != Self.builtInID else { throw PetImageLibraryError.cannotDeleteBuiltInSet }
        guard let index = customSets.firstIndex(where: { $0.id == id }) else {
            throw PetImageLibraryError.imageSetNotFound
        }
        customSets.remove(at: index)
        if activeSetID == id { activeSetID = Self.builtInID }
        persistGallery()
    }

    func renameSet(id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = customSets.firstIndex(where: { $0.id == id }) else {
            throw PetImageLibraryError.imageSetNotFound
        }
        customSets[index].name = trimmed
        persistGallery()
    }

    func replaceIdle(with sourceURL: URL) throws {
        var set = try editableActiveSet(named: "사용자 이미지")
        if set.storageFolder == nil { set.storageFolder = set.id.uuidString }
        let directory = try storageDirectory(for: set)
        set.idleFileName = try copyImage(from: sourceURL, to: directory)
        update(set)
    }

    func replaceReactions(with sourceURLs: [URL]) throws {
        guard !sourceURLs.isEmpty else { throw PetImageLibraryError.noReactionImages }
        var set = try editableActiveSet(named: "사용자 이미지")
        if set.storageFolder == nil { set.storageFolder = set.id.uuidString }
        let directory = try storageDirectory(for: set)
        set.reactionFileNames = try sourceURLs.map { try copyImage(from: $0, to: directory) }
        update(set)
    }

    @discardableResult
    func importFolder(_ folderURL: URL) throws -> FolderImportResult {
        let set = try addSet(from: folderURL)
        return FolderImportResult(imageSet: set, changedIdle: true, reactionCount: set.reactionFileNames.count)
    }

    func resetToDefaults() { activeSetID = Self.builtInID }

    private static var builtInSet: PetImageSet {
        PetImageSet(
            id: builtInID,
            name: "기본 세트",
            storageFolder: nil,
            idleFileName: defaultIdleName,
            reactionFileNames: defaultReactionNames,
            isBuiltIn: true
        )
    }

    private func resolvedURL(fileName: String, set: PetImageSet) -> URL? {
        if set.isBuiltIn {
            let name = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
            if let bundled = Bundle.main.url(forResource: name, withExtension: "png") { return bundled }
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Resources").appendingPathComponent(fileName)
            return fileManager.fileExists(atPath: source.path) ? source : nil
        }
        let base = set.storageFolder.map { setsDirectory.appendingPathComponent($0, isDirectory: true) } ?? imagesDirectory
        let url = base.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: url.path) { return url }
        if Self.defaultReactionNames.contains(fileName) || fileName == Self.defaultIdleName {
            let name = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
            if let bundled = Bundle.main.url(forResource: name, withExtension: "png") { return bundled }
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Resources").appendingPathComponent(fileName)
            return fileManager.fileExists(atPath: source.path) ? source : nil
        }
        return nil
    }

    private func editableActiveSet(named defaultName: String) throws -> PetImageSet {
        if !activeSet.isBuiltIn { return activeSet }
        let id = UUID()
        let folder = id.uuidString
        let directory = setsDirectory.appendingPathComponent(folder, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let idleName = try idleURL.map { try copyImage(from: $0, to: directory) } ?? Self.defaultIdleName
        let reactions = try reactionURLs.map { try copyImage(from: $0, to: directory) }
        let set = PetImageSet(id: id, name: defaultName, storageFolder: folder, idleFileName: idleName, reactionFileNames: reactions, isBuiltIn: false)
        customSets.append(set)
        persistGallery()
        activeSetID = id
        return set
    }

    private func update(_ set: PetImageSet) {
        guard let index = customSets.firstIndex(where: { $0.id == set.id }) else { return }
        customSets[index] = set
        persistGallery()
        activeSetID = set.id
    }

    private func storageDirectory(for set: PetImageSet) throws -> URL {
        let folder = set.storageFolder ?? set.id.uuidString
        let url = setsDirectory.appendingPathComponent(folder, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func copyImage(from sourceURL: URL, to destinationDirectory: URL) throws -> String {
        let ext = sourceURL.pathExtension.lowercased()
        guard FolderImageSelection.supportedExtensions.contains(ext) else {
            throw PetImageLibraryError.unsupportedFormat(sourceURL.lastPathComponent)
        }
        guard NSImage(contentsOf: sourceURL) != nil else {
            throw PetImageLibraryError.unreadableImage(sourceURL.lastPathComponent)
        }
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let safe = sourceURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let name = "\(UUID().uuidString)-\(safe).\(ext)"
        try fileManager.copyItem(at: sourceURL, to: destinationDirectory.appendingPathComponent(name))
        return name
    }

    private func persistGallery() {
        if let data = try? JSONEncoder().encode(customSets) { defaults.set(data, forKey: Keys.gallery) }
    }

    private func repairActiveSelection() {
        if !imageSets.contains(where: { $0.id == activeSetID }) { activeSetID = Self.builtInID }
    }

    private func migrateLegacySelectionIfNeeded() {
        guard customSets.isEmpty else { return }
        let idle = defaults.string(forKey: Keys.legacyIdleFile)
        let reactions = defaults.stringArray(forKey: Keys.legacyReactionFiles) ?? []
        guard idle != nil || !reactions.isEmpty else { return }
        let set = PetImageSet(
            id: UUID(), name: "기존 사용자 세트", storageFolder: nil,
            idleFileName: idle ?? Self.defaultIdleName,
            reactionFileNames: reactions.isEmpty ? Self.defaultReactionNames : reactions,
            isBuiltIn: false
        )
        customSets = [set]
        persistGallery()
        activeSetID = set.id
        defaults.removeObject(forKey: Keys.legacyIdleFile)
        defaults.removeObject(forKey: Keys.legacyReactionFiles)
    }
}
