import AppKit
import SwiftUI
import Combine

final class TodoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // The key window sees shortcuts before any menu, so the bubble's fields get them even while the app is inactive.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = TextEditingShortcuts.action(modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers, keyCode: event.keyCode),
           NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// The pointer in the bubble's hosting view (top-left origin), or nil when it is not over the bubble.
// Hover is computed from this and SwiftUI's own frames, because AppKit tracking areas inside SwiftUI
// can lag behind layout changes, for example while an edited title grows.
@MainActor
final class BubblePointer: ObservableObject {
    @Published var location: CGPoint? { didSet { updateCursor() } }
    // Text inputs register their frames so the pointer shows a text cursor before the panel is key.
    // AppKit would only do that through cursor rects, which work in the key window alone.
    private var textRegions: [AnyHashable: CGRect] = [:]
    private var showsTextCursor = false

    func setTextRegion(_ frame: CGRect?, for id: AnyHashable) {
        textRegions[id] = frame
        updateCursor()
    }

    private func updateCursor() {
        // Leaving the bubble needs nothing: the app under the pointer sets its own cursor.
        guard let location else { showsTextCursor = false; return }
        if textRegions.values.contains(where: { $0.contains(location) }) {
            NSCursor.iBeam.set()
            showsTextCursor = true
        } else if showsTextCursor {
            NSCursor.arrow.set()
            showsTextCursor = false
        }
    }
}

// Shared between the panel controller and the SwiftUI bubble.
// The view reports its natural size; the controller places the panel and picks the tail side.
@MainActor
final class TodoBubbleLayout: ObservableObject {
    static let tailLength: CGFloat = 10
    // Room around the bubble for its own shadow. Clicks there pass through.
    static let shadowMargin: CGFloat = 20
    @Published var tailEdge: TodoBubbleEdge = .bottom
    @Published var tailOffset: CGFloat = 0
    @Published var maxContentHeight: CGFloat = 520
    // Bumped when the user opens the list on purpose. Only then may the input take keyboard focus.
    @Published var focusRequest = 0
    // Bumped for each attention bounce. The height fits the room the canvas has on the far side from the pet.
    @Published var bounce = 0
    var bounceHeight = TodoBubbleLayout.attentionHopHeight
    // The first hop of the macOS Dock asking for attention, measured with a 48 pt Dock.
    static let attentionHopHeight: CGFloat = 53
    let pointer = BubblePointer()
    weak var window: NSWindow?
    // A nonactivating key panel receives keystrokes meant for the frontmost app.
    var windowIsKey: Bool { window?.isKeyWindow == true }
    private(set) var contentSize: CGSize = .zero
    var onContentSizeChange: (() -> Void)?

    func reportContentSize(_ size: CGSize) {
        guard abs(size.width - contentSize.width) > 0.5 || abs(size.height - contentSize.height) > 0.5 else { return }
        contentSize = size
        DispatchQueue.main.async { [weak self] in self?.onContentSizeChange?() }
    }
}

@MainActor
final class TodoBubbleWindowController {
    let store: TodoStore
    let panel: TodoPanel
    let layout = TodoBubbleLayout()
    let entry: TodoPanel
    private weak var pet: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var mouseMonitors: [Any] = []
    private var bubbleFrame: CGRect = .zero
    private var previousBubbleFrame: CGRect = .zero
    private var bubbleTransitionEnds: TimeInterval = 0
    private var revealed = false
    private var mustShow = false
    private var hideWork: DispatchWorkItem?
    private var menuTracking = false
    private var alphaTarget: CGFloat = 1
    private var bouncesLeft = 0
    private var bounceWork: DispatchWorkItem?

    init(store: TodoStore, pet: NSWindow, defaults: UserDefaults = AppEnvironment.defaults) {
        self.store = store
        self.pet = pet
        panel = Self.makePanel(size: NSSize(width: 320, height: 240))
        entry = Self.makePanel(size: TodoBubbleGeometry.entrySize)
        setAppearanceMode(SettingsAppearanceMode.load(from: defaults))
        panel.contentView = NSHostingView(rootView: TodoBubbleView(store: store, layout: layout))
        entry.contentView = NSHostingView(rootView: TodoEntryButton { [weak self] in self?.show() })
        layout.window = panel
        layout.onContentSizeChange = { [weak self] in self?.synchronize() }
        store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.synchronize() }
        }.store(in: &subscriptions)
        store.$attentionRequest.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.beginBouncing() }
        }.store(in: &subscriptions)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            notificationTokens.append(NotificationCenter.default.addObserver(forName: name, object: pet, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.synchronize() }
            })
        }
        notificationTokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronize() }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.panel.makeFirstResponder(nil) }
        })
        // The canvas is mostly transparent. Let clicks outside the bubble reach the windows below.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .leftMouseDown || event.type == .rightMouseDown {
                    self.panel.makeFirstResponder(nil)
                }
                self.handlePointerMotion()
            }
        }) { mouseMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handlePointerMotion() }
            return event
        }) { mouseMonitors.append(monitor) }
        // Menus opened from the bubble take the pointer away from it; keep it shown meanwhile.
        for (name, tracking) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            notificationTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.menuTracking = tracking
                    self?.updatePointerState()
                }
            })
        }
        notificationTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.makeFirstResponder(nil)
                self?.store.pauseForSleep()
            }
        })
        // Locking the screen is the clearest sign of leaving. The display can sleep without it, which idle time covers.
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            notificationTokens.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if locked {
                        self?.panel.makeFirstResponder(nil)
                        self?.store.screenDidLock()
                    } else {
                        self?.store.screenDidUnlock()
                    }
                }
            })
        }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.tick()
                self.handlePointerMotion()
            }
        }
        timer.tolerance = 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        synchronize()
    }

    func refreshLocalizedInterface() {
        panel.title = AppEnvironment.displayName + L(" · Todos")
        entry.title = panel.title
    }

    func setAppearanceMode(_ mode: SettingsAppearanceMode) {
        panel.appearance = mode.windowAppearance
        entry.appearance = mode.windowAppearance
    }

    private static func makePanel(size: NSSize) -> TodoPanel {
        let panel = TodoPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = AppEnvironment.displayName + L(" · Todos")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The bubble draws its own shadow, which stays the same when the panel becomes key.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        // Buttons work without key status. Only text input takes keystrokes from the frontmost app.
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    // While SwiftUI animates between two shapes, both stay interactive.
    private var interactiveFrame: CGRect {
        guard ProcessInfo.processInfo.systemUptime < bubbleTransitionEnds, previousBubbleFrame != .zero else { return bubbleFrame }
        return bubbleFrame.union(previousBubbleFrame)
    }

    var isInteracting: Bool {
        let mouse = NSEvent.mouseLocation
        return (panel.isVisible && alphaTarget > 0.01 && (interactiveFrame.insetBy(dx: -14, dy: -14).contains(mouse) || panel.isKeyWindow))
            || (entry.isVisible && entry.frame.insetBy(dx: -40, dy: -40).contains(mouse))
    }

    func show() {
        store.show()
        synchronize()
        panel.makeKeyAndOrderFront(nil)
        layout.focusRequest += 1
    }

    func synchronize() {
        guard let pet, pet.isVisible else {
            panel.orderOut(nil); entry.orderOut(nil); return
        }
        let visible = (pet.screen ?? NSScreen.main)?.visibleFrame ?? pet.frame
        if panel.level != pet.level { panel.level = pet.level }
        if entry.level != pet.level { entry.level = pet.level }
        let preferences = store.engine.state.featurePreferences
        if (preferences.enabled && !preferences.bubbleHidden) || store.errorMessage != nil {
            let zoom = CGFloat(store.zoom)
            let content = layout.contentSize == .zero ? CGSize(width: 320 * zoom, height: 240 * zoom) : layout.contentSize
            let canvas = TodoBubbleGeometry.canvas(content: content, tail: TodoBubbleLayout.tailLength * zoom, width: 320 * zoom,
                                                   maxHeight: max(160, min(560 * zoom, visible.height - 48)), pet: pet.frame, visible: visible,
                                                   margin: TodoBubbleLayout.shadowMargin)
            if abs(layout.maxContentHeight - canvas.maxContentHeight) > 0.5 { layout.maxContentHeight = canvas.maxContentHeight }
            if layout.tailEdge != canvas.tailEdge { layout.tailEdge = canvas.tailEdge }
            if abs(layout.tailOffset - canvas.tailOffset) > 0.5 { layout.tailOffset = canvas.tailOffset }
            if panel.frame != canvas.frame { panel.setFrame(canvas.frame, display: true) }
            if bubbleFrame != canvas.bubble {
                previousBubbleFrame = bubbleFrame
                bubbleFrame = canvas.bubble
                bubbleTransitionEnds = ProcessInfo.processInfo.systemUptime + 0.5
            }
            if !panel.isVisible { panel.orderFrontRegardless() }
            updatePointerState()
        } else {
            panel.orderOut(nil)
        }
        updateEntryVisibility(pet: pet, visible: visible)
    }

    private func handlePointerMotion() {
        if let pet, pet.isVisible {
            let visible = (pet.screen ?? NSScreen.main)?.visibleFrame ?? pet.frame
            updateEntryVisibility(pet: pet, visible: visible)
        }
        updatePointerState()
    }

    private func updateEntryVisibility(pet: NSWindow, visible: CGRect) {
        let mouse = NSEvent.mouseLocation
        let entryFrame = TodoBubbleGeometry.entryFrame(pet: pet.frame, visible: visible)
        // Show the entry before pointer avoidance moves the pet away.
        let nearPet = PetPointerAvoidance.distance(from: mouse, to: pet.frame) <= 108
        let overEntry = entryFrame.insetBy(dx: -18, dy: -18).contains(mouse)
        if nearPet || overEntry {
            if entry.frame != entryFrame { entry.setFrame(entryFrame, display: true) }
            if !entry.isVisible { entry.orderFrontRegardless() }
        } else if entry.isVisible {
            entry.orderOut(nil)
        }
    }

    private func updatePointerState() {
        guard panel.isVisible, let pet else { return }
        let mouse = NSEvent.mouseLocation
        let overBubble = interactiveFrame.insetBy(dx: -12, dy: -12).contains(mouse)
        let overPet = pet.frame.insetBy(dx: -8, dy: -8).contains(mouse) || (entry.isVisible && entry.frame.contains(mouse))
        let pointerWants = store.bubbleVisibility == .always ? overBubble || overPet : overPet || (revealed && overBubble)
        // Typing, open popovers and menus, an expired timer, an absence notice, and errors always keep the bubble readable.
        let popoverOpen = !(panel.childWindows ?? []).isEmpty
            || NSApp.windows.contains { $0 !== panel && $0 !== entry && $0 !== pet && $0.isVisible && $0.className.contains("Popover") }
        mustShow = panel.isKeyWindow || popoverOpen || menuTracking
            || store.engine.activeSession?.status == .expired || store.absence != nil || store.errorMessage != nil
        // Pointing at the bubble or the pet stops the bouncing.
        if bouncesLeft > 0, overBubble || overPet {
            bouncesLeft = 0
            bounceWork?.cancel()
        }
        if pointerWants || mustShow {
            hideWork?.cancel()
            hideWork = nil
            revealed = true
        } else if revealed, hideWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hideWork = nil
                self.revealed = false
                self.applyOpacity()
                self.updatePointerState()
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        applyOpacity()
        // The canvas is mostly transparent, and a hidden bubble takes no clicks at all.
        let inside = alphaTarget > 0.01 && interactiveFrame.insetBy(dx: -4, dy: -4).contains(mouse)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        let location = inside ? panel.contentView.map { $0.convert(panel.convertPoint(fromScreen: mouse), from: nil) } : nil
        if layout.pointer.location != location { layout.pointer.location = location }
    }

    // Like a Dock icon making a critical request: bounce every 2 seconds until the pointer comes over or the user answers.
    // It stops after five rounds so a bubble nobody watches does not bounce for hours; the return bounces again.
    private func beginBouncing() {
        bouncesLeft = 5
        bounceAgain()
    }

    private func bounceAgain() {
        bounceWork?.cancel()
        let waiting = store.absence != nil || store.engine.activeSession?.status == .expired
        guard bouncesLeft > 0, waiting, panel.isVisible else { bouncesLeft = 0; return }
        bouncesLeft -= 1
        // Keep the bubble and its shadow inside the canvas.
        let room: CGFloat
        switch layout.tailEdge {
        case .bottom: room = panel.frame.maxY - bubbleFrame.maxY
        case .top: room = bubbleFrame.minY - panel.frame.minY
        case .leading: room = panel.frame.maxX - bubbleFrame.maxX
        case .trailing: room = bubbleFrame.minX - panel.frame.minX
        }
        layout.bounceHeight = min(TodoBubbleLayout.attentionHopHeight, room - 12)
        if layout.bounceHeight >= 6 { layout.bounce += 1 }
        guard bouncesLeft > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.bounceAgain() }
        bounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func applyOpacity() {
        // Typing, an expired timer, and errors must stay readable whatever the opacity settings say.
        let target: CGFloat
        if mustShow { target = 1 }
        else if revealed { target = CGFloat(store.bubbleHoverOpacity) }
        else { target = store.bubbleVisibility == .hover ? 0 : CGFloat(store.bubbleRestingOpacity) }
        guard abs(target - alphaTarget) > 0.001 else { return }
        alphaTarget = target
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = target
        }
    }
}
