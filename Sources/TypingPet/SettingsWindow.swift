import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

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
    @Published private(set) var launchAtLogin: Bool
    @Published var errorMessage: String?

    let library: PetImageLibrary
    let keyStore: KeyReactionStore
    private let applyScale: (CGFloat) -> Void
    private let applyRestingOpacity: (CGFloat) -> Void
    private let applyHoverOpacity: (CGFloat) -> Void
    private let applyShake: (Int) -> Void
    private let applyAlwaysOnTop: (Bool) -> Void
    private let applyPositionLock: (Bool) -> Void
    private let reloadPet: () -> Void

    init(
        library: PetImageLibrary,
        keyStore: KeyReactionStore,
        scale: CGFloat,
        restingOpacity: CGFloat,
        hoverOpacity: CGFloat,
        shakeLevel: Int,
        alwaysOnTop: Bool,
        positionLocked: Bool,
        applyScale: @escaping (CGFloat) -> Void,
        applyRestingOpacity: @escaping (CGFloat) -> Void,
        applyHoverOpacity: @escaping (CGFloat) -> Void,
        applyShake: @escaping (Int) -> Void,
        applyAlwaysOnTop: @escaping (Bool) -> Void,
        applyPositionLock: @escaping (Bool) -> Void,
        reloadPet: @escaping () -> Void
    ) {
        self.library = library
        self.keyStore = keyStore
        self.scale = Double(scale)
        self.restingOpacity = Double(restingOpacity)
        self.hoverOpacity = Double(hoverOpacity)
        self.shakeLevel = shakeLevel
        self.alwaysOnTop = alwaysOnTop
        self.positionLocked = positionLocked
        self.applyScale = applyScale
        self.applyRestingOpacity = applyRestingOpacity
        self.applyHoverOpacity = applyHoverOpacity
        self.applyShake = applyShake
        self.applyAlwaysOnTop = applyAlwaysOnTop
        self.applyPositionLock = applyPositionLock
        self.reloadPet = reloadPet
        activeSetID = library.activeSetID
        selectedSetID = library.activeSetID
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refresh()
    }

    var selectedSet: PetImageSet? { imageSets.first { $0.id == selectedSetID } }
    var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

    func thumbnail(for set: PetImageSet) -> NSImage? {
        library.idleURL(for: set).flatMap(NSImage.init(contentsOf:))
    }

    func ruleImage(for rule: KeyReactionRule) -> NSImage? {
        keyStore.imageURL(for: rule).flatMap(NSImage.init(contentsOf:))
    }

    func refresh() {
        imageSets = library.imageSets
        activeSetID = library.activeSetID
        rules = keyStore.rules
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
        panel.title = "이미지 세트 폴더 추가"
        panel.message = "idle.* 또는 pet-idle.*는 대기 이미지로, 나머지는 반응 이미지로 가져옵니다."
        panel.prompt = "갤러리에 추가"
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
        alert.messageText = "‘\(set.name)’ 세트를 목록에서 제거할까요?"
        alert.informativeText = "원본 이미지에는 영향을 주지 않습니다."
        alert.addButton(withTitle: "제거")
        alert.addButton(withTitle: "취소")
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
        alert.messageText = "이미지 세트 이름 변경"
        alert.accessoryView = field
        alert.addButton(withTitle: "변경")
        alert.addButton(withTitle: "취소")
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
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(model: TypingPetSettingsModel) {
        let root = SettingsRootView(model: model)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Typing Pet 설정"
        window.setContentSize(NSSize(width: 760, height: 570))
        window.minSize = NSSize(width: 680, height: 500)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct SettingsRootView: View {
    @ObservedObject var model: TypingPetSettingsModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model)
                .tabItem { Label("일반", systemImage: "gearshape") }
            GallerySettingsView(model: model)
                .tabItem { Label("갤러리", systemImage: "photo.on.rectangle.angled") }
            KeyReactionSettingsView(model: model)
                .tabItem { Label("키 반응", systemImage: "keyboard") }
        }
        .padding(18)
        .alert("오류", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) { Button("확인") { model.errorMessage = nil } } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: TypingPetSettingsModel

    var body: some View {
        Form {
            Section("펫") {
                HStack {
                    Text("크기")
                    Slider(value: Binding(get: { model.scale }, set: model.setScale), in: 0.35...1.25)
                    Text("\(Int(model.scale * 100))%").monospacedDigit().frame(width: 48)
                }
                HStack {
                    Text("상시 투명도")
                    Slider(value: Binding(get: { model.restingOpacity }, set: model.setRestingOpacity), in: 0...1)
                    Text("\(Int(model.restingOpacity * 100))%").monospacedDigit().frame(width: 48)
                }
                HStack {
                    Text("호버 시 투명도")
                    Slider(value: Binding(get: { model.hoverOpacity }, set: model.setHoverOpacity), in: 0...1)
                    Text("\(Int(model.hoverOpacity * 100))%").monospacedDigit().frame(width: 48)
                }
                Text("100%는 선명하게, 0%는 완전히 투명하게 표시됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("통통 튀는 정도", selection: Binding(get: { model.shakeLevel }, set: model.setShakeLevel)) {
                    Text("끔").tag(0); Text("약하게").tag(1); Text("보통").tag(2); Text("강하게").tag(3)
                }
                Toggle("항상 다른 창 위에 표시", isOn: Binding(get: { model.alwaysOnTop }, set: model.setAlwaysOnTop))
                Toggle("위치 잠금 (클릭 통과)", isOn: Binding(get: { model.positionLocked }, set: model.setPositionLocked))
            }
            Section("시스템") {
                Toggle("로그인 시 자동 실행", isOn: Binding(get: { model.launchAtLogin }, set: model.toggleLaunchAtLogin))
                HStack {
                    Label(
                        model.inputMonitoringGranted ? "입력 모니터링 권한 허용됨" : "입력 모니터링 권한 필요",
                        systemImage: model.inputMonitoringGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    ).foregroundStyle(model.inputMonitoringGranted ? .green : .orange)
                    Spacer()
                    Button("시스템 설정 열기") { model.openInputMonitoringSettings() }
                }
                Text("키 조합 판별에는 물리 키 코드와 보조 키만 사용하며, 입력 문자는 저장하거나 전송하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GallerySettingsView: View {
    @ObservedObject var model: TypingPetSettingsModel
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("이미지 세트").font(.title2).bold()
                Spacer()
                Button { model.importImageSet() } label: { Label("폴더 추가", systemImage: "plus") }
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.imageSets) { set in
                        GalleryCard(set: set, image: model.thumbnail(for: set), active: set.id == model.activeSetID, selected: set.id == model.selectedSetID)
                            .onTapGesture { model.selectedSetID = set.id }
                    }
                }.padding(3)
            }
            Divider()
            HStack {
                if let set = model.selectedSet {
                    Text("\(set.name) · 반응 이미지 \(model.library.reactionURLs(for: set).count)장")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("이름 변경") { model.renameSelectedSet() }.disabled(model.selectedSet?.isBuiltIn != false)
                Button("제거") { model.deleteSelectedSet() }.disabled(model.selectedSet?.isBuiltIn != false)
                Button("적용") { model.activateSelectedSet() }.buttonStyle(.borderedProminent).disabled(model.selectedSetID == model.activeSetID)
            }
        }
    }
}

private struct GalleryCard: View {
    let set: PetImageSet
    let image: NSImage?
    let active: Bool
    let selected: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)).frame(height: 112)
                if let image { Image(nsImage: image).resizable().scaledToFit().padding(8).frame(maxWidth: .infinity, maxHeight: 112) }
                if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).padding(7) }
            }
            Text(set.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.13) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
    }
}

private struct KeyReactionSettingsView: View {
    @ObservedObject var model: TypingPetSettingsModel
    @State private var pendingImageURL: URL?
    @State private var isCapturing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("특정 키 반응").font(.title2).bold()
                    Text("등록한 키 또는 키 조합에는 지정한 이미지가 우선 표시됩니다.").foregroundStyle(.secondary)
                }
                Spacer()
                Button { chooseImage() } label: { Label("규칙 추가", systemImage: "plus") }
            }
            if model.rules.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "keyboard").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("등록된 키 반응이 없습니다").font(.headline)
                    Text("규칙 추가를 눌러 이미지와 키 조합을 지정하세요.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.rules) { rule in
                    HStack(spacing: 12) {
                        Group {
                            if let image = model.ruleImage(for: rule) { Image(nsImage: image).resizable().scaledToFit() }
                            else { Image(systemName: "photo") }
                        }.frame(width: 46, height: 46)
                        Text(rule.stroke.displayName).font(.system(size: 16, weight: .semibold, design: .rounded))
                        Spacer()
                        Button(role: .destructive) { model.removeRule(rule) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }.padding(.vertical, 4)
                }
            }
        }
        .sheet(isPresented: $isCapturing) {
            KeyCaptureSheet { stroke in
                if let url = pendingImageURL { model.addRule(stroke: stroke, imageURL: url) }
                pendingImageURL = nil
                isCapturing = false
            } onCancel: {
                pendingImageURL = nil
                isCapturing = false
            }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "키 반응 이미지 선택"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingImageURL = url
        isCapturing = true
    }
}

private struct KeyCaptureSheet: View {
    let onCapture: (KeyStroke) -> Void
    let onCancel: () -> Void
    @State private var captured: KeyStroke?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard.badge.ellipsis").font(.system(size: 42)).foregroundStyle(.tint)
            Text("사용할 키 또는 키 조합을 누르세요").font(.title3).bold()
            Text(captured?.displayName ?? "예: K, ⌘K, ⌃⌥Space")
                .font(.system(size: 22, weight: .semibold, design: .rounded)).frame(minHeight: 32)
            KeyCaptureView { captured = $0 }.frame(width: 1, height: 1)
            HStack {
                Button("취소", action: onCancel)
                Button("등록") { if let captured { onCapture(captured) } }
                    .buttonStyle(.borderedProminent).disabled(captured == nil)
            }
        }.padding(32).frame(width: 420, height: 260)
    }
}

private struct KeyCaptureView: NSViewRepresentable {
    let onCapture: (KeyStroke) -> Void

    func makeNSView(context: Context) -> CaptureNSView {
        let view = CaptureNSView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: CaptureNSView, context: Context) { nsView.onCapture = onCapture }

    final class CaptureNSView: NSView {
        var onCapture: ((KeyStroke) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in if let self { self.window?.makeFirstResponder(self) } }
        }
        override func keyDown(with event: NSEvent) {
            let modifiers = KeyModifiers(eventFlags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
            onCapture?(KeyStroke(keyCode: event.keyCode, modifiers: modifiers))
        }
    }
}
