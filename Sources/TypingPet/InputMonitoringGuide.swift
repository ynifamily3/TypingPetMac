import AppKit
import SwiftUI

enum TypingPetAppLocation: Equatable {
    case applications
    case outsideApplications
    case translocated

    static func detect(
        appURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> TypingPetAppLocation {
        let path = appURL.standardizedFileURL.path
        if path.contains("/AppTranslocation/") {
            return .translocated
        }

        let applicationsPaths = [
            URL(fileURLWithPath: "/Applications", isDirectory: true).path,
            homeDirectory.appendingPathComponent("Applications", isDirectory: true).standardizedFileURL.path
        ]
        return applicationsPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
            ? .applications
            : .outsideApplications
    }
}

@MainActor
enum InputMonitoringSettings {
    static let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    )!

    static func open() {
        NSWorkspace.shared.open(url)
    }
}

enum InputMonitoringGuidePlacement {
    static func appKitFrame(fromQuartzFrame frame: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryScreenMaxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    static func origin(
        panelSize: CGSize,
        beside targetFrame: CGRect,
        in visibleFrame: CGRect,
        gap: CGFloat = 12,
        margin: CGFloat = 12
    ) -> CGPoint {
        let minimumX = visibleFrame.minX + margin
        let maximumX = visibleFrame.maxX - panelSize.width - margin
        let minimumY = visibleFrame.minY + margin
        let maximumY = visibleFrame.maxY - panelSize.height - margin
        let rightX = targetFrame.maxX + gap
        let leftX = targetFrame.minX - gap - panelSize.width

        let x: CGFloat
        if rightX <= maximumX {
            x = rightX
        } else if leftX >= minimumX {
            x = leftX
        } else {
            let rightSpace = visibleFrame.maxX - targetFrame.maxX
            let leftSpace = targetFrame.minX - visibleFrame.minX
            x = min(max(rightSpace >= leftSpace ? rightX : leftX, minimumX), maximumX)
        }

        let topAlignedY = targetFrame.maxY - panelSize.height
        let y = min(max(topAlignedY, minimumY), maximumY)
        return CGPoint(x: x, y: y)
    }
}

private enum SystemSettingsWindowLocator {
    private static let bundleIdentifiers = [
        "com.apple.systempreferences",
        "com.apple.SystemSettings"
    ]

    static func frame(primaryScreenMaxY: CGFloat) -> CGRect? {
        let processIdentifiers = Set(bundleIdentifiers.flatMap { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .map(\.processIdentifier)
        })
        guard !processIdentifiers.isEmpty,
              let windowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else { return nil }

        for window in windowInfo {
            guard let processIdentifier = window[kCGWindowOwnerPID as String] as? pid_t,
                  processIdentifiers.contains(processIdentifier),
                  (window[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary else { continue }

            var quartzFrame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &quartzFrame),
                  quartzFrame.width >= 400,
                  quartzFrame.height >= 300 else { continue }
            return InputMonitoringGuidePlacement.appKitFrame(
                fromQuartzFrame: quartzFrame,
                primaryScreenMaxY: primaryScreenMaxY
            )
        }
        return nil
    }
}

@MainActor
final class InputMonitoringGuideController: NSObject, NSWindowDelegate {
    private let appURL: URL
    private let location: TypingPetAppLocation
    private let model: InputMonitoringGuideModel
    private let onSetupStarted: () -> Void
    private let onDismiss: () -> Void
    private var panel: NSPanel?
    private var permissionTimer: Timer?
    private var windowTrackingTimer: Timer?
    private var completionWork: DispatchWorkItem?

    init(
        appURL: URL = Bundle.main.bundleURL,
        idleURL: URL?,
        reactionURLs: [URL],
        resumeSetup: Bool = false,
        model: InputMonitoringGuideModel? = nil,
        onSetupStarted: @escaping () -> Void = {},
        onDismiss: @escaping () -> Void = {},
        connectMonitoring: @escaping (_ restart: Bool) -> Bool
    ) {
        self.appURL = appURL
        location = TypingPetAppLocation.detect(appURL: appURL)
        self.onDismiss = onDismiss
        self.onSetupStarted = onSetupStarted
        self.model = model ?? InputMonitoringGuideModel(
            idleImage: idleURL.flatMap { NSImage(contentsOf: $0) },
            reactionImages: reactionURLs.compactMap { NSImage(contentsOf: $0) },
            resumeSetup: resumeSetup,
            connectMonitoring: connectMonitoring,
            onSetupStarted: onSetupStarted
        )
        super.init()
    }

    func show() {
        completionWork?.cancel()
        if model.phase != .preview && model.phase != .complete { onSetupStarted() }
        let panel = panel ?? makePanel()
        self.panel = panel
        resizePanel()
        positionAtScreenCorner(panel)
        if model.phase == .preview {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        startPermissionTimer()
        updateWindowTrackingTimer()
        followSystemSettingsWindow()
        refreshPermission()
    }

    func hide() {
        completionWork?.cancel()
        completionWork = nil
        stopTimers()
        panel?.orderOut(nil)
        onDismiss()
    }

    func windowWillClose(_ notification: Notification) {
        hide()
    }

    @objc private func refreshPermission() {
        model.refresh()
    }

    func receivedGlobalKeystroke() {
        guard panel?.isVisible == true, model.receivedGlobalKeystroke() else { return }
        completionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard self?.model.phase == .complete else { return }
            self?.hide()
        }
        completionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private var panelHeight: CGFloat {
        let contentHeight: CGFloat
        switch model.phase {
        case .preview: contentHeight = 490
        case .permission: contentHeight = model.showsMissingAppHelp ? 390 : 250
        case .verifying: contentHeight = model.showsConnectionHelp ? 390 : 300
        case .connectionFailed: contentHeight = 360
        case .complete: contentHeight = 280
        }
        return contentHeight + (location == .applications || model.phase == .complete ? 0 : 64)
    }

    private func resizePanel() {
        guard let panel else { return }
        let previousTop = panel.frame.maxY
        panel.setContentSize(NSSize(width: 440, height: panelHeight))
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: previousTop - panel.frame.height))
        if let screen = panel.screen {
            panel.setFrameOrigin(NSPoint(
                x: min(max(panel.frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - panel.frame.width),
                y: min(max(panel.frame.minY, screen.visibleFrame.minY), screen.visibleFrame.maxY - panel.frame.height)
            ))
        }
        updateWindowTrackingTimer()
        followSystemSettingsWindow()
    }

    private func makePanel() -> NSPanel {
        let rootView = InputMonitoringGuideView(
            model: model,
            appURL: appURL,
            location: location,
            layoutChanged: { [weak self] in self?.resizePanel() },
            close: { [weak self] in self?.hide() }
        )
        let hostingController = NSHostingController(rootView: rootView)
        let panel = InputMonitoringGuidePanel(contentViewController: hostingController)
        panel.setContentSize(NSSize(width: 440, height: panelHeight))
        panel.styleMask = [.titled, .closable, .utilityWindow, .fullSizeContentView]
        panel.title = AppEnvironment.displayName + L(" Input Monitoring Guide")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 20
        panel.contentView?.layer?.masksToBounds = true
        return panel
    }

    private func positionAtScreenCorner(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }

        let margin: CGFloat = 24
        let origin = NSPoint(
            x: visibleFrame.maxX - panel.frame.width - margin,
            y: visibleFrame.minY + margin
        )
        panel.setFrameOrigin(origin)
    }

    @objc private func followSystemSettingsWindow() {
        guard model.phase != .preview,
              let panel,
              let primaryScreen = NSScreen.screens.first,
              let settingsFrame = SystemSettingsWindowLocator.frame(
                primaryScreenMaxY: primaryScreen.frame.maxY
              ),
              let screen = screen(containingMostOf: settingsFrame) else { return }

        let origin = InputMonitoringGuidePlacement.origin(
            panelSize: panel.frame.size,
            beside: settingsFrame,
            in: screen.visibleFrame
        )
        guard abs(panel.frame.origin.x - origin.x) >= 0.5
                || abs(panel.frame.origin.y - origin.y) >= 0.5 else { return }
        panel.setFrameOrigin(origin)
    }

    private func screen(containingMostOf frame: CGRect) -> NSScreen? {
        NSScreen.screens.max { first, second in
            first.frame.intersection(frame).area < second.frame.intersection(frame).area
        }
    }

    private func startPermissionTimer() {
        permissionTimer?.invalidate()
        let timer = Timer(
            timeInterval: 0.75,
            target: self,
            selector: #selector(refreshPermission),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func updateWindowTrackingTimer() {
        let shouldTrack = model.phase != .preview && model.phase != .complete && panel?.isVisible == true
        if !shouldTrack {
            windowTrackingTimer?.invalidate()
            windowTrackingTimer = nil
            return
        }
        guard windowTrackingTimer == nil else { return }
        let timer = Timer(
            timeInterval: 0.12,
            target: self,
            selector: #selector(followSystemSettingsWindow),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        windowTrackingTimer = timer
    }

    private func stopTimers() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        windowTrackingTimer?.invalidate()
        windowTrackingTimer = nil
    }

    #if DEBUG
    // Exercises every screen without requesting or changing macOS permissions.
    static func preview(
        phase: InputMonitoringGuideModel.Phase,
        idleURL: URL?,
        reactionURLs: [URL]
    ) -> InputMonitoringGuideController {
        let model = InputMonitoringGuideModel(
            idleImage: idleURL.flatMap { NSImage(contentsOf: $0) },
            reactionImages: reactionURLs.compactMap { NSImage(contentsOf: $0) },
            isPermissionGranted: { phase != .permission },
            connectMonitoring: { _ in phase != .connectionFailed },
            requestPermission: {},
            openSettings: {}
        )
        if phase != .preview { model.beginSetup() }
        if phase == .complete { model.receivedGlobalKeystroke() }
        return InputMonitoringGuideController(
            idleURL: idleURL, reactionURLs: reactionURLs, model: model,
            connectMonitoring: { _ in false }
        )
    }
    #endif

}

private extension CGRect {
    var area: CGFloat {
        isNull || isInfinite ? 0 : width * height
    }
}

private final class InputMonitoringGuidePanel: NSPanel {
    weak var previewKeyView: PreviewKeyCaptureView? { didSet { connectPreviewKeyViews() } }
    weak var previewFooter: InputMonitoringPreviewFooterView? { didSet { connectPreviewKeyViews() } }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func connectPreviewKeyViews() {
        guard let previewKeyView, let previewFooter else { return }
        previewKeyView.nextKeyView = previewFooter.laterButton
        previewFooter.laterButton.nextKeyView = previewFooter.setupButton
        previewFooter.setupButton.nextKeyView = previewKeyView
    }
}

private struct InputMonitoringGuideView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: InputMonitoringGuideModel
    let appURL: URL
    let location: TypingPetAppLocation
    let layoutChanged: () -> Void
    let close: () -> Void
    @State private var previewIsFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                step(L("1 Try it"), active: model.phase == .preview)
                Image(systemName: "chevron.right").font(.caption2)
                step(L("2 Set up"), active: model.phase == .permission || model.phase == .connectionFailed)
                Image(systemName: "chevron.right").font(.caption2)
                step(L("3 Verify"), active: model.phase == .verifying || model.phase == .complete)
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title2.bold())
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch model.phase {
            case .preview:
                preview
                Text(L("Input Monitoring lets your pet react while you use other apps. Only key presses and assigned shortcuts are detected. Typed text is never stored or sent."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .permission:
                permissionInstructions
            case .verifying:
                Label(L("Waiting for a key press"), systemImage: "keyboard")
                    .font(.headline)
                    .padding(.vertical, 8)
                DisclosureGroup(L("No reaction?"), isExpanded: $model.showsConnectionHelp) {
                    connectionHelp
                }
            case .connectionFailed:
                connectionHelp
            case .complete:
                Label(L("A real key press was detected"), systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .padding(.vertical, 12)
            }

            if location != .applications && model.phase != .complete {
                Label(locationWarning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            if model.phase == .preview {
                InputMonitoringPreviewFooter(onLater: close, onSetup: model.beginSetup)
                    .frame(height: 32)
            } else {
                HStack {
                    if model.phase != .complete {
                        Button(L("Later"), action: close)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    switch model.phase {
                    case .preview: EmptyView()
                    case .permission:
                        Button(L("Open Settings"), action: model.showSettings)
                            .buttonStyle(.borderedProminent)
                    case .verifying, .connectionFailed:
                        Button(L("Reconnect")) { model.refresh(restart: true) }
                            .buttonStyle(.borderedProminent)
                    case .complete:
                        Spacer()
                        Button(L("Get Started"), action: close).buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 440, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .onChange(of: model.phase) { _ in layoutChanged() }
        .onChange(of: model.showsMissingAppHelp) { _ in layoutChanged() }
        .onChange(of: model.showsConnectionHelp) { _ in layoutChanged() }
    }

    private func step(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.caption.weight(active ? .semibold : .regular))
            .foregroundStyle(active ? Color.accentColor : .secondary)
    }

    private var preview: some View {
        VStack(spacing: 10) {
            if let image = model.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 130)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 64))
                    .frame(height: 130)
                    .accessibilityHidden(true)
            }
            Text(previewIsFocused ? L("Press a key now") : L("Click here, then press a key"))
                .font(.callout.weight(.medium))
            Text(model.hasTriedPreview ? L("Your pet reacts whenever you type") : L("No permission is needed for this preview"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(previewIsFocused ? Color.accentColor : .clear, lineWidth: 2))
        .overlay {
            InputMonitoringPreviewCapture(
                onKeystroke: model.previewKeystroke,
                onFocusChanged: { previewIsFocused = $0 }
            )
        }
    }

    private var permissionInstructions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L("Turn on the switch for %1$@ in the list.", appURL.deletingPathExtension().lastPathComponent), systemImage: "switch.2")
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(L("Not in the list?"), isExpanded: $model.showsMissingAppHelp) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        DraggableAppIcon(appURL: appURL).frame(width: 52, height: 52)
                        Text(L("Drag this icon into the Input Monitoring list, then turn on its switch."))
                            .font(.callout)
                    }
                    Text(L("If dragging does not work, click + below the list and select %1$@.", appURL.lastPathComponent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)
            }
        }
    }

    private var connectionHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Close Settings and type in another app. If macOS asks you to quit and reopen, follow that prompt."))
            Text(L("If there is still no reaction, reconnect or quit the app from its menu and open it again."))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 6)
    }

    private var title: String {
        switch model.phase {
        case .preview: return L("Press a key. Meet your pet.")
        case .permission: return L("Turn on Input Monitoring")
        case .verifying: return L("Connected. Try typing.")
        case .connectionFailed: return L("Permission granted. Reconnect to continue.")
        case .complete: return L("You are ready!")
        }
    }

    private var message: String {
        switch model.phase {
        case .preview: return L("Try the key reactions in this window first.")
        case .permission: return L("System Settings → Privacy & Security → Input Monitoring")
        case .verifying: return L("Type in another app to see your pet react. This guide closes after the first reaction.")
        case .connectionFailed: return L("Reconnect key detection. Setup finishes after a real key press is detected.")
        case .complete: return L("Your pet will now react as you type.")
        }
    }

    private var locationWarning: String {
        switch location {
        case .applications: return ""
        case .outsideApplications: return L("This app is outside Applications. Move it into Applications and reopen it before granting permission.")
        case .translocated: return L("This app is running from a temporary security location. Move it into Applications, reopen it, then grant permission.")
        }
    }
}

private struct InputMonitoringPreviewFooter: NSViewRepresentable {
    let onLater: () -> Void
    let onSetup: () -> Void

    func makeNSView(context: Context) -> InputMonitoringPreviewFooterView {
        InputMonitoringPreviewFooterView(onLater: onLater, onSetup: onSetup)
    }

    func updateNSView(_ nsView: InputMonitoringPreviewFooterView, context: Context) {}
}

private final class InputMonitoringPreviewFooterView: NSView {
    let laterButton: InputMonitoringPreviewButton
    let setupButton: InputMonitoringPreviewButton

    init(onLater: @escaping () -> Void, onSetup: @escaping () -> Void) {
        laterButton = InputMonitoringPreviewButton(title: L("Later"), onPress: onLater)
        setupButton = InputMonitoringPreviewButton(title: L("Set Up Reactions in Other Apps"), onPress: onSetup)
        super.init(frame: .zero)
        laterButton.isBordered = false
        setupButton.bezelColor = .controlAccentColor
        setupButton.attributedTitle = NSAttributedString(
            string: setupButton.title,
            attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13)]
        )
        let stack = NSStackView(views: [laterButton, NSView(), setupButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? InputMonitoringGuidePanel)?.previewFooter = self
    }
}

private final class InputMonitoringPreviewButton: NSButton {
    private let onPress: () -> Void
    // Keep the preview's key-view loop usable even when system-wide keyboard
    // navigation for standard controls is disabled.
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    init(title: String, onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .large
        font = .systemFont(ofSize: 13)
        setContentHuggingPriority(.required, for: .horizontal)
        target = self
        action = #selector(pressed)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pressed() { onPress() }
}

private struct InputMonitoringPreviewCapture: NSViewRepresentable {
    let onKeystroke: () -> Void
    let onFocusChanged: (Bool) -> Void

    func makeNSView(context: Context) -> PreviewKeyCaptureView {
        PreviewKeyCaptureView(onKeystroke: onKeystroke, onFocusChanged: onFocusChanged)
    }

    func updateNSView(_ nsView: PreviewKeyCaptureView, context: Context) {}
}

private final class PreviewKeyCaptureView: NSView {
    private let onKeystroke: () -> Void
    private let onFocusChanged: (Bool) -> Void
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(
        onKeystroke: @escaping () -> Void,
        onFocusChanged: @escaping (Bool) -> Void
    ) {
        self.onKeystroke = onKeystroke
        self.onFocusChanged = onFocusChanged
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L("Key reaction preview"))
        setAccessibilityHelp(L("Click or activate this area and press a key to see your pet react. Typed text is not stored."))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? InputMonitoringGuidePanel)?.previewKeyView = self
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self) ?? false
    }

    override func becomeFirstResponder() -> Bool {
        onFocusChanged(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusChanged(false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        // Preserve keyboard navigation and app shortcuts. Never read event.characters.
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
        } else if event.keyCode == 53 || !event.modifierFlags.intersection([.command, .control]).isEmpty {
            super.keyDown(with: event)
        } else {
            onKeystroke()
        }
    }
}

private struct DraggableAppIcon: NSViewRepresentable {
    let appURL: URL

    func makeNSView(context: Context) -> AppBundleDragView {
        AppBundleDragView(appURL: appURL)
    }

    func updateNSView(_ nsView: AppBundleDragView, context: Context) {}
}

private final class AppBundleDragView: NSView, NSDraggingSource {
    private let appURL: URL
    private let iconView: NSImageView

    init(appURL: URL) {
        self.appURL = appURL
        iconView = NSImageView(frame: .zero)
        super.init(frame: .zero)
        wantsLayer = true

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 64, height: 64)
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        toolTip = L("Drag %1$@ into the Input Monitoring list", appURL.lastPathComponent)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L("Draggable %1$@", appURL.lastPathComponent))
        setAccessibilityHelp(L("Drag into the Input Monitoring list to add the app."))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        iconView.frame = bounds.insetBy(dx: 6, dy: 6)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        item.setDraggingFrame(bounds, contents: iconView.image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }
}
