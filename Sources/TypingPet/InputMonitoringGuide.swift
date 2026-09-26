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
    private let model = InputMonitoringGuideModel()
    private let onPermissionGranted: () -> Void
    private var panel: NSPanel?
    private var permissionTimer: Timer?
    private var windowTrackingTimer: Timer?
    private var didReportPermission = false

    init(appURL: URL = Bundle.main.bundleURL, onPermissionGranted: @escaping () -> Void) {
        self.appURL = appURL
        location = TypingPetAppLocation.detect(appURL: appURL)
        self.onPermissionGranted = onPermissionGranted
        super.init()
    }

    func show() {
        model.isGranted = CGPreflightListenEventAccess()
        didReportPermission = false

        let panel = panel ?? makePanel()
        self.panel = panel
        positionAtScreenCorner(panel)
        panel.orderFrontRegardless()
        startPermissionTimer()
        startWindowTrackingTimer()
        followSystemSettingsWindow()
        refreshPermission()
    }

    func hide() {
        stopTimers()
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stopTimers()
    }

    @objc private func refreshPermission() {
        let granted = CGPreflightListenEventAccess()
        model.isGranted = granted
        guard granted, !didReportPermission else { return }

        didReportPermission = true
        permissionTimer?.invalidate()
        permissionTimer = nil
        onPermissionGranted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.hide()
        }
    }

    private func makePanel() -> NSPanel {
        let panelHeight: CGFloat = location == .applications ? 292 : 336
        let rootView = InputMonitoringGuideView(
            model: model,
            appURL: appURL,
            location: location,
            panelHeight: panelHeight,
            openSettings: { InputMonitoringSettings.open() },
            checkPermission: { [weak self] in self?.refreshPermission() },
            close: { [weak self] in self?.hide() }
        )
        let hostingController = NSHostingController(rootView: rootView)
        let panel = NSPanel(contentViewController: hostingController)
        panel.setContentSize(NSSize(width: 404, height: panelHeight))
        panel.styleMask = [.titled, .closable, .utilityWindow, .fullSizeContentView, .nonactivatingPanel]
        panel.title = "Typing Pet 입력 모니터링 안내"
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
        guard let panel,
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

    private func startWindowTrackingTimer() {
        windowTrackingTimer?.invalidate()
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

}

private extension CGRect {
    var area: CGFloat {
        isNull || isInfinite ? 0 : width * height
    }
}

@MainActor
private final class InputMonitoringGuideModel: ObservableObject {
    @Published var isGranted = false
}

private struct InputMonitoringGuideView: View {
    @ObservedObject var model: InputMonitoringGuideModel
    let appURL: URL
    let location: TypingPetAppLocation
    let panelHeight: CGFloat
    let openSettings: () -> Void
    let checkPermission: () -> Void
    let close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFloating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Typing Pet을 목록에 추가하세요")
                    .font(.title3.bold())
                Text("앱 아이콘을 입력 모니터링 목록으로 드래그한 뒤 오른쪽 스위치를 켜세요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                DraggableAppIcon(appURL: appURL)
                    .frame(width: 76, height: 76)
                    .offset(y: reduceMotion ? 0 : (isFloating ? -4 : 4))
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 1.15).repeatForever(autoreverses: true),
                        value: isFloating
                    )

                Image(systemName: "arrow.right")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("입력 모니터링 목록")
                        .font(.headline)
                    Text("① 아이콘 추가\n② 스위치 켜기")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            )

            if location != .applications {
                Label(locationWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("드래그가 안 되면 입력 모니터링 목록 아래의 + 버튼을 누르고 TypingPet.app을 선택하세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Label(
                    model.isGranted ? "권한이 확인되었습니다" : "권한을 기다리는 중",
                    systemImage: model.isGranted ? "checkmark.circle.fill" : "clock"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(model.isGranted ? .green : .secondary)

                Spacer()

                Button("설정 창 열기", action: openSettings)
                    .buttonStyle(.borderedProminent)
                Button("다시 확인", action: checkPermission)
                Button("나중에", action: close)
            }
        }
        .padding(24)
        .frame(width: 404, height: panelHeight, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .onAppear { isFloating = true }
    }

    private var locationWarning: String {
        switch location {
        case .applications:
            return ""
        case .outsideApplications:
            return "현재 앱이 Applications 폴더 밖에서 실행 중입니다. 먼저 Applications로 옮긴 뒤 추가하는 것을 권장합니다."
        case .translocated:
            return "현재 앱이 임시 보안 위치에서 실행 중입니다. Applications 폴더로 옮겨 다시 실행한 뒤 추가해 주세요."
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
        toolTip = "TypingPet.app을 입력 모니터링 목록으로 드래그"
        setAccessibilityLabel("드래그 가능한 TypingPet.app")
        setAccessibilityHelp("입력 모니터링 목록으로 드래그하여 앱을 추가합니다.")
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
