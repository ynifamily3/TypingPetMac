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

private final class PetContentView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
private final class PetController: NSObject, NSWindowDelegate {
    private let library: PetImageLibrary
    private let keyStore: KeyReactionStore
    private let panel: PetPanel
    private let imageView: NSImageView
    private var baseSize: NSSize
    private var currentImageKey = ""
    private var idleWorkItem: DispatchWorkItem?

    init(library: PetImageLibrary, keyStore: KeyReactionStore) {
        self.library = library
        self.keyStore = keyStore
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
        super.init()

        let contentView = PetContentView(frame: NSRect(origin: .zero, size: panel.frame.size))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        imageView.autoresizingMask = [.width, .height]
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.wantsLayer = true
        contentView.addSubview(imageView)

        panel.contentView = contentView
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = Self.savedAlwaysOnTop ? .floating : .normal
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.ignoresMouseEvents = Self.savedPositionLocked
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let restoredPosition = panel.setFrameUsingName("TypingPetWindow")
        resizePanelForCurrentCanvas(animate: false)
        if !restoredPosition {
            resetPosition()
        }

        showIdleImage()
        panel.orderFrontRegardless()
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
            panel.ignoresMouseEvents = newValue
            UserDefaults.standard.set(newValue, forKey: "positionLocked")
        }
    }

    var scale: CGFloat {
        get { Self.savedScale }
        set {
            let clamped = max(0.35, min(newValue, 1.25))
            let oldFrame = panel.frame
            let newSize = Self.scaledSize(baseSize: baseSize, scale: clamped)
            let newOrigin = NSPoint(
                x: oldFrame.midX - newSize.width / 2,
                y: oldFrame.minY
            )
            panel.setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: true)
            UserDefaults.standard.set(Double(clamped), forKey: "petScale")
            panel.saveFrame(usingName: "TypingPetWindow")
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

    func resetPosition() {
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
        petController = PetController(library: imageLibrary, keyStore: keyReactionStore)
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

    func menuWillOpen(_ menu: NSMenu) {
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
                shakeLevel: petController.shakeLevel,
                alwaysOnTop: petController.isAlwaysOnTop,
                positionLocked: petController.isPositionLocked,
                applyScale: { [weak self] in self?.petController.scale = $0 },
                applyShake: { [weak self] in self?.petController.shakeLevel = $0 },
                applyAlwaysOnTop: { [weak self] in self?.petController.isAlwaysOnTop = $0 },
                applyPositionLock: { [weak self] in self?.petController.isPositionLocked = $0 },
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
