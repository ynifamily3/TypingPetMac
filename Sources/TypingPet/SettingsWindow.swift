import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsAppearanceMode: String, CaseIterable {
    case system, light, dark

    static let defaultsKey = "SettingsAppearanceMode"

    static func load(from defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .system
    }

    var windowAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class TypingPetSettingsModel: ObservableObject {
    @Published private(set) var imageSets: [PetImageSet] = []
    @Published var selectedSetID: UUID?
    @Published private(set) var activeSetID: UUID
    @Published private(set) var rules: [KeyReactionRule] = []
    @Published private(set) var scale: Double
    @Published private(set) var restingOpacity: Double
    @Published private(set) var hoverOpacity: Double
    @Published private(set) var shakeLevel: Int
    @Published private(set) var alwaysOnTop: Bool
    @Published private(set) var positionLocked: Bool
    @Published private(set) var avoidsPointerWhenLocked: Bool
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var appearanceMode: SettingsAppearanceMode
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var inputMonitoringConnected = false
    @Published var errorMessage: String?
    var onAppearanceChanged: ((SettingsAppearanceMode) -> Void)?

    let library: PetImageLibrary
    let keyStore: KeyReactionStore
    let packStore: PetPackStore
    private let defaults: UserDefaults
    private let applyScale: (CGFloat) -> Void
    private let applyRestingOpacity: (CGFloat) -> Void
    private let applyHoverOpacity: (CGFloat) -> Void
    private let applyShake: (Int) -> Void
    private let applyAlwaysOnTop: (Bool) -> Void
    private let applyPositionLock: (Bool) -> Void
    private let applyPointerAvoidance: (Bool) -> Void
    private let applyAppearance: (SettingsAppearanceMode) -> Void
    private let reloadPet: () -> Void
    private let openInputMonitoringSettingsAction: () -> Void
    private let monitoringIsRunning: () -> Bool
    private let retryMonitoring: () -> Void
    private let inputMonitoringAuthorized: () -> Bool

    init(
        library: PetImageLibrary,
        keyStore: KeyReactionStore,
        packStore: PetPackStore? = nil,
        scale: CGFloat,
        restingOpacity: CGFloat,
        hoverOpacity: CGFloat,
        shakeLevel: Int,
        alwaysOnTop: Bool,
        positionLocked: Bool,
        avoidsPointerWhenLocked: Bool,
        applyScale: @escaping (CGFloat) -> Void,
        applyRestingOpacity: @escaping (CGFloat) -> Void,
        applyHoverOpacity: @escaping (CGFloat) -> Void,
        applyShake: @escaping (Int) -> Void,
        applyAlwaysOnTop: @escaping (Bool) -> Void,
        applyPositionLock: @escaping (Bool) -> Void,
        applyPointerAvoidance: @escaping (Bool) -> Void,
        applyAppearance: @escaping (SettingsAppearanceMode) -> Void,
        reloadPet: @escaping () -> Void,
        openInputMonitoringSettings: @escaping () -> Void,
        monitoringIsRunning: @escaping () -> Bool = { false },
        retryMonitoring: @escaping () -> Void = {},
        inputMonitoringAuthorized: @escaping () -> Bool = { CGPreflightListenEventAccess() },
        defaults: UserDefaults = AppEnvironment.defaults
    ) {
        self.library = library
        self.keyStore = keyStore
        self.packStore = packStore ?? PetPackStore(library: library, keyStore: keyStore)
        self.defaults = defaults
        self.scale = Double(scale)
        self.restingOpacity = Double(restingOpacity)
        self.hoverOpacity = Double(hoverOpacity)
        self.shakeLevel = shakeLevel
        self.alwaysOnTop = alwaysOnTop
        self.positionLocked = positionLocked
        self.avoidsPointerWhenLocked = avoidsPointerWhenLocked
        self.applyScale = applyScale
        self.applyRestingOpacity = applyRestingOpacity
        self.applyHoverOpacity = applyHoverOpacity
        self.applyShake = applyShake
        self.applyAlwaysOnTop = applyAlwaysOnTop
        self.applyPositionLock = applyPositionLock
        self.applyPointerAvoidance = applyPointerAvoidance
        self.applyAppearance = applyAppearance
        self.reloadPet = reloadPet
        openInputMonitoringSettingsAction = openInputMonitoringSettings
        self.monitoringIsRunning = monitoringIsRunning
        self.retryMonitoring = retryMonitoring
        self.inputMonitoringAuthorized = inputMonitoringAuthorized
        activeSetID = library.activeSetID
        selectedSetID = library.activeSetID
        launchAtLogin = SMAppService.mainApp.status == .enabled
        appearanceMode = SettingsAppearanceMode.load(from: defaults)
        refresh()
    }

    var selectedSet: PetImageSet? { imageSets.first { $0.id == selectedSetID } }

    func thumbnail(for set: PetImageSet) -> NSImage? {
        library.thumbnail(for: set)
    }

    func ruleImage(for rule: KeyReactionRule) -> NSImage? {
        keyStore.imageURL(for: rule).flatMap { library.image(for: $0) }
    }

    func refresh() {
        imageSets = library.imageSets
        activeSetID = library.activeSetID
        rules = keyStore.rules
        refreshPermissions()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func packDidChange(reload: Bool = true) {
        refresh()
        if reload { reloadPet() }
    }

    func refreshPermissions(retryConnection: Bool = false) {
        let granted = inputMonitoringAuthorized()
        if retryConnection && granted { retryMonitoring() }
        let connected = granted && monitoringIsRunning()
        if inputMonitoringGranted != granted { inputMonitoringGranted = granted }
        if inputMonitoringConnected != connected { inputMonitoringConnected = connected }
    }

    func setScale(_ value: Double) {
        scale = value
        applyScale(CGFloat(value))
    }

    func syncScale(_ value: CGFloat) {
        scale = Double(value)
    }

    func setRestingOpacity(_ value: Double) {
        restingOpacity = value
        applyRestingOpacity(CGFloat(value))
    }

    func setHoverOpacity(_ value: Double) {
        hoverOpacity = value
        applyHoverOpacity(CGFloat(value))
    }

    func setShakeLevel(_ value: Int) {
        shakeLevel = value
        applyShake(value)
    }

    func setAlwaysOnTop(_ value: Bool) {
        alwaysOnTop = value
        applyAlwaysOnTop(value)
    }

    func setPositionLocked(_ value: Bool) {
        positionLocked = value
        applyPositionLock(value)
    }

    func setPointerAvoidance(_ value: Bool) {
        avoidsPointerWhenLocked = value
        applyPointerAvoidance(value)
    }

    func setAppearanceMode(_ value: SettingsAppearanceMode) {
        appearanceMode = value
        defaults.set(value.rawValue, forKey: SettingsAppearanceMode.defaultsKey)
        applyAppearance(value)
        onAppearanceChanged?(value)
    }

    func toggleLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = value
        } catch {
            errorMessage = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func activateSelectedSet() {
        guard let id = selectedSetID else { return }
        do {
            try library.activateSet(id: id)
            activeSetID = id
            reloadPet()
        } catch { errorMessage = error.localizedDescription }
    }

    func importImageSet() {
        let panel = NSOpenPanel()
        panel.title = L("Add Image Set Folder")
        panel.message = L("idle.* or pet-idle.* is the idle image. Other files are imported as reaction images.")
        panel.prompt = L("Add to Gallery")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let set = try library.addSet(from: url)
            selectedSetID = set.id
            refresh()
            reloadPet()
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteSelectedSet() {
        guard let set = selectedSet, !set.isBuiltIn else { return }
        let alert = NSAlert()
        alert.messageText = L("Remove “%1$@” from the list?", set.name)
        alert.informativeText = L("Original images will not be changed.")
        alert.addButton(withTitle: L("Remove"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try library.deleteSet(id: set.id)
            selectedSetID = library.activeSetID
            refresh()
            reloadPet()
        } catch { errorMessage = error.localizedDescription }
    }

    func renameSelectedSet() {
        guard let set = selectedSet, !set.isBuiltIn else { return }
        let field = NSTextField(string: set.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let alert = NSAlert()
        alert.messageText = L("Rename Image Set")
        alert.accessoryView = field
        alert.addButton(withTitle: L("Rename"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try library.renameSet(id: set.id, to: field.stringValue)
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func addRule(stroke: KeyStroke, imageURL: URL) {
        do {
            try keyStore.setRule(for: stroke, image: imageURL)
            rules = keyStore.rules
        } catch { errorMessage = error.localizedDescription }
    }

    func removeRule(_ rule: KeyReactionRule) {
        keyStore.removeRule(id: rule.id)
        rules = keyStore.rules
    }

    func openInputMonitoringSettings() {
        openInputMonitoringSettingsAction()
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var languageSubscription: AnyCancellable?

    init(model: TypingPetSettingsModel, todoStore: TodoStore, updater: UpdateController) {
        let workspace = SettingsWorkspaceController(model: model, todoStore: todoStore, updater: updater)
        let window = NSWindow(contentViewController: workspace)
        window.title = AppEnvironment.displayName + L(" Settings")
        window.setContentSize(SettingsWindowSizing.contentSize())
        window.contentMinSize = SettingsWindowSizing.minimumSize()
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        workspace.installToolbar(on: window)
        window.appearance = model.appearanceMode.windowAppearance
        window.center()
        super.init(window: window)
        window.delegate = self
        let applyAppearance = model.onAppearanceChanged
        model.onAppearanceChanged = { [weak window] mode in
            applyAppearance?(mode)
            window?.appearance = mode.windowAppearance
        }
        languageSubscription = AppLocalization.shared.$language.sink { [weak window, weak model] _ in
            // Published values are delivered before storage changes.
            DispatchQueue.main.async {
                window?.title = AppEnvironment.displayName + L(" Settings")
                model?.refresh()
            }
        }
        shouldCascadeWindows = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        if let window {
            window.contentMinSize = SettingsWindowSizing.minimumSize()
            let size = window.contentView?.frame.size ?? window.contentLayoutRect.size
            window.setContentSize(NSSize(width: max(size.width, window.contentMinSize.width), height: max(size.height, window.contentMinSize.height)))
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

enum SettingsWindowSizing {
    // Keep the keyboard and grouped sidebar visible together, including at larger text sizes.
    static func contentSize(fontSize: CGFloat = NSFont.preferredFont(forTextStyle: .body).pointSize) -> NSSize {
        let scale = max(1, fontSize / 13)
        return NSSize(width: 1100 * scale, height: 820 * scale)
    }

    static func minimumSize(fontSize: CGFloat = NSFont.preferredFont(forTextStyle: .body).pointSize) -> NSSize {
        let size = contentSize(fontSize: fontSize)
        return NSSize(width: size.width * (900.0 / 1100), height: size.height * (700.0 / 820))
    }
}

private enum SettingsMetrics {
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space6: CGFloat = 24
    static let labelWidth: CGFloat = 132
    static let rowHeight: CGFloat = 40
}

private struct FlatSettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.space2) {
            Text(title)
                .font(.headline)
            content
                .padding(.horizontal, SettingsMetrics.space4)
                .padding(.vertical, SettingsMetrics.space2)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.rowHeight, alignment: .leading)
    }
}

private struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        SettingsRow {
            HStack(spacing: SettingsMetrics.space3) {
                Text(title)
                    .frame(width: SettingsMetrics.labelWidth, alignment: .leading)
                Slider(value: $value, in: range)
                Text("\(Int(value * 100))%")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var isEnabled = true

    var body: some View {
        SettingsRow {
            HStack(spacing: SettingsMetrics.space3) {
                Text(title)
                Spacer(minLength: SettingsMetrics.space3)
                Toggle(title, isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .disabled(!isEnabled)
    }
}

private struct SettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, SettingsMetrics.space2)
    }
}

enum GeneralSettingsScope { case all, pet, system }

struct GeneralSettingsView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var model: TypingPetSettingsModel
    @ObservedObject var updater: UpdateController
    var scope: GeneralSettingsScope = .all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.space6) {
                if scope != .system {
                    FlatSettingsSection(L("Pet")) {
                        VStack(spacing: 0) {
                            SettingsSliderRow(
                                title: L("Size"),
                                value: Binding(get: { model.scale }, set: model.setScale),
                                range: 0.35...1.25
                            )
                            Divider()
                            SettingsSliderRow(
                                title: L("Resting opacity"),
                                value: Binding(get: { model.restingOpacity }, set: model.setRestingOpacity),
                                range: 0...1
                            )
                            Divider()
                            SettingsSliderRow(
                                title: L("Hover opacity"),
                                value: Binding(get: { model.hoverOpacity }, set: model.setHoverOpacity),
                                range: 0...1
                            )
                            Divider()
                            SettingsNote(text: L("100% is fully visible. 0% is completely transparent."))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                            SettingsRow {
                                HStack(spacing: SettingsMetrics.space3) {
                                    Text(L("Bounce strength"))
                                    Spacer(minLength: SettingsMetrics.space3)
                                    Picker("", selection: Binding(get: { model.shakeLevel }, set: model.setShakeLevel)) {
                                        Text(L("Off")).tag(0)
                                        Text(L("Gentle")).tag(1)
                                        Text(L("Medium")).tag(2)
                                        Text(L("Strong")).tag(3)
                                    }
                                    .labelsHidden()
                                    .frame(width: 112, alignment: .trailing)
                                }
                            }
                            Divider()
                            SettingsToggleRow(
                                title: L("Always on top"),
                                isOn: Binding(get: { model.alwaysOnTop }, set: model.setAlwaysOnTop)
                            )
                            Divider()
                            SettingsToggleRow(
                                title: L("Lock position (click through)"),
                                isOn: Binding(get: { model.positionLocked }, set: model.setPositionLocked)
                            )
                            Divider()
                            SettingsToggleRow(
                                title: L("Avoid pointer while locked"),
                                isOn: Binding(get: { model.avoidsPointerWhenLocked }, set: model.setPointerAvoidance),
                                isEnabled: model.positionLocked
                            )
                            Divider()
                            SettingsNote(text: L("Your pet smoothly moves aside when the pointer gets close, staying on screen."))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                }
                if scope != .pet {
                    FlatSettingsSection(L("System")) {
                        VStack(spacing: 0) {
                            SettingsRow {
                                HStack(spacing: SettingsMetrics.space3) {
                                    Text(L("Language"))
                                    Spacer(minLength: SettingsMetrics.space3)
                                    Picker(L("Language"), selection: Binding(
                                        get: { localization.mode },
                                        set: localization.setMode
                                    )) {
                                        Text(L("System")).tag(AppLanguageMode.system)
                                        Text(L("language.korean")).tag(AppLanguageMode.korean)
                                        Text(L("language.english")).tag(AppLanguageMode.english)
                                        Text(L("language.japanese")).tag(AppLanguageMode.japanese)
                                        Text(L("language.simplifiedChinese")).tag(AppLanguageMode.simplifiedChinese)
                                        Text(L("language.traditionalChinese")).tag(AppLanguageMode.traditionalChinese)
                                    }
                                    .labelsHidden()
                                    .frame(width: 200, alignment: .trailing)
                                }
                            }
                            Divider()
                            SettingsRow {
                                HStack(spacing: SettingsMetrics.space3) {
                                    Text(L("Appearance"))
                                    Spacer(minLength: SettingsMetrics.space3)
                                    Picker(L("Appearance"), selection: Binding(
                                        get: { model.appearanceMode },
                                        set: model.setAppearanceMode
                                    )) {
                                        Text(L("System")).tag(SettingsAppearanceMode.system)
                                        Text(L("Light")).tag(SettingsAppearanceMode.light)
                                        Text(L("Dark")).tag(SettingsAppearanceMode.dark)
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .frame(width: 252, alignment: .trailing)
                                }
                            }
                            Divider()
                            SettingsToggleRow(
                                title: L("Launch at login"),
                                isOn: Binding(get: { model.launchAtLogin }, set: model.toggleLaunchAtLogin)
                            )
                            Divider()
                            SettingsRow {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Label(model.inputMonitoringGranted ? L("Input Monitoring allowed") : L("Input Monitoring required"),
                                              systemImage: model.inputMonitoringGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                            .foregroundStyle(model.inputMonitoringGranted ? .green : .orange)
                                        Spacer(minLength: 12)
                                        Button(L("Check Again")) { model.refreshPermissions(retryConnection: true) }
                                    }
                                    HStack {
                                        Label(model.inputMonitoringConnected ? L("Keyboard monitoring connected") : L("Keyboard monitoring disconnected"),
                                              systemImage: model.inputMonitoringConnected ? "link" : "link.badge.plus")
                                            .font(.callout).foregroundStyle(.secondary)
                                        Spacer(minLength: 12)
                                        Button(L("Open System Settings")) { model.openInputMonitoringSettings() }
                                    }
                                }
                                .padding(.vertical, 10)
                            }
                            Divider()
                            SettingsNote(text: L("Only physical key codes and modifier keys are used to recognize shortcuts. Typed text is never stored or sent."))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    FlatSettingsSection(L("Updates")) {
                        VStack(spacing: 0) {
                            SettingsRow {
                                HStack(spacing: SettingsMetrics.space3) {
                                    VStack(alignment: .leading, spacing: SettingsMetrics.space1) {
                                        Text(L("Current version %1$@", updater.currentVersionText))
                                        Text(updater.statusText)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: SettingsMetrics.space3)
                                    if updater.isBusy { ProgressView().controlSize(.small) }
                                    Button(updater.menuTitle) { updater.performPrimaryAction() }
                                        .disabled(updater.isBusy || updater.unavailableReason != nil)
                                }
                                .padding(.vertical, SettingsMetrics.space2)
                            }
                            Divider()
                            SettingsToggleRow(
                                title: L("Check for updates automatically"),
                                isOn: $updater.automaticChecks,
                                isEnabled: updater.unavailableReason == nil
                            )
                        }
                    }

                }
            }
            .padding(22)
        }
        .onAppear { if scope != .pet { model.refreshPermissions() } }
        .task(id: scope) {
            guard scope != .pet else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { model.refreshPermissions() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if scope != .pet { model.refreshPermissions() }
        }
    }

}

struct TodoSettingsView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var store: TodoStore

    private var enabled: Bool { store.engine.state.featurePreferences.enabled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.space6) {
                FlatSettingsSection(L("Todos and Focus Timer")) {
                    VStack(spacing: 0) {
                        SettingsToggleRow(
                            title: L("Enable Todos"),
                            isOn: Binding(get: { enabled }, set: { value in
                                store.expanded = true
                                store.change { $0.setFeature(enabled: value, hidden: false) }
                            }),
                            isEnabled: !store.loadBlocked
                        )
                        Divider()
                        SettingsToggleRow(
                            title: L("Show bubble"),
                            isOn: Binding(
                                get: { !store.engine.state.featurePreferences.bubbleHidden },
                                set: { value in if value { store.show() } else { store.hide() } }
                            ),
                            isEnabled: enabled && !store.loadBlocked
                        )
                        Divider()
                        SettingsRow {
                            HStack(spacing: SettingsMetrics.space3) {
                                Text(L("Detect absence"))
                                Spacer(minLength: SettingsMetrics.space3)
                                Picker("", selection: Binding(get: { store.idleMinutes }, set: store.setIdleMinutes)) {
                                    ForEach(TodoStore.idleMinuteChoices, id: \.self) { minutes in
                                        Text(minutes == 0 ? L("Off") : (minutes < 60 ? L("After %1$@ min", minutes) : L("After %1$@ hr", minutes / 60))).tag(minutes)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 168, alignment: .trailing)
                            }
                        }
                        .disabled(!enabled || store.loadBlocked)
                        Divider()
                        SettingsNote(text: store.idleMinutes == 0
                            ? L("Hiding the bubble keeps the timer running. Sleep and quitting the app pause it.")
                            : L("While a timer is running, %1$@ without keyboard or mouse input, locking the screen, or sleep pauses it and excludes time since the last input. On return, choose whether to include that time. Hiding the bubble keeps the timer running.", store.idleMinutes < 60 ? L("%1$@ min", store.idleMinutes) : L("%1$@ hr", store.idleMinutes / 60)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                FlatSettingsSection(L("Bubble")) {
                    VStack(spacing: 0) {
                        SettingsRow {
                            HStack(spacing: SettingsMetrics.space3) {
                                Text(L("Size"))
                                    .frame(width: SettingsMetrics.labelWidth, alignment: .leading)
                                Spacer(minLength: SettingsMetrics.space3)
                                HStack(spacing: SettingsMetrics.space1) {
                                    ZoomStepButton(symbol: "minus", label: L("Zoom Out"), enabled: store.canZoomOut) { store.zoomOut() }
                                    Text("\(store.zoomPercent)%")
                                        .monospacedDigit()
                                        .frame(width: 52)
                                        .accessibilityLabel(L("Bubble size %1$@%", store.zoomPercent))
                                    ZoomStepButton(symbol: "plus", label: L("Zoom In"), enabled: store.canZoomIn) { store.zoomIn() }
                                }
                                Button(L("Reset to 100%")) { store.resetZoom() }
                                    .disabled(store.zoom == 1)
                            }
                        }
                        Divider()
                        SettingsNote(text: L("Zoom in steps from 80% to 200%, like a browser. While typing in the bubble, use ⌘+, ⌘−, or ⌘0."))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        SettingsRow {
                            HStack(spacing: SettingsMetrics.space3) {
                                Text(L("List view"))
                                Spacer(minLength: SettingsMetrics.space3)
                                Picker("", selection: Binding(get: { store.listStyle }, set: store.setListStyle)) {
                                    Text(L("Full")).tag(TodoListStyle.full)
                                    Text(L("Compact")).tag(TodoListStyle.compact)
                                }
                                .labelsHidden()
                                .frame(width: 168, alignment: .trailing)
                            }
                        }
                        Divider()
                        SettingsNote(text: L("Compact view shows up to three Todos on single lines. Check them off directly, or right-click to control timers. To add or edit, hover over the bubble and click ⤢ for the full view."))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        SettingsRow {
                            HStack(spacing: SettingsMetrics.space3) {
                                Text(L("Visibility"))
                                Spacer(minLength: SettingsMetrics.space3)
                                Picker("", selection: Binding(get: { store.bubbleVisibility }, set: store.setBubbleVisibility)) {
                                    Text(L("Always")).tag(TodoBubbleVisibility.always)
                                    Text(L("On hover")).tag(TodoBubbleVisibility.hover)
                                }
                                .labelsHidden()
                                .frame(width: 168, alignment: .trailing)
                            }
                        }
                        Divider()
                        SettingsSliderRow(
                            title: L("Resting opacity"),
                            value: Binding(get: { store.bubbleRestingOpacity }, set: store.setBubbleRestingOpacity),
                            range: 0...1
                        )
                        .disabled(store.bubbleVisibility == .hover)
                        Divider()
                        SettingsSliderRow(
                            title: L("Hover opacity"),
                            value: Binding(get: { store.bubbleHoverOpacity }, set: store.setBubbleHoverOpacity),
                            range: 0...1
                        )
                        Divider()
                        SettingsNote(text: store.bubbleVisibility == .always
                            ? L("100% is fully visible. 0% is completely transparent. Hovering over the pet or bubble uses the hover opacity. While editing or when a timer finishes, the bubble stays fully visible.")
                            : L("Hover over the pet to reveal the bubble at its hover opacity. It stays visible while the pointer is over it. While editing or when a timer finishes, it stays fully visible."))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                FlatSettingsSection(L("Records")) {
                    VStack(spacing: 0) {
                        SettingsRow {
                            HStack(spacing: SettingsMetrics.space3) {
                                Text(L("Record file"))
                                Spacer(minLength: SettingsMetrics.space3)
                                Button(L("Show Record Data")) { NSWorkspace.shared.activateFileViewerSelecting([store.storage.url]) }
                            }
                        }
                        Divider()
                        Text(store.storage.url.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, SettingsMetrics.space2)
                        SettingsNote(text: L("Todo titles, completion dates, timer preferences, and measured focus time are stored in a JSON file on this Mac."))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let error = store.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(22)
        }
    }
}

// Both steps share one frame, so the minus and plus buttons render at the same size.
private struct ZoomStepButton: View {
    let symbol: String
    let label: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 16)
        }
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
