import XCTest
import Darwin
@testable import TypingPet

private final class TestClock {
    var uptime: Double = 0
    var date = Date(timeIntervalSince1970: 1_790_000_000)
    func advance(_ seconds: Double) { uptime += seconds; date += seconds }
    func engine() -> FocusTimerEngine { FocusTimerEngine(monotonicNow: { self.uptime }, wallNow: { self.date }) }
}

final class FocusTimerTests: XCTestCase {
    func testActualTimeAcrossThreeSessionsIs64Minutes() throws {
        let c = TestClock()
        var e = c.engine()
        let id = try XCTUnwrap(e.addTodo("Work"))
        e.setPreference(.countdown(minutes: 25)!, for: id)
        XCTAssertTrue(e.start(id))
        c.advance(1508); e.tick()
        XCTAssertEqual(e.activeSession?.status, .expired)
        c.advance(300); e.finish()
        e.setPreference(.countdown(minutes: 45)!, for: id)
        XCTAssertTrue(e.start(id)); c.advance(18 * 60); e.finish()
        e.setPreference(.countup, for: id)
        XCTAssertTrue(e.start(id)); c.advance(21 * 60); e.finish()
        XCTAssertEqual(e.totalSeconds(for: id), 64 * 60, accuracy: 0.0001)
        XCTAssertNil(e.openTodos.first?.completedAt)
        try e.state.validate()
    }

    func testExtensionUsesSameSessionAndExcludesWaiting() throws {
        let c = TestClock(); var e = c.engine()
        let id = e.addTodo("Work")!
        e.start(id); let sessionID = e.activeSession?.id
        c.advance(1209); e.tick(); c.advance(450)
        e.extend(minutes: 10); c.advance(300); e.finish()
        XCTAssertEqual(e.state.sessions.count, 1)
        XCTAssertEqual(e.state.sessions[0].id, sessionID)
        XCTAssertEqual(e.state.sessions[0].activeSegments.count, 2)
        XCTAssertEqual(e.totalSeconds(for: id), 1500)
        try e.state.validate()
    }

    func testRepeatedPauseResumeAndWallClockChanges() throws {
        let c = TestClock(); var e = c.engine(); let id = e.addTodo("Work")!
        e.setPreference(.countup, for: id); e.start(id)
        for _ in 0..<4 {
            c.advance(0.25); e.tick(); e.tick(); e.pause()
            c.advance(900); e.tick(); e.resume()
        }
        c.date -= 80_000; c.uptime += 2.5; e.finish()
        XCTAssertEqual(e.totalSeconds(for: id), 3.5, accuracy: 0.000001)
        try e.state.validate()
    }

    func testSwitchCancelAndConfirmationTime() throws {
        let c = TestClock(); var e = c.engine()
        let a = e.addTodo("A")!; let b = e.addTodo("B")!
        e.start(a); c.advance(10)
        XCTAssertFalse(e.start(b)) // Cancel leaves the engine unchanged.
        e.setPreference(.countup, for: b)
        XCTAssertEqual(e.activeSession?.todoId, a)
        c.advance(6); XCTAssertTrue(e.start(b, replaceActive: true))
        XCTAssertEqual(e.totalSeconds(for: a), 16)
        XCTAssertEqual(e.state.sessions[0].endReason, .switched)
        XCTAssertEqual(e.activeSession?.todoId, b)
        XCTAssertEqual(e.state.sessions.filter { $0.status != .finished }.count, 1)
        e.pause(); XCTAssertFalse(e.start(a)); e.resume()
        c.advance(1); e.finish(); e.start(a); c.advance(1201); e.tick()
        XCTAssertFalse(e.start(b)); XCTAssertTrue(e.start(b, replaceActive: true))
        try e.state.validate()
    }

    func testCompleteUndoDeleteAndUnrelatedTodo() throws {
        let c = TestClock(); var e = c.engine()
        let a = e.addTodo("A")!; let b = e.addTodo("B")!
        e.start(a); c.advance(7.125); e.setCompleted(b, completed: true)
        XCTAssertEqual(e.activeSession?.todoId, a)
        e.setCompleted(a, completed: true)
        XCTAssertNil(e.activeSession)
        XCTAssertEqual(e.state.sessions[0].endReason, .completed)
        e.setCompleted(a, completed: false); e.delete(a)
        XCTAssertEqual(e.totalSeconds(for: a), 7.125)
        XCTAssertEqual(e.openTodos.count, 0)
        try e.state.validate()
    }

    func testLocalCalendarMidnightKeepsOpenTodosAndTimer() throws {
        let c = TestClock()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        c.date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 23, minute: 59))!
        var e = c.engine(); let a = e.addTodo("A")!; let b = e.addTodo("B")!
        e.setCompleted(a, completed: true); e.start(b)
        XCTAssertEqual(e.completedToday(calendar: calendar).count, 1)
        c.advance(120); e.tick()
        XCTAssertEqual(e.completedToday(calendar: calendar).count, 0)
        XCTAssertEqual(e.openTodos.map(\.id), [b])
        XCTAssertEqual(e.activeSession?.status, .running)
        XCTAssertEqual(e.totalSeconds(for: b), 120)
    }

    func testRenameKeepsSessionsAndRejectsBlankTitles() throws {
        let c = TestClock()
        var e = c.engine()
        let id = try XCTUnwrap(e.addTodo("Draft"))
        XCTAssertTrue(e.start(id)); c.advance(90)
        e.rename(id, to: "  Final title  ")
        XCTAssertEqual(e.activeSession?.todoId, id)
        e.finish()
        e.rename(id, to: " \n ")
        XCTAssertEqual(e.state.todos[0].title, "Final title")
        XCTAssertEqual(e.totalSeconds(for: id), 90, accuracy: 0.0001)
        e.delete(id); e.rename(id, to: "Hidden")
        XCTAssertEqual(e.state.todos[0].title, "Final title")
        try e.state.validate()
    }

    func testSettingsAreIndependentAndDoNotStartTimer() throws {
        var e = TestClock().engine(); let a = e.addTodo("Same")!; let b = e.addTodo("Same")!
        XCTAssertNil(e.addTodo(" \n "))
        e.setPreference(.countup, for: a)
        XCTAssertEqual(e.state.todos[1].timerPreference, TimerPreference())
        XCTAssertNil(e.activeSession)
        XCTAssertNotEqual(a, b)
        XCTAssertNil(TimerPreference.countdown(minutes: 0))
        XCTAssertNil(TimerPreference.countdown(minutes: 1000))
        XCTAssertNotNil(TimerPreference.countdown(minutes: 999))
        e.setPreference(TimerPreference(seconds: .infinity), for: a)
        XCTAssertEqual(e.state.todos[0].timerPreference, .countup)
    }

    func testRestartRestoresPausedAndDoesNotAddOfflineTime() throws {
        let c = TestClock(); var e = c.engine(); let id = e.addTodo("Work")!
        e.start(id); c.advance(12.25); e.tick()
        let snapshot = e.state
        c.advance(80_000)
        e = FocusTimerEngine(state: snapshot, monotonicNow: { c.uptime }, wallNow: { c.date })
        e.tick(); XCTAssertEqual(e.activeSession?.status, .paused)
        XCTAssertEqual(e.totalSeconds(for: id), 12.25)
        e.resume(); c.advance(0.75); e.finish()
        XCTAssertEqual(e.totalSeconds(for: id), 13)
        try e.state.validate()
    }

    func testAbsencePauseTakesBackIdleTimeAndIncludingRestoresIt() throws {
        let c = TestClock(); var e = c.engine(); let id = e.addTodo("Work")!
        e.setPreference(.countup, for: id); e.start(id)
        c.advance(1000)
        XCTAssertEqual(e.pause(excludingLast: 900), 900)
        XCTAssertEqual(e.activeSession?.status, .paused)
        XCTAssertEqual(e.activeSession?.totalActiveSeconds, 100)
        c.advance(3600); e.resume(adding: 4500)
        XCTAssertEqual(e.activeSession?.status, .running)
        XCTAssertEqual(e.activeSession?.totalActiveSeconds, 4600)
        c.advance(10); e.pause(excludingLast: 99_999)
        XCTAssertEqual(e.activeSession?.totalActiveSeconds, 0)
        e.finish()
        e.setPreference(.countdown(minutes: 20)!, for: id); e.start(id)
        c.advance(600); e.pause(excludingLast: 300)
        XCTAssertEqual(e.displaySeconds, 900)
        e.resume(adding: 2000)
        XCTAssertEqual(e.activeSession?.status, .expired)
        XCTAssertEqual(e.activeSession?.activeSegments.last?.actualActiveSeconds, 1200)
        try e.state.validate()
    }
}

final class TodoPersistenceTests: XCTestCase {
    private func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("todo-state.json")
    }

    func testJSONRoundTripAndPreferences() throws {
        let storage = TodoFileStorage(url: try temporaryFile())
        let c = TestClock(); var e = c.engine(); let id = e.addTodo("한글 Work")!
        e.setFeature(enabled: true, hidden: true)
        e.setPreference(.countup, for: id); e.start(id)
        c.advance(1.234567); e.finish()
        try storage.save(e.state)
        let restored = try storage.load()
        XCTAssertEqual(restored.todos, e.state.todos)
        XCTAssertEqual(restored.featurePreferences, e.state.featurePreferences)
        XCTAssertEqual(restored.sessions[0].totalActiveSeconds, 1.234567)
        XCTAssertEqual(restored.sessions[0].endedAt!.timeIntervalSince1970, e.state.sessions[0].endedAt!.timeIntervalSince1970, accuracy: 1)
        let text = try String(contentsOf: storage.url, encoding: .utf8)
        XCTAssertTrue(text.contains("totalActiveSeconds"))
        XCTAssertTrue(text.contains("Z"))
    }

    // Stores with a test clock also fake idle time. A CI runner has no input, so real idle time pauses the timer.
    @MainActor func testCheckpointCrashSleepAndNormalTerminationRecovery() throws {
        let url = try temporaryFile(); let c = TestClock()
        var store = TodoStore(url: url, monotonicNow: { c.uptime }, wallNow: { c.date }, idleSeconds: { 0 })
        store.change { e in let id = e.addTodo("Work")!; e.start(id) }
        c.advance(5); store.tick()
        c.advance(3) // Uncommitted time is lost after a crash.
        store = TodoStore(url: url, monotonicNow: { c.uptime }, wallNow: { c.date }, idleSeconds: { 0 })
        XCTAssertEqual(store.engine.activeSession?.status, .paused)
        XCTAssertEqual(store.engine.activeSession?.totalActiveSeconds, 5)
        store.change { $0.resume() }; c.advance(2.5)
        store.pauseForSleepOrTermination(); c.advance(9000); store.tick()
        XCTAssertEqual(store.engine.activeSession?.totalActiveSeconds, 7.5)
        store = TodoStore(url: url, monotonicNow: { c.uptime }, wallNow: { c.date }, idleSeconds: { 0 })
        XCTAssertEqual(store.engine.activeSession?.status, .paused)
        XCTAssertEqual(store.engine.activeSession?.totalActiveSeconds, 7.5)
    }

    @MainActor func testCorruptAndFutureFilesAreNeverOverwritten() throws {
        for data in [Data("broken".utf8), Data("{\"schemaVersion\":99,\"todos\":[],\"sessions\":[],\"featurePreferences\":{\"enabled\":false,\"bubbleHidden\":false}}".utf8)] {
            let url = try temporaryFile(); try data.write(to: url)
            let store = TodoStore(url: url)
            XCTAssertTrue(store.loadBlocked)
            XCTAssertNotNil(store.errorMessage)
            store.show(); store.tick(); store.persist()
            XCTAssertEqual(try Data(contentsOf: url), data)
            XCTAssertTrue(store.engine.state.todos.isEmpty)
        }
    }

    @MainActor func testWriteFailureIsVisibleAndRetryCanSave() throws {
        let url = try temporaryFile()
        try Data("block folder".utf8).write(to: url)
        let target = url.appendingPathComponent("record.json")
        let store = TodoStore(url: target)
        XCTAssertNotNil(store.errorMessage)
        store.change { _ = $0.addTodo("Keep me") }
        try FileManager.default.removeItem(at: url)
        store.persist()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(try TodoFileStorage(url: target).load().todos.first?.title, "Keep me")
    }

    @MainActor func testVisibilitySavesMeasuredTimeAndDoesNotStopTimer() throws {
        let url = try temporaryFile(); let c = TestClock()
        let store = TodoStore(url: url, monotonicNow: { c.uptime }, wallNow: { c.date }, idleSeconds: { 0 })
        store.change { e in let id = e.addTodo("Work")!; e.setPreference(.countup, for: id); e.start(id) }
        c.advance(2.25); store.hide()
        let hidden = try TodoFileStorage(url: url).load()
        XCTAssertTrue(hidden.featurePreferences.bubbleHidden)
        XCTAssertEqual(hidden.sessions[0].totalActiveSeconds, 2.25)
        c.advance(1); store.show()
        XCTAssertEqual(store.engine.activeSession?.status, .running)
        XCTAssertEqual(store.engine.activeSession?.totalActiveSeconds, 3.25)
    }

    @MainActor func testIdleLockAndSleepPauseAndTheNoticeFollowsTheAnswer() throws {
        let url = try temporaryFile(); let c = TestClock(); var idle = 0.0
        let suite = "TypingPetTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var store = TodoStore(url: url, defaults: defaults, monotonicNow: { c.uptime }, wallNow: { c.date }, idleSeconds: { idle })
        XCTAssertEqual(store.idleMinutes, 15)
        var id: UUID?
        store.change { id = $0.addTodo("Work"); $0.setPreference(.countup, for: id!); $0.start(id!) }
        let start = c.date
        c.advance(600); idle = 300; store.tick()
        XCTAssertEqual(store.engine.activeSession?.status, .running)
        c.advance(600); idle = 900; store.tick()
        XCTAssertEqual(store.engine.activeSession?.status, .paused)
        XCTAssertEqual(store.engine.activeSession?.totalActiveSeconds, 300)
        XCTAssertEqual(store.absence?.reason, .idle)
        XCTAssertEqual(store.absence?.since, start + 300)
        c.advance(3600); idle = 4500; store.tick()
        XCTAssertNil(store.absence?.returnedAt)
        idle = 1; store.tick()
        XCTAssertEqual(store.absence?.returnedAt, c.date)
        XCTAssertEqual(store.absence?.awaySeconds(now: c.date + 99), 4500)
        c.advance(10); store.includeAbsence()
        XCTAssertEqual(store.engine.activeSession?.status, .running)
        XCTAssertEqual(store.engine.activeSession?.totalActiveSeconds, 4810)
        XCTAssertNil(store.absence)
        idle = 2; store.screenDidLock()
        XCTAssertEqual(store.absence?.reason, .locked)
        c.advance(60); idle = 0.5; store.tick()
        XCTAssertNil(store.absence?.returnedAt)
        store.screenDidUnlock()
        XCTAssertEqual(store.absence?.returnedAt, c.date)
        store.change { $0.resume() }
        XCTAssertNil(store.absence)
        idle = 3; store.pauseForSleep()
        XCTAssertEqual(store.absence?.reason, .sleep)
        store.change { $0.finish() }
        XCTAssertNil(store.absence)
        store.change { $0.start(id!) }
        store.setIdleMinutes(7); store.setIdleMinutes(0)
        XCTAssertEqual(store.idleMinutes, 0)
        c.advance(5); idle = 99_999; store.tick(); store.screenDidLock()
        XCTAssertEqual(store.engine.activeSession?.status, .running)
        store.pauseForSleep()
        XCTAssertEqual(store.engine.activeSession?.status, .paused)
        XCTAssertNil(store.absence)
        store.setIdleMinutes(30)
        store = TodoStore(url: url, defaults: defaults, monotonicNow: { c.uptime }, wallNow: { c.date }, idleSeconds: { idle })
        XCTAssertEqual(store.idleMinutes, 30)
        try TodoFileStorage(url: url).load().validate()
    }

    @MainActor func testBubbleHopsOnExpiryAndOnReturnToAMissedNotice() throws {
        let c = TestClock(); var idle = 0.0
        let suite = "TypingPetTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TodoStore(url: try temporaryFile(), defaults: defaults, monotonicNow: { c.uptime }, wallNow: { c.date }, idleSeconds: { idle })
        var id: UUID?
        store.change { id = $0.addTodo("Work"); $0.start(id!) }
        c.advance(1200); store.tick()
        XCTAssertTrue(store.engine.activeSession?.status == .expired && store.attentionRequest == 1, "Expiry did not hop")
        c.advance(5); idle = 1; store.tick()
        XCTAssertTrue(store.attentionRequest == 1, "Expiry while present hopped twice")
        store.change { $0.finish(); $0.start(id!) }
        c.advance(1195); idle = 600; store.tick(); c.advance(5); idle = 605; store.tick()
        XCTAssertTrue(store.attentionRequest == 2, "Expiry while away did not hop at once")
        c.advance(60); idle = 665; store.tick()
        XCTAssertTrue(store.attentionRequest == 2, "Hopped again without input")
        idle = 1; store.tick()
        XCTAssertTrue(store.attentionRequest == 3, "Missed expiry did not hop on return")
        store.change { $0.finish(); $0.setPreference(.countup, for: id!); $0.start(id!) }
        c.advance(1000); idle = 900; store.tick()
        XCTAssertTrue(store.absence != nil && store.attentionRequest == 3, "Absence hopped while nobody was there")
        c.advance(600); idle = 1; store.tick()
        XCTAssertTrue(store.attentionRequest == 4, "Return to an absence did not hop")
        store.change { $0.resume() }
        idle = 1; store.screenDidLock(); c.advance(30); store.change { $0.finish() }; store.screenDidUnlock(); store.tick()
        XCTAssertTrue(store.attentionRequest == 4, "Hopped for a notice already answered")
    }

    @MainActor func testCompactListStaysOpenWhileATimerRunsEndsAndRelaunches() throws {
        let c = TestClock()
        let suite = "TypingPetTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = try temporaryFile()
        @MainActor func open() -> TodoStore { TodoStore(url: url, defaults: defaults, monotonicNow: { c.uptime }, wallNow: { c.date }, idleSeconds: { 0 }) }
        var store = open()
        store.setListStyle(.compact)
        store.change { let id = $0.addTodo("Work")!; $0.start(id) }
        store.expanded = true
        c.advance(1200); store.tick()
        XCTAssertTrue(store.engine.activeSession?.status == .expired && store.expanded, "The compact list folded when the countdown ended")
        store.change { $0.extend(minutes: 10) }
        store = open()
        XCTAssertTrue(store.engine.activeSession?.status == .paused && store.expanded, "A relaunch folded the compact list")
        store.setListStyle(.full)
        store = open()
        XCTAssertTrue(!store.expanded, "A relaunch kept the full list open over a timer")
        store.change { $0.resume() }; store.expanded = true
        c.advance(600); store.tick()
        XCTAssertTrue(store.engine.activeSession?.status == .expired && !store.expanded, "The full list did not fold when the countdown ended")
    }

    func testInvalidTotalsAndSessionReferencesAreRejected() throws {
        let c = TestClock(); var e = c.engine(); let id = e.addTodo("Work")!
        e.start(id); c.advance(60); e.finish()
        var state = e.state; state.todos = []
        XCTAssertThrowsError(try state.validate())
        let storage = TodoFileStorage(url: try temporaryFile()); try storage.save(e.state)
        var text = try String(contentsOf: storage.url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"totalActiveSeconds\" : 60", with: "\"totalActiveSeconds\" : 600")
        try Data(text.utf8).write(to: storage.url)
        XCTAssertThrowsError(try storage.load())
    }

    func testInputHardeningBoundsTitlesRejectsSymlinksAndSecuresPermissions() throws {
        let huge = String(repeating: "a\nb ", count: 20_000)
        let draft = TodoTitlePolicy.limitedDraft(huge)
        XCTAssertEqual(draft.count, TodoTitlePolicy.maxLength)
        XCTAssertFalse(draft.contains("\n"))
        let normalized = TodoTitlePolicy.normalized(huge)
        XCTAssertLessThanOrEqual(normalized.count, TodoTitlePolicy.maxLength)
        XCTAssertFalse(normalized.contains("\n"))

        var multilineState = TodoState(todos: [TodoItem(title: "Line 1\nLine 2", createdAt: Date())])
        XCTAssertThrowsError(try multilineState.validate())
        multilineState.todos[0].title = String(repeating: "x", count: 1001)
        XCTAssertThrowsError(try multilineState.validate())

        let file = try temporaryFile()
        let storage = TodoFileStorage(url: file)
        var e = TestClock().engine()
        _ = e.addTodo("Private task")
        try storage.save(e.state)
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)

        let link = file.deletingLastPathComponent().appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try TodoFileStorage(url: link).load())
    }

    func testSaveCreatesAndReplacesWithOwnerOnlyPermissions() throws {
        let file = try temporaryFile()
        let storage = TodoFileStorage(url: file)
        var state = TodoState(todos: [TodoItem(title: "First", createdAt: Date())])
        try storage.save(state)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        state.todos[0].title = "Replacement"
        try storage.save(state)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try storage.load().todos[0].title, "Replacement")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), [file.lastPathComponent])
    }

    func testPermissionFailurePreservesOriginalAndRemovesTemporaryFile() throws {
        let file = try temporaryFile()
        let original = TodoState(todos: [TodoItem(title: "Keep me", createdAt: Date())])
        try TodoFileStorage(url: file).save(original)
        let bytes = try Data(contentsOf: file)
        let storage = TodoFileStorage(url: file, setPrivatePermissions: { descriptor in
            var attributes = stat()
            XCTAssertEqual(fstat(descriptor, &attributes), 0)
            XCTAssertEqual(attributes.st_size, 0, "Personal data was written before its permissions were secured")
            throw POSIXError(.EPERM)
        })
        XCTAssertThrowsError(try storage.save(TodoState()))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), [file.lastPathComponent])
    }

    func testOversizedSaveDoesNotReplaceReadableRecords() throws {
        let file = try temporaryFile()
        let storage = TodoFileStorage(url: file)
        try storage.save(TodoState())
        let original = try Data(contentsOf: file)
        let title = String(repeating: "🔒", count: 1000)
        let oversized = TodoState(todos: (0..<3000).map { _ in TodoItem(title: title, createdAt: Date()) })
        XCTAssertThrowsError(try storage.save(oversized))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try storage.load(), TodoState())
    }

    @MainActor
    func testUnsafeRecordFilesBlockLoadingWithoutOverwritingThem() throws {
        let file = try temporaryFile()
        let fifo = file.deletingLastPathComponent().appendingPathComponent("fifo.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try TodoFileStorage(url: fifo).load())

        let dangling = file.deletingLastPathComponent().appendingPathComponent("dangling.json")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: file)
        XCTAssertThrowsError(try TodoFileStorage(url: dangling).load())

        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(TodoFileStorage.maximumFileSize + 1))
        try handle.close()
        let suite = "TypingPetOversizedRecords.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TodoStore(url: file, defaults: defaults)
        XCTAssertTrue(store.loadBlocked)
        store.change { _ = $0.addTodo("Must not overwrite") }
        store.persist()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, TodoFileStorage.maximumFileSize + 1)
    }

    func testPersistedTitlesRejectEveryNewlineKind() {
        for newline in ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let state = TodoState(todos: [TodoItem(title: "First\(newline)Second", createdAt: Date())])
            XCTAssertThrowsError(try state.validate())
        }
    }

    @MainActor func testIdleTicksDoNotPublishUntilDayRollsOverOrSessionRuns() throws {
        let c = TestClock()
        let suite = "TypingPetIdleTickTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = try temporaryFile()
        let store = TodoStore(url: file, defaults: defaults, monotonicNow: { c.uptime }, wallNow: { c.date }, idleSeconds: { 0 })
        var publications = 0
        let cancellable = store.objectWillChange.sink { _ in publications += 1 }
        defer { cancellable.cancel() }

        for _ in 0..<5 {
            c.advance(1)
            store.tick()
        }
        XCTAssertEqual(publications, 0)

        c.advance(86_400)
        store.tick()
        XCTAssertEqual(publications, 1)

        var id: UUID?
        store.change { id = $0.addTodo("Run"); $0.start(id!) }
        let baseline = publications
        c.advance(1)
        store.tick()
        XCTAssertEqual(publications, baseline + 1)
    }
}
