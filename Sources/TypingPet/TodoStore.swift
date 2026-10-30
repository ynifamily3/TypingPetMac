import Foundation
import Combine
import CoreGraphics
import Darwin

struct TodoFileStorage {
    let url: URL
    static let maximumFileSize = 10 * 1024 * 1024
    private let setPrivatePermissions: (Int32) throws -> Void

    init(url: URL, setPrivatePermissions: @escaping (Int32) throws -> Void = TodoFileStorage.protectFile) {
        self.url = url
        self.setPrivatePermissions = setPrivatePermissions
    }

    static func protectFile(_ descriptor: Int32) throws {
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static var defaultURL: URL {
        AppEnvironment.supportDirectory.appendingPathComponent("todo-state.json")
    }
    func load() throws -> TodoState {
        // Check and read the same descriptor. Never follow a link or block opening a FIFO.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return TodoState() }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard attributes.st_mode & S_IFMT == S_IFREG, attributes.st_size <= Self.maximumFileSize else {
            throw TodoDataError.invalidState
        }
        // Keep the bound even if another process grows the file after fstat.
        var data = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, Self.maximumFileSize + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= Self.maximumFileSize else { throw TodoDataError.invalidState }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(TodoState.self, from: data)
        try state.validate()
        return state
    }
    func save(_ state: TodoState) throws {
        try state.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        // Do not publish a file the next launch would refuse to load.
        guard data.count <= Self.maximumFileSize else { throw TodoDataError.invalidState }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // mkstemp creates an exclusive 0600 file beside the destination for an atomic rename.
        var template = Array(url.deletingLastPathComponent().appendingPathComponent(".todo-state-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let temporaryURL = URL(fileURLWithPath: String(cString: template))
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Fail before writing personal data or replacing the original if protection fails.
        try setPrivatePermissions(descriptor)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

enum TodoBubbleVisibility: String, CaseIterable {
    case always, hover
}

// How much of the list the bubble shows. Compact is a widget-sized summary for a bubble that stays open.
enum TodoListStyle: String, CaseIterable {
    case full, compact
}

// Seconds since the last keyboard, mouse, or trackpad input in this login session. Needs no permission.
enum SystemIdle {
    static func seconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

// Why a running timer stopped on its own. Kept in memory only: a relaunch restores the session paused anyway.
struct TodoAbsence: Equatable {
    enum Reason { case idle, locked, sleep }
    let reason: Reason
    let sessionID: UUID
    // The last input before the user left, in wall time for display and uptime for adding time back.
    // Uptime stops while the Mac sleeps, so sleep is never added back.
    let since: Date
    let sinceUptime: TimeInterval
    let pausedAt: Date
    // The first input after the user came back. The shown duration stops here.
    var returnedAt: Date?
    func awaySeconds(now: Date) -> Double { max(0, (returnedAt ?? now).timeIntervalSince(since)) }
}

@MainActor
final class TodoStore: ObservableObject {
    @Published private(set) var engine: FocusTimerEngine
    @Published private(set) var errorMessage: String?
    @Published private(set) var loadBlocked = false
    @Published var expanded = true
    // A display preference, so it lives in UserDefaults instead of the record file.
    @Published private(set) var zoom: Double
    @Published private(set) var bubbleVisibility: TodoBubbleVisibility
    // Same model as the pet: opacity while the pointer is away, and while it is over the pet or bubble.
    @Published private(set) var bubbleRestingOpacity: Double
    @Published private(set) var bubbleHoverOpacity: Double
    @Published private(set) var listStyle: TodoListStyle
    // Minutes without input before a running timer pauses itself. 0 turns this and the lock pause off.
    @Published private(set) var idleMinutes: Int
    @Published private(set) var absence: TodoAbsence?
    // Bumped when the bubble should bounce for attention like a Dock icon: when a countdown ends,
    // and when the user comes back to an absence notice or an ending they did not see.
    @Published private(set) var attentionRequest = 0
    static let idleMinuteChoices = [0, 5, 10, 15, 30, 60]
    let storage: TodoFileStorage
    private var lastCheckpoint: TimeInterval
    private let monotonicNow: () -> TimeInterval
    private let wallNow: () -> Date
    private let idleSeconds: () -> Double
    private var screenLocked = false
    private var attentionOnReturn: Date?
    private var lastObservedDay: Date
    private let defaults: UserDefaults
    private static let zoomKey = "todoBubbleZoom"
    private static let visibilityKey = "todoBubbleVisibility"
    private static let restingOpacityKey = "todoBubbleRestingOpacity"
    private static let hoverOpacityKey = "todoBubbleHoverOpacity"
    private static let listStyleKey = "todoListStyle"
    private static let idleMinutesKey = "todoIdleMinutes"

    init(url: URL = TodoFileStorage.defaultURL, defaults: UserDefaults = AppEnvironment.defaults, monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, wallNow: @escaping () -> Date = Date.init, idleSeconds: @escaping () -> Double = SystemIdle.seconds) {
        storage = TodoFileStorage(url: url)
        self.defaults = defaults
        self.wallNow = wallNow
        self.idleSeconds = idleSeconds
        idleMinutes = (defaults.object(forKey: Self.idleMinutesKey) as? Int).flatMap { Self.idleMinuteChoices.contains($0) ? $0 : nil } ?? 15
        zoom = (defaults.object(forKey: Self.zoomKey) as? Double).map(TodoBubbleZoom.normalized) ?? 1
        bubbleVisibility = defaults.string(forKey: Self.visibilityKey).flatMap(TodoBubbleVisibility.init(rawValue:)) ?? .always
        bubbleRestingOpacity = (defaults.object(forKey: Self.restingOpacityKey) as? Double).map(Self.clampedOpacity) ?? 1
        bubbleHoverOpacity = (defaults.object(forKey: Self.hoverOpacityKey) as? Double).map(Self.clampedOpacity) ?? 1
        listStyle = defaults.string(forKey: Self.listStyleKey).flatMap(TodoListStyle.init(rawValue:)) ?? .full
        self.monotonicNow = monotonicNow
        lastCheckpoint = monotonicNow()
        lastObservedDay = Calendar.current.startOfDay(for: wallNow())
        do {
            engine = FocusTimerEngine(state: try storage.load(), monotonicNow: monotonicNow, wallNow: wallNow)
        } catch {
            engine = FocusTimerEngine(monotonicNow: monotonicNow, wallNow: wallNow)
            loadBlocked = true
            errorMessage = L("Could not read Todo records. The original file was preserved. %1$@", error.localizedDescription)
        }
        // The compact list shows the active Todo with its timer, so it stays open; the full list folds into the focus bubble.
        if engine.activeSession != nil { expanded = listStyle == .compact }
        if !loadBlocked { persist() }
    }
    func change(_ operation: (inout FocusTimerEngine) -> Void) {
        guard !loadBlocked else { return }
        let previous = engine.activeSession?.status
        engine.tick()
        operation(&engine)
        if engine.activeSession?.status == .expired, previous != .expired { didExpire() }
        // Resuming, finishing, or switching answers the notice.
        if let absence, engine.activeSession?.id != absence.sessionID || engine.activeSession?.status != .paused { self.absence = nil }
        persist()
    }
    func tick() {
        guard !loadBlocked else { return }
        let currentDay = Calendar.current.startOfDay(for: wallNow())
        if currentDay != lastObservedDay {
            lastObservedDay = currentDay
            objectWillChange.send()
        }
        let previous = engine.activeSession?.status
        if previous == .running {
            engine.tick()
            if engine.activeSession?.status == .expired, previous != .expired { didExpire() }
        }
        if previous != engine.activeSession?.status || monotonicNow() - lastCheckpoint >= 5 {
            if engine.activeSession?.status == .running || previous != engine.activeSession?.status || errorMessage != nil { persist() }
        }
        checkPresence()
    }
    func pauseForSleepOrTermination() { change { $0.pause() } }
    private func didExpire() {
        // The compact list shows the ending in its own bubble without folding, so an extension returns to the list.
        if listStyle == .full { expanded = false }
        requestAttention()
    }
    // Bounce now, and again at the next input when the user seems away and may have missed it.
    private func requestAttention(onlyOnReturn: Bool = false) {
        if !onlyOnReturn { attentionRequest += 1 }
        if onlyOnReturn || screenLocked || idleSeconds() >= 30 { attentionOnReturn = wallNow() }
    }
    private var needsAnswer: Bool { absence != nil || engine.activeSession?.status == .expired }

    // MARK: Absence

    func setIdleMinutes(_ value: Int) {
        guard Self.idleMinuteChoices.contains(value), value != idleMinutes else { return }
        idleMinutes = value
        defaults.set(value, forKey: Self.idleMinutesKey)
    }
    // Sleep always pauses. With absence detection on, it also takes back the idle time before it.
    func pauseForSleep() {
        if idleMinutes > 0 { pauseForAbsence(.sleep) } else { pauseForSleepOrTermination() }
    }
    func screenDidLock() {
        screenLocked = true
        if idleMinutes > 0 { pauseForAbsence(.locked) }
    }
    func screenDidUnlock() {
        screenLocked = false
        markReturned()
    }
    // Puts the whole absence back and keeps counting, as if the timer had never paused.
    func includeAbsence() {
        guard let absence else { return }
        change { $0.resume(adding: monotonicNow() - absence.sinceUptime) }
    }

    // Pauses a running timer once the user has been away long enough, and notices when they come back.
    private func checkPresence() {
        let idle = idleSeconds()
        if idleMinutes > 0, engine.activeSession?.status == .running, idle >= Double(idleMinutes * 60) {
            pauseForAbsence(.idle, idle: idle)
        } else if let absence, absence.returnedAt == nil, !screenLocked, idle < wallNow().timeIntervalSince(absence.pausedAt) {
            markReturned()
        }
        if let since = attentionOnReturn, !screenLocked, idle < wallNow().timeIntervalSince(since) {
            attentionOnReturn = nil
            if needsAnswer { attentionRequest += 1 }
        }
    }
    private func pauseForAbsence(_ reason: TodoAbsence.Reason, idle: Double? = nil) {
        guard let session = engine.activeSession, session.status == .running else { return }
        let idle = max(0, idle ?? idleSeconds())
        let now = wallNow()
        change { $0.pause(excludingLast: idle) }
        absence = TodoAbsence(reason: reason, sessionID: session.id, since: now.addingTimeInterval(-idle),
                              sinceUptime: monotonicNow() - idle, pausedAt: now)
        // Nobody is watching yet, so the bounce waits for the return.
        requestAttention(onlyOnReturn: true)
    }
    private func markReturned() {
        guard var absence, absence.returnedAt == nil else { return }
        absence.returnedAt = wallNow()
        self.absence = absence
    }
    func show() {
        expanded = true
        change { $0.setFeature(enabled: true, hidden: false) }
    }
    func hide() { change { $0.setFeature(enabled: true, hidden: true) } }
    var zoomPercent: Int { Int((zoom * 100).rounded()) }
    var canZoomIn: Bool { zoom < TodoBubbleZoom.steps[TodoBubbleZoom.steps.count - 1] }
    var canZoomOut: Bool { zoom > TodoBubbleZoom.steps[0] }
    func zoomIn() { setZoom(TodoBubbleZoom.larger(than: zoom)) }
    func zoomOut() { setZoom(TodoBubbleZoom.smaller(than: zoom)) }
    func resetZoom() { setZoom(1) }
    func setBubbleVisibility(_ value: TodoBubbleVisibility) {
        guard value != bubbleVisibility else { return }
        bubbleVisibility = value
        defaults.set(value.rawValue, forKey: Self.visibilityKey)
    }
    func setListStyle(_ value: TodoListStyle) {
        guard value != listStyle else { return }
        listStyle = value
        defaults.set(value.rawValue, forKey: Self.listStyleKey)
    }
    func setBubbleRestingOpacity(_ value: Double) {
        let value = Self.clampedOpacity(value)
        guard value != bubbleRestingOpacity else { return }
        bubbleRestingOpacity = value
        defaults.set(value, forKey: Self.restingOpacityKey)
    }
    func setBubbleHoverOpacity(_ value: Double) {
        let value = Self.clampedOpacity(value)
        guard value != bubbleHoverOpacity else { return }
        bubbleHoverOpacity = value
        defaults.set(value, forKey: Self.hoverOpacityKey)
    }
    private static func clampedOpacity(_ value: Double) -> Double { min(max(value, 0), 1) }
    func setZoom(_ value: Double) {
        let value = TodoBubbleZoom.normalized(value)
        guard value != zoom else { return }
        zoom = value
        defaults.set(value, forKey: Self.zoomKey)
    }
    func persist() {
        guard !loadBlocked else { return }
        do {
            try storage.save(engine.state)
            lastCheckpoint = monotonicNow()
            errorMessage = nil
        } catch {
            errorMessage = L("Could not save Todo records. Recent changes may be lost. %1$@", error.localizedDescription)
        }
    }
}
