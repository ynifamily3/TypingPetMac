import AppKit
import CoreGraphics
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

private enum PetConstants {
    static let fallbackBaseSize = NSSize(width: 453, height: 354)
    static let idleDelay: TimeInterval = 0.75
}

private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PetResizeHandleView: NSView {
    var onResizeBegan: ((NSPoint) -> Void)?
    var onResizeDragged: ((NSPoint) -> Void)?
    var onResizeEnded: (() -> Void)?

    private let imageView: NSImageView
    private(set) var isDragging = false
    private var cursorTrackingArea: NSTrackingArea?

    private static var resizeCursor: NSCursor {
        if #available(macOS 15.0, *) {
            return .frameResize(position: .topRight, directions: .all)
        }
        return .resizeLeftRight
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        imageView = NSImageView(frame: .zero)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        layer?.cornerRadius = frameRect.width / 2

        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        imageView.image = NSImage(
            systemSymbolName: "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: L("Resize")
        )?.withSymbolConfiguration(configuration)
        imageView.contentTintColor = .white
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)
        toolTip = L("Drag to resize")
        setAccessibilityLabel(L("Resize pet"))
        setAccessibilityHelp(L("Drag to resize your pet."))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
        imageView.frame = bounds.insetBy(dx: 9, dy: 9)
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        Self.resizeCursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        if !isDragging { NSCursor.arrow.set() }
    }

    override func cursorUpdate(with event: NSEvent) {
        Self.resizeCursor.set()
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        Self.resizeCursor.set()
        onResizeBegan?(screenLocation(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        Self.resizeCursor.set()
        onResizeDragged?(screenLocation(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        let localPoint = convert(event.locationInWindow, from: nil)
        (bounds.contains(localPoint) ? Self.resizeCursor : NSCursor.arrow).set()
        onResizeEnded?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: Self.resizeCursor)
    }

    private func screenLocation(for event: NSEvent) -> NSPoint {
        guard let window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
}

private final class PetContentView: NSView {
    var onClose: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onResizeBegan: ((NSPoint) -> Void)?
    var onResizeDragged: ((NSPoint) -> Void)?
    var onResizeEnded: (() -> Void)?
    var onMoveBegan: ((PetDragSample) -> Void)?
    var onMoveDragged: ((PetDragSample) -> Void)?
    var onMoveEnded: ((PetDragSample) -> Void)?
    weak var petImageView: NSView?

    private let closeButton: NSButton
    private let settingsButton: NSButton
    private let resizeHandle: PetResizeHandleView
    private var hoverTrackingArea: NSTrackingArea?
    private var controlsVisible = false
    private var isPointerInside = false
    private var isBodyPressed = false

    var controlsEnabled = true {
        didSet {
            if !controlsEnabled { hideControls() }
        }
    }

    override init(frame frameRect: NSRect) {
        closeButton = NSButton(frame: .zero)
        settingsButton = NSButton(frame: .zero)
        resizeHandle = PetResizeHandleView(frame: .zero)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        closeButton.isBordered = false
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: L("Hide Pet")
        )?.withSymbolConfiguration(.init(pointSize: 18, weight: .semibold))
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .white
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        closeButton.target = self
        closeButton.action = #selector(closePet)
        closeButton.setAccessibilityLabel(L("Hide Pet"))

        settingsButton.isBordered = false
        settingsButton.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: L("Open Settings")
        )?.withSymbolConfiguration(.init(pointSize: 18, weight: .semibold))
        settingsButton.imagePosition = .imageOnly
        settingsButton.contentTintColor = .white
        settingsButton.wantsLayer = true
        settingsButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.toolTip = L("Open Settings")
        settingsButton.setAccessibilityLabel(L("Open Pet Settings"))

        resizeHandle.onResizeBegan = { [weak self] in self?.onResizeBegan?($0) }
        resizeHandle.onResizeDragged = { [weak self] in self?.onResizeDragged?($0) }
        resizeHandle.onResizeEnded = { [weak self] in self?.onResizeEnded?() }

        addSubview(closeButton)
        addSubview(settingsButton)
        addSubview(resizeHandle)
        setControlsVisible(false, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        let imageFrame = bounds.insetBy(
            dx: bounds.width * 0.015,
            dy: bounds.height * 0.015
        )
        petImageView?.frame = imageFrame
        if let imageLayer = petImageView?.layer {
            imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            imageLayer.position = CGPoint(x: imageFrame.midX, y: imageFrame.midY)
        }
        let controlSize: CGFloat = 38
        let margin: CGFloat = 10
        closeButton.frame = NSRect(
            x: margin,
            y: bounds.maxY - controlSize - margin,
            width: controlSize,
            height: controlSize
        )
        closeButton.layer?.cornerRadius = controlSize / 2
        resizeHandle.frame = NSRect(
            x: bounds.maxX - controlSize - margin,
            y: bounds.maxY - controlSize - margin,
            width: controlSize,
            height: controlSize
        )
        settingsButton.frame = resizeHandle.frame.offsetBy(dx: -controlSize - 6, dy: 0)
        settingsButton.layer?.cornerRadius = controlSize / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard controlsEnabled else { return }
        isPointerInside = true
        setControlsVisible(true)
        updateInteractionScale()
    }

    override func mouseDown(with event: NSEvent) {
        if controlsEnabled { setControlsVisible(true) }
        isBodyPressed = true
        updateInteractionScale(pressed: true)
        onMoveBegan?(dragSample(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        onMoveDragged?(dragSample(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        isBodyPressed = false
        isPointerInside = bounds.contains(convert(event.locationInWindow, from: nil))
        updateInteractionScale()
        onMoveEnded?(dragSample(for: event))
    }

    override func mouseMoved(with event: NSEvent) {
        guard controlsEnabled else { return }
        setControlsVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        guard !resizeHandle.isDragging else { return }
        setControlsVisible(false)
        if !isBodyPressed { updateInteractionScale() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if controlsVisible, closeButton.frame.contains(point) { return closeButton }
        if controlsVisible, settingsButton.frame.contains(point) { return settingsButton }
        if controlsVisible, resizeHandle.frame.contains(point) { return resizeHandle }
        return self
    }

    func hideControls() {
        setControlsVisible(false, animated: false)
        isPointerInside = false
        isBodyPressed = false
        updateInteractionScale(animated: false)
    }

    @objc private func closePet() {
        setControlsVisible(false, animated: false)
        onClose?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    private func setControlsVisible(_ visible: Bool, animated: Bool = true) {
        guard controlsVisible != visible || !animated else { return }
        controlsVisible = visible

        if visible {
            closeButton.isHidden = false
            settingsButton.isHidden = false
            resizeHandle.isHidden = false
            window?.invalidateCursorRects(for: resizeHandle)
        }

        let changes = { [weak self] in
            self?.closeButton.alphaValue = visible ? 1 : 0
            self?.settingsButton.alphaValue = visible ? 1 : 0
            self?.resizeHandle.alphaValue = visible ? 1 : 0
        }
        let completion = { [weak self] in
            guard let self, !self.controlsVisible else { return }
            self.closeButton.isHidden = true
            self.settingsButton.isHidden = true
            self.resizeHandle.isHidden = true
        }

        guard animated else {
            changes()
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            closeButton.animator().alphaValue = visible ? 1 : 0
            settingsButton.animator().alphaValue = visible ? 1 : 0
            resizeHandle.animator().alphaValue = visible ? 1 : 0
        } completionHandler: {
            completion()
        }
    }

    private func updateInteractionScale(pressed: Bool? = nil, animated: Bool = true) {
        let targetScale: CGFloat
        if pressed ?? isBodyPressed {
            targetScale = 0.94
        } else if isPointerInside, controlsEnabled {
            targetScale = 1.025
        } else {
            targetScale = 1
        }
        animateImageScale(to: targetScale, animated: animated)
    }

    private func animateImageScale(to targetScale: CGFloat, animated: Bool) {
        guard let imageLayer = petImageView?.layer else { return }
        imageLayer.removeAnimation(forKey: "interactionScale")
        let currentScale = (imageLayer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat)
            ?? (imageLayer.value(forKeyPath: "transform.scale") as? CGFloat)
            ?? 1
        imageLayer.setValue(targetScale, forKeyPath: "transform.scale")
        guard animated else { return }

        let animation = CASpringAnimation(keyPath: "transform.scale")
        animation.fromValue = currentScale
        animation.toValue = targetScale
        animation.mass = 0.75
        animation.stiffness = targetScale < currentScale ? 360 : 220
        animation.damping = targetScale < currentScale ? 22 : 15
        animation.initialVelocity = 0
        animation.duration = animation.settlingDuration
        imageLayer.add(animation, forKey: "interactionScale")
    }

    private func screenLocation(for event: NSEvent) -> NSPoint {
        guard let window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func dragSample(for event: NSEvent) -> PetDragSample {
        PetDragSample(point: screenLocation(for: event), timestamp: event.timestamp)
    }
}

@MainActor
private final class PetController: NSObject, NSWindowDelegate {
    private let library: PetImageLibrary
    private let packStore: PetPackStore
    private var playback = PresetPlaybackCursor()
    private let panel: PetPanel
    var todoAnchorWindow: NSWindow { panel }
    var shouldHoldPosition: (() -> Bool)?
    var onPresentationChanged: (() -> Void)?
    private let contentView: PetContentView
    private let imageView: NSImageView
    private let onScaleChanged: (CGFloat) -> Void
    private var baseSize: NSSize
    private var idleWorkItem: DispatchWorkItem?
    private var resizeInitialMouseLocation: NSPoint?
    private var resizeInitialFrame: NSRect?
    private var resizeInitialScale: CGFloat?
    private var moveInitialMouseLocation: NSPoint?
    private var moveInitialFrame: NSRect?
    private var moveSamples: [PetDragSample] = []
    private var inertiaTimer: Timer?
    private var inertiaVelocity: CGVector = .zero
    private var inertiaLastTimestamp: TimeInterval?
    private var inertiaBounds: NSRect?
    private var avoidanceTimer: Timer?
    private var avoidanceVelocity: CGVector = .zero
    private var avoidanceLastTimestamp: TimeInterval?
    private var avoidanceBounds: NSRect?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var cachedRestingOpacity = PetController.savedRestingOpacity
    private var cachedHoverOpacity = PetController.savedHoverOpacity
    private var cachedAvoidsPointerWhenLocked = PetController.savedAvoidsPointerWhenLocked
    private var cachedShakeLevel = PetController.savedShakeLevel

    init(
        library: PetImageLibrary,
        packStore: PetPackStore,
        onScaleChanged: @escaping (CGFloat) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.library = library
        self.packStore = packStore
        self.onScaleChanged = onScaleChanged
        let initialImage = packStore.idleURL.flatMap { library.image(for: $0) }
        baseSize = Self.normalizedBaseSize(for: initialImage?.size ?? PetConstants.fallbackBaseSize)
        panel = PetPanel(
            contentRect: NSRect(
                origin: .zero,
                size: Self.scaledSize(baseSize: baseSize, scale: Self.savedScale)
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        imageView = NSImageView(frame: NSRect(origin: .zero, size: panel.frame.size))
        contentView = PetContentView(frame: NSRect(origin: .zero, size: panel.frame.size))
        super.init()

        imageView.autoresizingMask = []
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.wantsLayer = true
        contentView.petImageView = imageView
        contentView.addSubview(imageView, positioned: .below, relativeTo: nil)
        contentView.onClose = { [weak self] in self?.hidePet() }
        contentView.onOpenSettings = onOpenSettings
        contentView.onResizeBegan = { [weak self] in self?.beginResize(at: $0) }
        contentView.onResizeDragged = { [weak self] in self?.continueResize(at: $0) }
        contentView.onResizeEnded = { [weak self] in self?.endResize() }
        contentView.onMoveBegan = { [weak self] in self?.beginMove(with: $0) }
        contentView.onMoveDragged = { [weak self] in self?.continueMove(with: $0) }
        contentView.onMoveEnded = { [weak self] in self?.endMove(with: $0) }

        panel.title = AppEnvironment.displayName + L(" · Pet")
        panel.contentView = contentView
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = Self.savedAlwaysOnTop ? .floating : .normal
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = Self.savedPositionLocked
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView.controlsEnabled = !Self.savedPositionLocked

        let restoredPosition = panel.setFrameUsingName(AppEnvironment.frameAutosaveName)
        resizePanelForCurrentCanvas(animate: false)
        if !restoredPosition {
            resetPosition()
        }

        showIdleImage()
        panel.orderFrontRegardless()
        updateMouseMonitoringState()
        updatePetOpacity()
        updatePointerAvoidance()
    }

    var isAlwaysOnTop: Bool {
        get { panel.level == .floating }
        set {
            panel.level = newValue ? .floating : .normal
            onPresentationChanged?()
            AppEnvironment.defaults.set(newValue, forKey: "alwaysOnTop")
        }
    }

    var isPositionLocked: Bool {
        get { panel.ignoresMouseEvents }
        set {
            if newValue { stopInertia(savePosition: true) }
            panel.ignoresMouseEvents = newValue
            contentView.controlsEnabled = !newValue
            AppEnvironment.defaults.set(newValue, forKey: "positionLocked")
            updateMouseMonitoringState()
            if newValue {
                updatePointerAvoidance()
            } else {
                stopPointerAvoidance(savePosition: true)
            }
        }
    }

    var isPetVisible: Bool { panel.isVisible }

    var scale: CGFloat {
        get { Self.savedScale }
        set { applyScale(newValue, anchorOrigin: nil, animate: true) }
    }

    var restingOpacity: CGFloat {
        get { cachedRestingOpacity }
        set {
            let clamped = min(max(newValue, 0), 1)
            cachedRestingOpacity = clamped
            AppEnvironment.defaults.set(Double(clamped), forKey: "restingOpacity")
            updateMouseMonitoringState()
            updatePetOpacity()
        }
    }

    var hoverOpacity: CGFloat {
        get { cachedHoverOpacity }
        set {
            let clamped = min(max(newValue, 0), 1)
            cachedHoverOpacity = clamped
            AppEnvironment.defaults.set(Double(clamped), forKey: "hoverOpacity")
            updateMouseMonitoringState()
            updatePetOpacity()
        }
    }

    var avoidsPointerWhenLocked: Bool {
        get { cachedAvoidsPointerWhenLocked }
        set {
            cachedAvoidsPointerWhenLocked = newValue
            AppEnvironment.defaults.set(newValue, forKey: "avoidsPointerWhenLocked")
            updateMouseMonitoringState()
            if newValue {
                updatePointerAvoidance()
            } else {
                stopPointerAvoidance(savePosition: true)
            }
        }
    }

    var shakeLevel: Int {
        get { cachedShakeLevel }
        set {
            let clamped = max(0, min(newValue, 3))
            cachedShakeLevel = clamped
            AppEnvironment.defaults.set(clamped, forKey: "shakeLevel")
        }
    }

    func handleKeystroke(_ stroke: KeyStroke? = nil) {
        let set = library.activeSet
        let pack = packStore.rawConfiguration(for: set)
        guard let id = playback.reaction(for: stroke, in: pack),
              let chosenURL = packStore.imageURL(id: id, in: pack, set: set) else { return }

        idleWorkItem?.cancel()
        showImage(at: chosenURL)
        bounce()

        let workItem = DispatchWorkItem { [weak self] in
            self?.showIdleImage()
        }
        idleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + PetConstants.idleDelay, execute: workItem)
    }

    func reloadImages() {
        idleWorkItem?.cancel()
        playback = PresetPlaybackCursor()
        if let idleImage = packStore.idleURL.flatMap({ library.image(for: $0) }) {
            baseSize = Self.normalizedBaseSize(for: idleImage.size)
        } else {
            baseSize = PetConstants.fallbackBaseSize
        }
        resizePanelForCurrentCanvas(animate: true)
        showIdleImage()
    }

    func hidePet() {
        stopInertia(savePosition: true)
        stopPointerAvoidance(savePosition: true)
        contentView.hideControls()
        panel.orderOut(nil)
        onPresentationChanged?()
        updateMouseMonitoringState()
    }

    func showPet() {
        contentView.hideControls()
        panel.orderFrontRegardless()
        onPresentationChanged?()
        updateMouseMonitoringState()
        updatePetOpacity()
        updatePointerAvoidance()
    }

    func togglePetVisibility() {
        isPetVisible ? hidePet() : showPet()
    }

    func resetPosition() {
        stopInertia(savePosition: false)
        stopPointerAvoidance(savePosition: false)
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.minY + 24
        )
        panel.setFrameOrigin(origin)
        panel.saveFrame(usingName: AppEnvironment.frameAutosaveName)
    }

    func windowDidMove(_ notification: Notification) {
        panel.saveFrame(usingName: AppEnvironment.frameAutosaveName)
    }

    private func showIdleImage() {
        let set = library.activeSet
        let pack = packStore.rawConfiguration(for: set)
        guard let id = playback.idle(in: pack),
              let idleURL = packStore.imageURL(id: id, in: pack, set: set) else { return }
        showImage(at: idleURL)
    }

    private func showImage(at url: URL) {
        guard let image = library.image(for: url) else { return }
        if imageView.image === image, url.pathExtension.caseInsensitiveCompare("gif") != .orderedSame { return }
        imageView.image = nil
        imageView.image = image
    }

    private func resizePanelForCurrentCanvas(animate: Bool) {
        let oldFrame = panel.frame
        let newSize = Self.scaledSize(baseSize: baseSize, scale: Self.savedScale)
        let newOrigin = NSPoint(
            x: oldFrame.midX - newSize.width / 2,
            y: oldFrame.minY
        )
        panel.setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: animate)
        panel.saveFrame(usingName: AppEnvironment.frameAutosaveName)
    }

    private func beginResize(at mouseLocation: NSPoint) {
        stopInertia(savePosition: true)
        resizeInitialMouseLocation = mouseLocation
        resizeInitialFrame = panel.frame
        resizeInitialScale = scale
    }

    private func beginMove(with sample: PetDragSample) {
        stopInertia(savePosition: false)
        moveInitialMouseLocation = sample.point
        moveInitialFrame = panel.frame
        moveSamples = [sample]
    }

    private func continueMove(with sample: PetDragSample) {
        guard let initialMouse = moveInitialMouseLocation,
              let initialFrame = moveInitialFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: initialFrame.origin.x + sample.point.x - initialMouse.x,
            y: initialFrame.origin.y + sample.point.y - initialMouse.y
        ))
        appendMoveSample(sample)
    }

    private func endMove(with sample: PetDragSample) {
        appendMoveSample(sample)
        let velocity = PetMotionPhysics.releaseVelocity(samples: moveSamples)
        moveInitialMouseLocation = nil
        moveInitialFrame = nil
        moveSamples.removeAll()
        startInertia(with: velocity)
    }

    private func appendMoveSample(_ sample: PetDragSample) {
        moveSamples.append(sample)
        let cutoff = sample.timestamp - 0.15
        moveSamples.removeAll { $0.timestamp < cutoff }
    }

    private func startInertia(with velocity: CGVector) {
        let speed = hypot(velocity.dx, velocity.dy)
        guard speed >= 45 else {
            panel.saveFrame(usingName: AppEnvironment.frameAutosaveName)
            return
        }
        inertiaVelocity = velocity
        inertiaLastTimestamp = ProcessInfo.processInfo.systemUptime
        inertiaBounds = (panel.screen ?? NSScreen.main)?.visibleFrame
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceInertia() }
        }
        inertiaTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceInertia() {
        guard let lastTimestamp = inertiaLastTimestamp else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(max(now - lastTimestamp, 1.0 / 240.0), 1.0 / 30.0)
        inertiaLastTimestamp = now
        let visibleFrame = inertiaBounds ?? panel.frame
        let step = PetMotionPhysics.advance(
            origin: panel.frame.origin,
            size: panel.frame.size,
            velocity: inertiaVelocity,
            elapsed: elapsed,
            bounds: visibleFrame
        )
        inertiaVelocity = step.velocity
        panel.setFrameOrigin(step.origin)
        updatePetOpacity()
        if hypot(step.velocity.dx, step.velocity.dy) < 18 {
            stopInertia(savePosition: true)
        }
    }

    private func stopInertia(savePosition: Bool) {
        inertiaTimer?.invalidate()
        inertiaTimer = nil
        inertiaVelocity = .zero
        inertiaLastTimestamp = nil
        inertiaBounds = nil
        if savePosition { panel.saveFrame(usingName: AppEnvironment.frameAutosaveName) }
    }

    private func updateMouseMonitoringState() {
        let needsMonitoring = panel.isVisible && (
            abs(cachedRestingOpacity - cachedHoverOpacity) > 0.001 ||
            (isPositionLocked && cachedAvoidsPointerWhenLocked)
        )
        needsMonitoring ? startMouseHoverMonitoring() : stopMouseHoverMonitoring()
    }

    private func startMouseHoverMonitoring() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePointerMotion() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.handlePointerMotion() }
            return event
        }
    }

    private func stopMouseHoverMonitoring() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
    }

    private func handlePointerMotion() {
        updatePetOpacity()
        updatePointerAvoidance()
    }

    private func updatePetOpacity() {
        guard panel.isVisible, let imageLayer = imageView.layer else { return }
        let targetOpacity = PetOpacityBehavior.opacity(
            isHovering: panel.frame.contains(NSEvent.mouseLocation),
            restingOpacity: cachedRestingOpacity,
            hoverOpacity: cachedHoverOpacity
        )
        guard abs(CGFloat(imageLayer.opacity) - targetOpacity) > 0.001 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.opacity = Float(targetOpacity)
        CATransaction.commit()
    }

    private func updatePointerAvoidance() {
        if shouldHoldPosition?() == true {
            stopPointerAvoidance(savePosition: true)
            return
        }
        guard avoidanceTimer == nil, panel.isVisible, isPositionLocked, avoidsPointerWhenLocked else { return }
        let bounds = avoidanceBounds ?? (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        guard PetPointerAvoidance.targetOrigin(
            mouseLocation: NSEvent.mouseLocation,
            petFrame: panel.frame,
            bounds: bounds
        ) != nil else { return }
        startPointerAvoidance(in: bounds)
    }

    private func startPointerAvoidance(in bounds: NSRect) {
        guard avoidanceTimer == nil else { return }
        avoidanceBounds = bounds
        avoidanceLastTimestamp = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advancePointerAvoidance() }
        }
        avoidanceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advancePointerAvoidance() {
        if shouldHoldPosition?() == true {
            stopPointerAvoidance(savePosition: true)
            return
        }
        guard panel.isVisible, isPositionLocked, avoidsPointerWhenLocked,
              let lastTimestamp = avoidanceLastTimestamp else {
            stopPointerAvoidance(savePosition: true)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = CGFloat(min(max(now - lastTimestamp, 1.0 / 240.0), 1.0 / 30.0))
        avoidanceLastTimestamp = now
        let bounds = avoidanceBounds ?? panel.frame
        let origin = panel.frame.origin
        let target = PetPointerAvoidance.targetOrigin(
            mouseLocation: NSEvent.mouseLocation,
            petFrame: panel.frame,
            bounds: bounds
        )
        let delta = CGVector(
            dx: (target?.x ?? origin.x) - origin.x,
            dy: (target?.y ?? origin.y) - origin.y
        )
        let stiffness: CGFloat = target == nil ? 0 : 58
        let damping: CGFloat = target == nil ? 16 : 13
        avoidanceVelocity.dx += (delta.dx * stiffness - avoidanceVelocity.dx * damping) * elapsed
        avoidanceVelocity.dy += (delta.dy * stiffness - avoidanceVelocity.dy * damping) * elapsed

        let speed = hypot(avoidanceVelocity.dx, avoidanceVelocity.dy)
        if speed > 520 {
            let factor = 520 / speed
            avoidanceVelocity.dx *= factor
            avoidanceVelocity.dy *= factor
        }
        let proposedOrigin = CGPoint(
            x: origin.x + avoidanceVelocity.dx * elapsed,
            y: origin.y + avoidanceVelocity.dy * elapsed
        )
        let nextOrigin = PetPointerAvoidance.clampedOrigin(
            proposedOrigin,
            size: panel.frame.size,
            bounds: bounds
        )
        if nextOrigin.x != proposedOrigin.x { avoidanceVelocity.dx = 0 }
        if nextOrigin.y != proposedOrigin.y { avoidanceVelocity.dy = 0 }
        panel.setFrameOrigin(nextOrigin)
        updatePetOpacity()

        if target == nil, hypot(avoidanceVelocity.dx, avoidanceVelocity.dy) < 5 {
            stopPointerAvoidance(savePosition: true)
        }
    }

    private func stopPointerAvoidance(savePosition: Bool) {
        avoidanceTimer?.invalidate()
        avoidanceTimer = nil
        avoidanceVelocity = .zero
        avoidanceLastTimestamp = nil
        avoidanceBounds = nil
        if savePosition { panel.saveFrame(usingName: AppEnvironment.frameAutosaveName) }
    }

    private func continueResize(at mouseLocation: NSPoint) {
        guard let initialMouse = resizeInitialMouseLocation,
              let initialFrame = resizeInitialFrame,
              let initialScale = resizeInitialScale else { return }
        let delta = NSPoint(
            x: mouseLocation.x - initialMouse.x,
            y: mouseLocation.y - initialMouse.y
        )
        let newScale = PetResizeGeometry.scale(
            initialScale: initialScale,
            initialSize: initialFrame.size,
            dragDelta: delta
        )
        applyScale(newScale, anchorOrigin: initialFrame.origin, animate: false)
    }

    private func endResize() {
        resizeInitialMouseLocation = nil
        resizeInitialFrame = nil
        resizeInitialScale = nil
        panel.saveFrame(usingName: AppEnvironment.frameAutosaveName)
    }

    private func applyScale(_ value: CGFloat, anchorOrigin: NSPoint?, animate: Bool) {
        let clamped = max(0.35, min(value, 1.25))
        let oldFrame = panel.frame
        let newSize = Self.scaledSize(baseSize: baseSize, scale: clamped)
        let newOrigin = anchorOrigin ?? NSPoint(
            x: oldFrame.midX - newSize.width / 2,
            y: oldFrame.minY
        )
        panel.setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: animate)
        AppEnvironment.defaults.set(Double(clamped), forKey: "petScale")
        onScaleChanged(clamped)
        if animate { panel.saveFrame(usingName: AppEnvironment.frameAutosaveName) }
    }

    private func bounce() {
        let amplitudes: [CGFloat] = [0, 4, 9, 15]
        let amplitude = amplitudes[shakeLevel]
        guard amplitude > 0 else { return }
        guard let layer = imageView.layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        animation.values = [0, amplitude, 0]
        animation.keyTimes = [0, 0.42, 1]
        animation.duration = 0.16
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "typingBounce")
    }

    private static func scaledSize(baseSize: NSSize, scale: CGFloat) -> NSSize {
        NSSize(
            width: baseSize.width * scale,
            height: baseSize.height * scale
        )
    }

    private static func normalizedBaseSize(for imageSize: NSSize) -> NSSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return PetConstants.fallbackBaseSize
        }

        let longestSide: CGFloat = 453
        if imageSize.width >= imageSize.height {
            return NSSize(
                width: longestSide,
                height: longestSide * imageSize.height / imageSize.width
            )
        }
        return NSSize(
            width: longestSide * imageSize.width / imageSize.height,
            height: longestSide
        )
    }

    private static var savedScale: CGFloat {
        let value = AppEnvironment.defaults.double(forKey: "petScale")
        return value > 0 ? CGFloat(value) : 0.62
    }

    private static var savedRestingOpacity: CGFloat {
        guard let value = AppEnvironment.defaults.object(forKey: "restingOpacity") as? Double else {
            return 1
        }
        return min(max(CGFloat(value), 0), 1)
    }

    private static var savedHoverOpacity: CGFloat {
        guard let value = AppEnvironment.defaults.object(forKey: "hoverOpacity") as? Double else {
            return 0.3
        }
        return min(max(CGFloat(value), 0), 1)
    }

    private static var savedAvoidsPointerWhenLocked: Bool {
        AppEnvironment.defaults.bool(forKey: "avoidsPointerWhenLocked")
    }

    private static var savedAlwaysOnTop: Bool {
        if AppEnvironment.defaults.object(forKey: "alwaysOnTop") == nil {
            return true
        }
        return AppEnvironment.defaults.bool(forKey: "alwaysOnTop")
    }

    private static var savedPositionLocked: Bool {
        AppEnvironment.defaults.bool(forKey: "positionLocked")
    }

    private static var savedShakeLevel: Int {
        let stored = AppEnvironment.defaults.object(forKey: "shakeLevel") as? Int
        return max(0, min(stored ?? 2, 3))
    }
}

private final class GlobalKeyMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let handler: (KeyStroke) -> Void

    init(handler: @escaping (KeyStroke) -> Void) {
        self.handler = handler
    }

    var isRunning: Bool {
        eventTap != nil
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        stop()

        guard CGPreflightListenEventAccess() else {
            return false
        }

        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let callback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<GlobalKeyMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
                if let tap = monitor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            } else if eventType == .keyDown {
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                monitor.handler(KeyStroke(keyCode: keyCode, modifiers: KeyModifiers(eventFlags: event.flags)))
            }

            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let imageLibrary = PetImageLibrary()
    private let keyReactionStore = KeyReactionStore()
    private lazy var packStore: PetPackStore = {
        let store = PetPackStore(library: imageLibrary, keyStore: keyReactionStore)
        store.applyBuiltInKeyboardDefaultsIfNeeded()
        return store
    }()
    private let todoStore: TodoStore = {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["TYPINGPET_TODO_TEST_PATH"] {
            return TodoStore(url: URL(fileURLWithPath: path))
        }
        #endif
        return TodoStore()
    }()
    private var todoBubble: TodoBubbleWindowController?
    private var statusItem: NSStatusItem!
    private var petController: PetController!
    private var keyMonitor: GlobalKeyMonitor!
    private var menu: NSMenu!
    private var petVisibilityItem: NSMenuItem!
    private var positionLockedItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var monitoringStatusItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private let updater = UpdateController()
    private var permissionRetryTimer: Timer?
    private static let inputMonitoringWelcomeShownKey = "inputMonitoringWelcomeShown-v1"
    private static let inputMonitoringSetupPendingKey = "inputMonitoringSetupPending-v1"
    private var settingsWindowController: SettingsWindowController?
    private var settingsModel: TypingPetSettingsModel?
    private var inputMonitoringGuideController: InputMonitoringGuideController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TextEditingShortcuts.installEditMenu(appName: AppEnvironment.displayName)
        BackgroundCursor.enable()
        petController = PetController(
            library: imageLibrary,
            packStore: packStore,
            onScaleChanged: { [weak self] scale in self?.settingsModel?.syncScale(scale) },
            onOpenSettings: { [weak self] in self?.showSettings() }
        )
        todoBubble = TodoBubbleWindowController(store: todoStore, pet: petController.todoAnchorWindow)
        petController.shouldHoldPosition = { [weak self] in self?.todoBubble?.isInteracting == true }
        petController.onPresentationChanged = { [weak self] in self?.todoBubble?.synchronize() }
        configureStatusItem()
        updater.isTimerRunning = { [weak self] in self?.todoStore.engine.activeSession?.status == .running }
        updater.onChange = { [weak self] in self?.updateUpdateItem() }
        updater.start()

        keyMonitor = GlobalKeyMonitor { [weak self] stroke in
            DispatchQueue.main.async {
                self?.petController.handleKeystroke(stroke)
                self?.inputMonitoringGuideController?.receivedGlobalKeystroke()
            }
        }

        let shouldShowWelcome = !AppEnvironment.isDevelopment
            && !AppEnvironment.defaults.bool(forKey: Self.inputMonitoringWelcomeShownKey)
        let shouldResumeSetup = !AppEnvironment.isDevelopment
            && AppEnvironment.defaults.bool(forKey: Self.inputMonitoringSetupPendingKey)
        #if DEBUG
        if !ProcessInfo.processInfo.arguments.contains("--todo-preview"),
           !ProcessInfo.processInfo.arguments.contains("--input-guide-preview") {
            startMonitoring(showGuideIfNeeded: shouldShowWelcome)
            if shouldResumeSetup { showInputMonitoringGuide() }
        }
        if ProcessInfo.processInfo.arguments.contains("--show-todos") { showTodos() }
        if ProcessInfo.processInfo.arguments.contains("--install-update-now") { updater.installNowForChecks() }
        if ProcessInfo.processInfo.arguments.contains("--show-input-guide") { showInputMonitoringGuide() }
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--input-guide-preview"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1),
           let phase = InputMonitoringGuideModel.Phase(rawValue: ProcessInfo.processInfo.arguments[index + 1]) {
            inputMonitoringGuideController = .preview(
                phase: phase, idleURL: packStore.idleURL, reactionURLs: imageLibrary.reactionURLs
            )
            inputMonitoringGuideController?.show()
        }
        #else
        startMonitoring(showGuideIfNeeded: shouldShowWelcome)
        if shouldResumeSetup { showInputMonitoringGuide() }
        #endif

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--show-settings") {
            DispatchQueue.main.async { [weak self] in self?.showSettings() }
        }
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        todoStore.pauseForSleepOrTermination()
        guard let error = todoStore.errorMessage, !todoStore.loadBlocked else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("Could not save Todo records")
        alert.informativeText = error
        alert.addButton(withTitle: L("Save Again"))
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Quit Without Saving"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            todoStore.persist()
            return todoStore.errorMessage == nil ? .terminateNow : .terminateCancel
        case .alertThirdButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionRetryTimer?.invalidate()
        keyMonitor.stop()
        updater.applicationWillTerminate()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        retryMonitoringIfAuthorized()
        settingsModel?.refresh()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !petController.isPetVisible {
            petController.showPet()
        }
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        petVisibilityItem.title = petController.isPetVisible ? L("Hide Pet") : L("Show Pet Again")
        positionLockedItem.state = petController.isPositionLocked ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updateMonitoringStatusItem()
        updateUpdateItem()
    }

    @objc private func toggleAlwaysOnTop() {
        petController.isAlwaysOnTop.toggle()
    }

    @objc private func togglePetVisibility() {
        petController.togglePetVisibility()
    }

    @objc private func togglePositionLock() {
        petController.isPositionLocked.toggle()
    }

    @objc private func resetPosition() {
        petController.resetPosition()
    }

    @objc private func setSmallSize() {
        petController.scale = 0.46
    }

    @objc private func setMediumSize() {
        petController.scale = 0.62
    }

    @objc private func setLargeSize() {
        petController.scale = 0.82
    }

    @objc private func setExtraLargeSize() {
        petController.scale = 1.08
    }

    @objc private func changeIdleImage() {
        guard let url = chooseImageFiles(
            title: L("Choose Idle Image"),
            message: L("Choose the image shown when you are not typing."),
            allowsMultipleSelection: false
        )?.first else { return }

        do {
            try packStore.replaceIdle(with: url)
            petController.reloadImages()
            settingsModel?.refresh()
        } catch {
            showImageError(error)
        }
    }

    @objc private func replaceReactionImages() {
        guard let urls = chooseImageFiles(
            title: L("Choose Reaction Images"),
            message: L("Select one or more images to show randomly when you press a key."),
            allowsMultipleSelection: true
        ), !urls.isEmpty else { return }

        do {
            try packStore.replaceUnassigned(with: urls)
            petController.reloadImages()
            settingsModel?.refresh()
        } catch {
            showImageError(error)
        }
    }

    @objc private func importImageFolder() {
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        let panel = NSOpenPanel()
        panel.title = L("Import Image Folder")
        panel.message = L("idle.* or pet-idle.* is the idle image. Other files are imported as key reaction images.")
        panel.prompt = L("Import")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        do {
            let result = try imageLibrary.importFolder(folderURL)
            petController.reloadImages()

            var parts: [String] = []
            if result.changedIdle {
                parts.append(L("1 idle image"))
            }
            if let reactionCount = result.reactionCount {
                parts.append(L("%1$@ reaction images", reactionCount))
            }
            showAlert(
                title: L("Images Imported"),
                message: parts.joined(separator: ", ") + L(" were applied."),
                primaryButton: L("OK")
            )
        } catch {
            showImageError(error)
        }
    }

    @objc private func showImageFolderRules() {
        showAlert(
            title: L("Image Set Folder Rules"),
            message: L("File names are flexible. idle.* or pet-idle.* is used as the idle image; other files become key reaction images. Without an idle image, the first sorted image is used. A single image is used for both idle and reactions. PNG, APNG, JPG, GIF, TIFF, HEIC, and WebP are supported."),
            primaryButton: L("OK")
        )
    }

    @objc private func resetImages() {
        showAlert(
            title: L("Restore default images?"),
            message: L("Reset your idle and reaction image selections to the defaults. Original image files will not be changed."),
            primaryButton: L("Restore"),
            secondaryButton: L("Cancel")
        ) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            guard let self else { return }
            do {
                try self.packStore.resetToDefaults()
                self.petController.reloadImages()
                self.settingsModel?.refresh()
            } catch { self.showImageError(error) }
        }
    }

    @objc private func restartMonitoring() {
        startMonitoring(showGuideIfNeeded: true)
    }

    @objc private func previewReaction() {
        petController.handleKeystroke(nil)
    }

    @objc private func showTodos() {
        petController.showPet()
        todoBubble?.show()
    }

    @objc private func showSettings() {
        if settingsModel == nil {
            settingsModel = TypingPetSettingsModel(
                library: imageLibrary,
                keyStore: keyReactionStore,
                packStore: packStore,
                scale: petController.scale,
                restingOpacity: petController.restingOpacity,
                hoverOpacity: petController.hoverOpacity,
                shakeLevel: petController.shakeLevel,
                alwaysOnTop: petController.isAlwaysOnTop,
                positionLocked: petController.isPositionLocked,
                avoidsPointerWhenLocked: petController.avoidsPointerWhenLocked,
                applyScale: { [weak self] in self?.petController.scale = $0 },
                applyRestingOpacity: { [weak self] in self?.petController.restingOpacity = $0 },
                applyHoverOpacity: { [weak self] in self?.petController.hoverOpacity = $0 },
                applyShake: { [weak self] in self?.petController.shakeLevel = $0 },
                applyAlwaysOnTop: { [weak self] in self?.petController.isAlwaysOnTop = $0 },
                applyPositionLock: { [weak self] in self?.petController.isPositionLocked = $0 },
                applyPointerAvoidance: { [weak self] in self?.petController.avoidsPointerWhenLocked = $0 },
                applyAppearance: { [weak self] in self?.todoBubble?.setAppearanceMode($0) },
                reloadPet: { [weak self] in self?.petController.reloadImages() },
                openInputMonitoringSettings: { [weak self] in self?.openInputMonitoringSettings() },
                monitoringIsRunning: { [weak self] in self?.keyMonitor?.isRunning == true },
                retryMonitoring: { [weak self] in _ = self?.connectMonitoring(restart: true) }
            )
        }
        settingsModel?.refresh()
        if settingsWindowController == nil, let settingsModel {
            settingsWindowController = SettingsWindowController(model: settingsModel, todoStore: todoStore, updater: updater)
        }
        settingsWindowController?.show()
    }

    @objc private func openInputMonitoringSettings() {
        if CGPreflightListenEventAccess(), keyMonitor.isRunning {
            InputMonitoringSettings.open()
        } else {
            showInputMonitoringGuide()
        }
    }

    private func showInputMonitoringGuide() {
        AppEnvironment.defaults.set(true, forKey: Self.inputMonitoringWelcomeShownKey)
        if inputMonitoringGuideController == nil {
            inputMonitoringGuideController = InputMonitoringGuideController(
                idleURL: packStore.idleURL,
                reactionURLs: imageLibrary.reactionURLs,
                resumeSetup: AppEnvironment.defaults.bool(forKey: Self.inputMonitoringSetupPendingKey),
                onSetupStarted: {
                    AppEnvironment.defaults.set(true, forKey: Self.inputMonitoringSetupPendingKey)
                },
                onDismiss: {
                    AppEnvironment.defaults.set(false, forKey: Self.inputMonitoringSetupPendingKey)
                }
            ) { [weak self] restart in
                let connected = self?.connectMonitoring(restart: restart) ?? false
                self?.settingsModel?.refresh()
                return connected
            }
        }
        inputMonitoringGuideController?.show()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert(
                title: L("Could not change launch at login"),
                message: error.localizedDescription,
                primaryButton: L("OK")
            )
        }
    }

    @objc private func performUpdateAction() {
        updater.performPrimaryAction()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: AppEnvironment.isDevelopment ? NSStatusItem.variableLength : NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: AppEnvironment.isDevelopment ? "flask.fill" : "pawprint.fill", accessibilityDescription: AppEnvironment.displayName)
            image?.isTemplate = true
            button.image = image
            button.toolTip = AppEnvironment.displayName
            if AppEnvironment.isDevelopment {
                button.title = " DEV"
                button.imagePosition = .imageLeading
            }
        }

        menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        menu.addItem(makeMenuItem(L("Show Todos"), action: #selector(showTodos)))
        menu.addItem(makeMenuItem(L("Settings"), action: #selector(showSettings), keyEquivalent: ","))
        petVisibilityItem = makeMenuItem(L("Hide Pet"), action: #selector(togglePetVisibility))
        menu.addItem(petVisibilityItem)
        menu.addItem(.separator())

        positionLockedItem = makeMenuItem(L("Lock position (click through)"), action: #selector(togglePositionLock))
        menu.addItem(positionLockedItem)
        menu.addItem(makeMenuItem(L("Reset Position"), action: #selector(resetPosition)))
        menu.addItem(.separator())
        monitoringStatusItem = NSMenuItem(title: L("Key detection (checking)"), action: nil, keyEquivalent: "")
        monitoringStatusItem.isEnabled = true
        menu.addItem(monitoringStatusItem)
        updateMonitoringStatusItem()
        menu.addItem(makeMenuItem(L("Input Monitoring Settings"), action: #selector(openInputMonitoringSettings)))
        menu.addItem(.separator())

        loginItem = makeMenuItem(L("Launch at login"), action: #selector(toggleLaunchAtLogin))
        menu.addItem(loginItem)
        updateItem = makeMenuItem(L("Check for Updates…"), action: #selector(performUpdateAction))
        menu.addItem(updateItem)
        updateUpdateItem()
        menu.addItem(makeMenuItem(L("Quit %1$@", AppEnvironment.displayName), action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func updateMonitoringStatusItem() {
        let isAvailable = keyMonitor?.isRunning == true
        let title = isAvailable ? L("Key detection (available)") : L("Key detection (unavailable)")
        monitoringStatusItem.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: isAvailable ? NSColor.systemGreen : NSColor.systemRed
            ]
        )
    }

    private func updateUpdateItem() {
        guard let updateItem else { return }
        updateItem.title = updater.menuTitle
        updateItem.isEnabled = !updater.isBusy
    }

    private func makeMenuItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func chooseImageFiles(
        title: String,
        message: String,
        allowsMultipleSelection: Bool
    ) -> [URL]? {
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = L("Choose")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.allowedContentTypes = [.image]
        return panel.runModal() == .OK ? panel.urls : nil
    }

    private func showImageError(_ error: Error) {
        showAlert(
            title: L("Could not apply images"),
            message: error.localizedDescription,
            primaryButton: L("OK")
        )
    }

    private func startMonitoring(showGuideIfNeeded: Bool) {
        if connectMonitoring() { return }
        schedulePermissionRetry()
        if showGuideIfNeeded { showInputMonitoringGuide() }
    }

    @discardableResult
    private func connectMonitoring(restart: Bool = false) -> Bool {
        guard CGPreflightListenEventAccess() else { return false }
        if restart { keyMonitor.stop() }
        let connected = keyMonitor.isRunning || keyMonitor.start()
        if connected {
            permissionRetryTimer?.invalidate()
            permissionRetryTimer = nil
        } else {
            schedulePermissionRetry()
        }
        updateMonitoringStatusItem()
        return connected
    }

    private func schedulePermissionRetry() {
        guard permissionRetryTimer == nil else { return }
        permissionRetryTimer = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(retryMonitoringIfAuthorized),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func retryMonitoringIfAuthorized() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--todo-preview")
            || ProcessInfo.processInfo.arguments.contains("--input-guide-preview") { return }
        #endif
        connectMonitoring()
    }

    private func showAlert(
        title: String,
        message: String,
        primaryButton: String,
        secondaryButton: String? = nil,
        completion: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: primaryButton)
        if let secondaryButton {
            alert.addButton(withTitle: secondaryButton)
        }
        let response = alert.runModal()
        completion?(response)
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let runLock = DevelopmentRunLock()
    if AppEnvironment.isDevelopment {
        do {
            guard try runLock.acquire(at: AppEnvironment.supportDirectory.appendingPathComponent(".runtime.lock")) else {
                let alert = NSAlert()
                alert.messageText = L("TypingPet Dev is already running")
                alert.informativeText = L("Use the DEV app in the menu bar. Quit the existing Dev app before launching again.")
                alert.runModal()
                exit(0)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not start TypingPet Dev")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            exit(1)
        }
    }
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(runLock) { application.run() }
}
