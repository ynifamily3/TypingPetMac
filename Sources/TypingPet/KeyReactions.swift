import AppKit
import CoreGraphics
import Foundation

struct KeyModifiers: OptionSet, Codable, Hashable {
    let rawValue: Int

    static let command = KeyModifiers(rawValue: 1 << 0)
    static let option = KeyModifiers(rawValue: 1 << 1)
    static let control = KeyModifiers(rawValue: 1 << 2)
    static let shift = KeyModifiers(rawValue: 1 << 3)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(eventFlags: CGEventFlags) {
        var result: KeyModifiers = []
        if eventFlags.contains(.maskCommand) { result.insert(.command) }
        if eventFlags.contains(.maskAlternate) { result.insert(.option) }
        if eventFlags.contains(.maskControl) { result.insert(.control) }
        if eventFlags.contains(.maskShift) { result.insert(.shift) }
        self = result
    }

    var displayPrefix: String {
        var value = ""
        if contains(.control) { value += "⌃" }
        if contains(.option) { value += "⌥" }
        if contains(.shift) { value += "⇧" }
        if contains(.command) { value += "⌘" }
        return value
    }
}

struct KeyStroke: Codable, Hashable {
    let keyCode: UInt16
    let modifiers: KeyModifiers

    var displayName: String { modifiers.displayPrefix + KeyCodeNames.name(for: keyCode) }
}

struct KeyReactionRule: Codable, Identifiable, Equatable {
    let id: UUID
    var stroke: KeyStroke
    var imageFileName: String
}

enum KeyReactionError: LocalizedError {
    case unreadableImage(String)
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let name): "이미지를 읽을 수 없습니다: \(name)"
        case .unsupportedFormat(let name): "지원하지 않는 이미지 형식입니다: \(name)"
        }
    }
}

@MainActor
final class KeyReactionStore {
    private enum Keys { static let rules = "keyReactionRules-v1" }

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let directory: URL
    private(set) var rules: [KeyReactionRule]

    init(fileManager: FileManager = .default, defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.directory = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TypingPet", isDirectory: true)
            .appendingPathComponent("KeyReactions", isDirectory: true)
        if let data = defaults.data(forKey: Keys.rules),
           let decoded = try? JSONDecoder().decode([KeyReactionRule].self, from: data) {
            rules = decoded
        } else {
            rules = []
        }
    }

    func imageURL(matching stroke: KeyStroke) -> URL? {
        guard let rule = rules.first(where: { $0.stroke == stroke }) else { return nil }
        let url = directory.appendingPathComponent(rule.imageFileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func imageURL(for rule: KeyReactionRule) -> URL? {
        let url = directory.appendingPathComponent(rule.imageFileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    func setRule(for stroke: KeyStroke, image sourceURL: URL) throws -> KeyReactionRule {
        let ext = sourceURL.pathExtension.lowercased()
        guard FolderImageSelection.supportedExtensions.contains(ext) else {
            throw KeyReactionError.unsupportedFormat(sourceURL.lastPathComponent)
        }
        guard NSImage(contentsOf: sourceURL) != nil else {
            throw KeyReactionError.unreadableImage(sourceURL.lastPathComponent)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(UUID().uuidString).\(ext)"
        try fileManager.copyItem(at: sourceURL, to: directory.appendingPathComponent(fileName))
        rules.removeAll { $0.stroke == stroke }
        let rule = KeyReactionRule(id: UUID(), stroke: stroke, imageFileName: fileName)
        rules.append(rule)
        rules.sort { $0.stroke.displayName < $1.stroke.displayName }
        persist()
        return rule
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: Keys.rules) }
    }
}

enum KeyCodeNames {
    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3",
        21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]",
        31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K",
        41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`",
        51: "Delete", 53: "Esc", 76: "Enter", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
        101: "F9", 103: "F11", 109: "F10", 111: "F12", 115: "Home", 116: "Page Up", 117: "Forward Delete",
        119: "End", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    static func name(for keyCode: UInt16) -> String { names[keyCode] ?? "키 \(keyCode)" }
}
