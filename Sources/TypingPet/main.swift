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
            accessibilityDescription: "크기 조절"
        )?.withSymbolConfiguration(configuration)
        imageView.contentTintColor = .white
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)
        setAccessibilityLabel("펫 크기 조절")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
        imageView.frame = bounds.insetBy(dx: 9, dy: 9)
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        onResizeBegan?(screenLocation(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        onResizeDragged?(screenLocation(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        onResizeEnded?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private func screenLocation(for event: NSEvent) -> NSPoint {
        guard let window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
}

private final class PetContentView: NSView {
    var onClose: (() -> Void)?
    var onResizeBegan: ((NSPoint) -> Void)?
    var onResizeDragged: ((NSPoint) -> Void)?
    var onResizeEnded: (() -> Void)?
    var onMoveBegan: ((PetDragSample) -> Void)?
    var onMoveDragged: ((PetDragSample) -> Void)?
    var onMoveEnded: ((PetDragSample) -> Void)?
    weak var petImageView: NSView?

    private let closeButton: NSButton
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
        resizeHandle = PetResizeHandleView(frame: .zero)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        closeButton.isBordered = false
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "펫 숨기기"
        )?.withSymbolConfiguration(.init(pointSize: 18, weight: .semibold))
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .white
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        closeButton.target = self
        closeButton.action = #selector(closePet)
        closeButton.setAccessibilityLabel("펫 숨기기")

        resizeHandle.onResizeBegan = { [weak self] in self?.onResizeBegan?($0) }
        resizeHandle.onResizeDragged = { [weak self] in self?.onResizeDragged?($0) }
        resizeHandle.onResizeEnded = { [weak self] in self?.onResizeEnded?() }

        addSubview(closeButton)
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

    private func setControlsVisible(_ visible: Bool, animated: Bool = true) {
        guard controlsVisible != visible || !animated else { return }
        controlsVisible = visible

        if visible {
            closeButton.isHidden = false
            resizeHandle.isHidden = false
        }

        let changes = { [weak self] in
            self?.closeButton.alphaValue = visible ? 1 : 0
            self?.resizeHandle.alphaValue = visible ? 1 : 0
        }
        let completion = { [weak self] in
            guard let self, !self.controlsVisible else { return }
            self.closeButton.isHidden = true
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
    private let keyStore: KeyReactionStore
    private let panel: PetPanel
    private let contentView: PetContentView
    private let imageView: NSImageView
    private let onScaleChanged: (CGFloat) -> Void
    private var baseSize: NSSize
    private var currentImageKey = ""
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

    init(
        library: PetImageLibrary,
        keyStore: KeyReactionStore,
        onScaleChanged: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.library = library
        self.keyStore = keyStore
        self.onScaleChanged = onScaleChanged
        let initialImage = library.idleURL.flatMap(NSImage.init(contentsOf:))
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
        contentView.onResizeBegan = { [weak self] in self?.beginResize(at: $0) }
        contentView.onResizeDragged = { [weak self] in self?.continueResize(at: $0) }
        contentView.onResizeEnded = { [weak self] in self?.endResize() }
        contentView.onMoveBegan = { [weak self] in self?.beginMove(with: $0) }
        contentView.onMoveDragged = { [weak self] in self?.continueMove(with: $0) }
        contentView.onMoveEnded = { [weak self] in self?.endMove(with: $0) }

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

        let restoredPosition = panel.setFrameUsingName("TypingPetWindow")
        resizePanelForCurrentCanvas(animate: false)
        if !restoredPosition {
            resetPosition()
        }

        showIdleImage()
        panel.orderFrontRegardless()
        startMouseHoverMonitoring()
        updatePetOpacity()
        updatePointerAvoidance()
    }

    var isAlwaysOnTop: Bool {
        get { panel.level == .floating }
        set {
            panel.level = newValue ? .floating : .normal
            UserDefaults.standard.set(newValue, forKey: "alwaysOnTop")
        }
    }

    var isPositionLocked: Bool {
        get { panel.ignoresMouseEvents }
        set {
            if newValue { stopInertia(savePosition: true) }
            panel.ignoresMouseEvents = newValue
            contentView.controlsEnabled = !newValue
            UserDefaults.standard.set(newValue, forKey: "positionLocked")
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
        get { Self.savedRestingOpacity }
        set {
            UserDefaults.standard.set(Double(min(max(newValue, 0), 1)), forKey: "restingOpacity")
            updatePetOpacity()
        }
    }

    var hoverOpacity: CGFloat {
        get { Self.savedHoverOpacity }
        set {
            UserDefaults.standard.set(Double(min(max(newValue, 0), 1)), forKey: "hoverOpacity")
            updatePetOpacity()
        }
    }

    var avoidsPointerWhenLocked: Bool {
        get { Self.savedAvoidsPointerWhenLocked }
        set {
            UserDefaults.standard.set(newValue, forKey: "avoidsPointerWhenLocked")
            if newValue {
                updatePointerAvoidance()
            } else {
                stopPointerAvoidance(savePosition: true)
            }
        }
    }

    var shakeLevel: Int {
        get {
            let stored = UserDefaults.standard.object(forKey: "shakeLevel") as? Int
            return max(0, min(stored ?? 2, 3))
        }
        set { UserDefaults.standard.set(max(0, min(newValue, 3)), forKey: "shakeLevel") }
    }

    func handleKeystroke(_ stroke: KeyStroke? = nil) {
        let chosenURL: URL?
        if let stroke, let exactMatch = keyStore.imageURL(matching: stroke) {
            chosenURL = exactMatch
        } else {
            let reactions = library.reactionURLs
            let picker = ImagePicker(names: reactions.map(\.path))
            chosenURL = picker.next(excluding: currentImageKey).map(URL.init(fileURLWithPath:))
        }
        guard let chosenURL else { return }

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
        if let idleImage = library.idleURL.flatMap(NSImage.init(contentsOf:)) {
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
    }

    func showPet() {
        contentView.hideControls()
        panel.orderFrontRegardless()
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
        panel.saveFrame(usingName: "TypingPetWindow")
    }

    func windowDidMove(_ notification: Notification) {
        panel.saveFrame(usingName: "TypingPetWindow")
    }

    private func showIdleImage() {
        guard let idleURL = library.idleURL else { return }
        showImage(at: idleURL)
    }

    private func showImage(at url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        currentImageKey = url.path
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
        panel.saveFrame(usingName: "TypingPetWindow")
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
            panel.saveFrame(usingName: "TypingPetWindow")
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
        if savePosition { panel.saveFrame(usingName: "TypingPetWindow") }
    }

    private func startMouseHoverMonitoring() {
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

    private func handlePointerMotion() {
        updatePetOpacity()
        updatePointerAvoidance()
    }

    private func updatePetOpacity() {
        guard panel.isVisible, let imageLayer = imageView.layer else { return }
        let targetOpacity = PetOpacityBehavior.opacity(
            isHovering: panel.frame.contains(NSEvent.mouseLocation),
            restingOpacity: restingOpacity,
            hoverOpacity: hoverOpacity
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.opacity = Float(targetOpacity)
        CATransaction.commit()
    }

    private func updatePointerAvoidance() {
        guard panel.isVisible, isPositionLocked, avoidsPointerWhenLocked else { return }
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
        if savePosition { panel.saveFrame(usingName: "TypingPetWindow") }
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
        panel.saveFrame(usingName: "TypingPetWindow")
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
        UserDefaults.standard.set(Double(clamped), forKey: "petScale")
        onScaleChanged(clamped)
        if animate { panel.saveFrame(usingName: "TypingPetWindow") }
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
        let value = UserDefaults.standard.double(forKey: "petScale")
        return value > 0 ? CGFloat(value) : 0.62
    }

    private static var savedRestingOpacity: CGFloat {
        guard let value = UserDefaults.standard.object(forKey: "restingOpacity") as? Double else {
            return 1
        }
        return min(max(CGFloat(value), 0), 1)
    }

    private static var savedHoverOpacity: CGFloat {
        guard let value = UserDefaults.standard.object(forKey: "hoverOpacity") as? Double else {
            return 0.3
        }
        return min(max(CGFloat(value), 0), 1)
    }

    private static var savedAvoidsPointerWhenLocked: Bool {
        UserDefaults.standard.bool(forKey: "avoidsPointerWhenLocked")
    }

    private static var savedAlwaysOnTop: Bool {
        if UserDefaults.standard.object(forKey: "alwaysOnTop") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "alwaysOnTop")
    }

    private static var savedPositionLocked: Bool {
        UserDefaults.standard.bool(forKey: "positionLocked")
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
    private var statusItem: NSStatusItem!
    private var petController: PetController!
    private var keyMonitor: GlobalKeyMonitor!
    private var menu: NSMenu!
    private var petVisibilityItem: NSMenuItem!
    private var alwaysOnTopItem: NSMenuItem!
    private var positionLockedItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var monitoringStatusItem: NSMenuItem!
    private var reactionCountItem: NSMenuItem!
    private var resetImagesItem: NSMenuItem!
    private var permissionRetryTimer: Timer?
    private var didShowPermissionAlert = false
    private var settingsWindowController: SettingsWindowController?
    private var settingsModel: TypingPetSettingsModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        petController = PetController(
            library: imageLibrary,
            keyStore: keyReactionStore,
            onScaleChanged: { [weak self] scale in self?.settingsModel?.syncScale(scale) }
        )
        configureStatusItem()

        keyMonitor = GlobalKeyMonitor { [weak self] stroke in
            DispatchQueue.main.async {
                self?.petController.handleKeystroke(stroke)
            }
        }

        startMonitoringOrRequestPermission(shouldShowAlert: true)

        if ProcessInfo.processInfo.arguments.contains("--show-settings") {
            DispatchQueue.main.async { [weak self] in self?.showSettings() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionRetryTimer?.invalidate()
        keyMonitor.stop()
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
        petVisibilityItem.title = petController.isPetVisible ? "펫 숨기기" : "펫 다시 표시"
        alwaysOnTopItem.state = petController.isAlwaysOnTop ? .on : .off
        positionLockedItem.state = petController.isPositionLocked ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let permissionGranted = CGPreflightListenEventAccess()
        monitoringStatusItem.title = keyMonitor.isRunning
            ? "키 입력 감지: 연결됨"
            : (permissionGranted ? "키 입력 감지: 다시 연결 중" : "키 입력 감지: 권한 필요")
        permissionItem.title = permissionGranted ? "입력 모니터링 설정 열기…" : "입력 모니터링 권한 열기…"
        reactionCountItem.title = "현재 반응 이미지: \(imageLibrary.reactionURLs.count)장"
        resetImagesItem.isEnabled = imageLibrary.usesCustomImages
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
            title: "대기 이미지 선택",
            message: "키 입력이 없을 때 표시할 이미지를 선택하세요.",
            allowsMultipleSelection: false
        )?.first else { return }

        do {
            try imageLibrary.replaceIdle(with: url)
            petController.reloadImages()
        } catch {
            showImageError(error)
        }
    }

    @objc private func replaceReactionImages() {
        guard let urls = chooseImageFiles(
            title: "반응 이미지 선택",
            message: "키를 누를 때 무작위로 표시할 이미지를 한 장 이상 선택하세요.",
            allowsMultipleSelection: true
        ), !urls.isEmpty else { return }

        do {
            try imageLibrary.replaceReactions(with: urls)
            petController.reloadImages()
        } catch {
            showImageError(error)
        }
    }

    @objc private func importImageFolder() {
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        let panel = NSOpenPanel()
        panel.title = "이미지 폴더 가져오기"
        panel.message = "idle.* 또는 pet-idle.*는 대기 이미지로, 나머지는 키 입력용 이미지로 가져옵니다."
        panel.prompt = "가져오기"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        do {
            let result = try imageLibrary.importFolder(folderURL)
            petController.reloadImages()

            var parts: [String] = []
            if result.changedIdle {
                parts.append("대기 이미지 1장")
            }
            if let reactionCount = result.reactionCount {
                parts.append("반응 이미지 \(reactionCount)장")
            }
            showAlert(
                title: "이미지를 가져왔습니다",
                message: parts.joined(separator: ", ") + "을 적용했습니다.",
                primaryButton: "확인"
            )
        } catch {
            showImageError(error)
        }
    }

    @objc private func showImageFolderRules() {
        showAlert(
            title: "이미지 세트 폴더 규칙",
            message: "파일명은 자유롭게 사용할 수 있습니다. idle.* 또는 pet-idle.* 파일이 있으면 대기 이미지로 인식하며, 나머지는 키 입력용 이미지가 됩니다. 대기 이미지가 없으면 정렬상 첫 이미지를 대기 이미지로 사용합니다. 이미지가 한 장뿐이면 대기/반응에 함께 사용합니다. PNG, APNG, JPG, GIF, TIFF, HEIC, WebP를 지원합니다.",
            primaryButton: "확인"
        )
    }

    @objc private func resetImages() {
        showAlert(
            title: "기본 이미지로 복원할까요?",
            message: "현재 선택한 대기 이미지와 반응 이미지 설정을 기본값으로 되돌립니다. 원본 이미지 파일은 변경하지 않습니다.",
            primaryButton: "복원",
            secondaryButton: "취소"
        ) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.imageLibrary.resetToDefaults()
            self?.petController.reloadImages()
        }
    }

    @objc private func restartMonitoring() {
        startMonitoringOrRequestPermission(shouldShowAlert: true)
    }

    @objc private func previewReaction() {
        petController.handleKeystroke(nil)
    }

    @objc private func showSettings() {
        if settingsModel == nil {
            settingsModel = TypingPetSettingsModel(
                library: imageLibrary,
                keyStore: keyReactionStore,
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
                reloadPet: { [weak self] in self?.petController.reloadImages() }
            )
        }
        settingsModel?.refresh()
        if settingsWindowController == nil, let settingsModel {
            settingsWindowController = SettingsWindowController(model: settingsModel)
        }
        settingsWindowController?.show()
    }

    @objc private func openInputMonitoringSettings() {
        let address = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        if let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        }
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
                title: "자동 실행 설정 실패",
                message: error.localizedDescription,
                primaryButton: "확인"
            )
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Typing Pet")
            image?.isTemplate = true
            button.image = image
        }

        menu = NSMenu()
        menu.delegate = self

        menu.addItem(makeMenuItem("설정…", action: #selector(showSettings), keyEquivalent: ","))
        petVisibilityItem = makeMenuItem("펫 숨기기", action: #selector(togglePetVisibility))
        menu.addItem(petVisibilityItem)
        menu.addItem(.separator())

        alwaysOnTopItem = makeMenuItem("항상 위에 표시", action: #selector(toggleAlwaysOnTop))
        positionLockedItem = makeMenuItem("위치 잠금 (클릭 통과)", action: #selector(togglePositionLock))
        menu.addItem(alwaysOnTopItem)
        menu.addItem(positionLockedItem)
        menu.addItem(makeMenuItem("위치 초기화", action: #selector(resetPosition)))

        let sizeItem = NSMenuItem(title: "크기", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        sizeMenu.addItem(makeMenuItem("작게", action: #selector(setSmallSize)))
        sizeMenu.addItem(makeMenuItem("보통", action: #selector(setMediumSize)))
        sizeMenu.addItem(makeMenuItem("크게", action: #selector(setLargeSize)))
        sizeMenu.addItem(makeMenuItem("아주 크게", action: #selector(setExtraLargeSize)))
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let imagesItem = NSMenuItem(title: "이미지", action: nil, keyEquivalent: "")
        let imagesMenu = NSMenu()
        reactionCountItem = NSMenuItem(title: "현재 반응 이미지: 0장", action: nil, keyEquivalent: "")
        reactionCountItem.isEnabled = false
        imagesMenu.addItem(reactionCountItem)
        imagesMenu.addItem(.separator())
        imagesMenu.addItem(makeMenuItem("대기 이미지 변경…", action: #selector(changeIdleImage)))
        imagesMenu.addItem(makeMenuItem("반응 이미지 교체…", action: #selector(replaceReactionImages)))
        imagesMenu.addItem(makeMenuItem("이미지 폴더 가져오기…", action: #selector(importImageFolder)))
        imagesMenu.addItem(makeMenuItem("폴더 규칙 보기…", action: #selector(showImageFolderRules)))
        imagesMenu.addItem(.separator())
        resetImagesItem = makeMenuItem("기본 이미지로 복원", action: #selector(resetImages))
        imagesMenu.addItem(resetImagesItem)
        imagesItem.submenu = imagesMenu
        menu.addItem(imagesItem)

        menu.addItem(.separator())
        monitoringStatusItem = NSMenuItem(title: "키 입력 감지: 확인 중", action: nil, keyEquivalent: "")
        monitoringStatusItem.isEnabled = false
        menu.addItem(monitoringStatusItem)
        permissionItem = makeMenuItem("입력 모니터링 권한 열기…", action: #selector(openInputMonitoringSettings))
        menu.addItem(permissionItem)
        menu.addItem(makeMenuItem("키 입력 감지 다시 시작", action: #selector(restartMonitoring)))
        menu.addItem(makeMenuItem("반응 이미지 테스트", action: #selector(previewReaction)))

        loginItem = makeMenuItem("로그인 시 자동 실행", action: #selector(toggleLaunchAtLogin))
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Typing Pet 종료", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
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
        panel.prompt = "선택"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.allowedContentTypes = [.image]
        return panel.runModal() == .OK ? panel.urls : nil
    }

    private func showImageError(_ error: Error) {
        showAlert(
            title: "이미지를 적용하지 못했습니다",
            message: error.localizedDescription,
            primaryButton: "확인"
        )
    }

    private func startMonitoringOrRequestPermission(shouldShowAlert: Bool) {
        if CGPreflightListenEventAccess(), keyMonitor.start() {
            permissionRetryTimer?.invalidate()
            permissionRetryTimer = nil
            return
        }

        schedulePermissionRetry()
        guard shouldShowAlert, !didShowPermissionAlert else { return }
        didShowPermissionAlert = true
        _ = CGRequestListenEventAccess()
        showAlert(
            title: "키 입력 감지 권한이 필요합니다",
            message: "Typing Pet은 입력 내용을 읽거나 저장하지 않고, 키가 눌렸다는 사실만 감지합니다. 시스템 설정에서 Typing Pet의 입력 모니터링을 허용하면 앱이 자동으로 다시 연결합니다.",
            primaryButton: "시스템 설정 열기",
            secondaryButton: "나중에"
        ) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.openInputMonitoringSettings()
            }
        }
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
        guard !keyMonitor.isRunning, CGPreflightListenEventAccess() else { return }
        if keyMonitor.start() {
            permissionRetryTimer?.invalidate()
            permissionRetryTimer = nil
        }
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
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
