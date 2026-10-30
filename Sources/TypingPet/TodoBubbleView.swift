import AppKit
import Combine
import SwiftUI

private enum TodoTimeText {
    static func clock(_ seconds: Double, countdown: Bool) -> String {
        let value = Int(countdown ? ceil(max(0, seconds)) : floor(max(0, seconds)))
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
    // Same wording as the timer button in the full view.
    static func start(_ preference: TimerPreference) -> String {
        preference.mode == .countup ? L("Start Count Up") : L("Start %1$@ min", Int((preference.seconds ?? 1200) / 60))
    }
    static func total(_ seconds: Double) -> String {
        let minutes = Int(max(0, seconds)) / 60
        if minutes < 60 { return L("Total %1$@ min", minutes) }
        return String(format: L("Total %d hr %02d min"), minutes / 60, minutes % 60)
    }
    // Both 분 and 시간 end in a final consonant, so the topic particle is always 은.
    static func away(_ seconds: Double) -> String {
        let minutes = Int(max(0, seconds)) / 60
        guard minutes > 0 else { return L("Time away was excluded") }
        let length = minutes < 60 ? L("%1$@ min", minutes) : (minutes % 60 == 0 ? L("%1$@ hr", minutes / 60) : L("%1$@ hr %2$@ min", minutes / 60, minutes % 60))
        return L("Excluded %1$@ away", length)
    }
    static func awayReason(_ reason: TodoAbsence.Reason) -> String {
        switch reason {
        case .idle: return L("Away")
        case .locked: return L("Screen locked")
        case .sleep: return L("Sleep")
        }
    }
    // Pick 을/를 from the last Hangul syllable. Other scripts get both forms.
    static func objectParticle(after title: String) -> String {
        guard let scalar = title.unicodeScalars.last, (0xAC00...0xD7A3).contains(scalar.value) else { return L("object.particle.unknown") }
        return (scalar.value - 0xAC00) % 28 == 0 ? L("object.particle.vowel") : L("object.particle.consonant")
    }
    // Quotes inside sentences stay short so a long title cannot swallow the message.
    static func quoted(_ title: String, limit: Int = 24) -> String {
        title.count > limit ? String(title.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : title
    }
    @MainActor private static let cachedDayFormatter = DateFormatter()
    @MainActor private static var cachedDayLanguage: String?
    @MainActor static var day: DateFormatter {
        let language = AppLocalization.shared.language
        if cachedDayLanguage != language {
            cachedDayLanguage = language
            cachedDayFormatter.locale = AppLocalization.shared.locale
            cachedDayFormatter.dateFormat = L("EEEE, MMM d")
        }
        return cachedDayFormatter
    }
}

// MARK: - Palette and zoom

private extension NSColor {
    static func bubble(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}

// Cool neutral grays without a blue cast, and an ink accent. Tomato red marks timer elements only.
private enum BubbleNSColor {
    static let ink = NSColor.bubble(0x1C1C1E, 0xF0F0F2)
    static let muted = NSColor.bubble(0x6E6E73, 0xA1A1A6)
}

private enum BubbleColor {
    static let surface = Color(nsColor: .bubble(0xFCFCFC, 0x1F1F21))
    static let well = Color(nsColor: .bubble(0xF1F1F2, 0x2B2B2E))
    static let line = Color(nsColor: .bubble(0xE3E3E5, 0x3A3A3D))
    static let ink = Color(nsColor: BubbleNSColor.ink)
    static let muted = Color(nsColor: BubbleNSColor.muted)
    static let faint = Color(nsColor: .bubble(0xABABB0, 0x636367))
    static let accent = Color(nsColor: .bubble(0x2C2C2E, 0xE5E5E7))
    static let onAccent = Color(nsColor: .bubble(0xFFFFFF, 0x1C1C1E))
    static let tomato = Color(nsColor: .bubble(0xEE5843, 0xFF6E59))
    static let tomatoWash = Color(nsColor: .bubble(0xFDEEEE, 0x42292D))
    static let done = Color(nsColor: .bubble(0x3E9C66, 0x5DBE86))
}

private struct BubbleZoomKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
private struct BubblePointerKey: EnvironmentKey { static let defaultValue: BubblePointer? = nil }

private extension EnvironmentValues {
    var bubbleZoom: CGFloat {
        get { self[BubbleZoomKey.self] }
        set { self[BubbleZoomKey.self] = newValue }
    }
    // Not observed directly; views subscribe and update only when their own hover changes.
    var bubblePointer: BubblePointer? {
        get { self[BubblePointerKey.self] }
        set { self[BubblePointerKey.self] = newValue }
    }
}

// Scale design values instead of transforming views, so text stays sharp and text fields keep working.
private struct Z {
    let zoom: CGFloat
    func callAsFunction(_ value: CGFloat) -> CGFloat { value * zoom }
    func font(_ size: CGFloat, _ weight: Font.Weight = .regular, _ design: Font.Design = .default) -> Font {
        .system(size: size * zoom, weight: weight, design: design)
    }
}

// MARK: - Bubble

struct TodoBubbleView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var store: TodoStore
    @ObservedObject var layout: TodoBubbleLayout
    @State private var draft = ""
    @State private var completedExpanded = false
    @State private var pendingStart: UUID?
    @State private var pendingDelete: UUID?
    @State private var editingID: UUID?
    // Live draft of the edited title, for the length counter.
    @State private var editingTitle = ""
    @State private var titleFocusID: UUID?
    @State private var titleFocusToken = 0
    @State private var addRowHeight: CGFloat = 0
    @State private var completing: Set<UUID> = []
    @State private var extensionPreference = TimerPreference()
    @State private var lastOpenCount = 0
    @State private var listContentHeight: CGFloat = 0
    @State private var focusHovering = false
    @State private var addHovering = false
    @State private var compactHovering = false
    @State private var zoomBadgeVisible = false
    @State private var zoomBadgeToken = 0
    @State private var hops: CGFloat = 0
    @FocusState private var addFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Mode { case list, compactList, focus, away, expired }
    static let motion = Animation.spring(response: 0.34, dampingFraction: 0.86)

    private var zoom: CGFloat { CGFloat(store.zoom) }
    private var z: Z { Z(zoom: zoom) }
    private var session: FocusSession? { store.engine.activeSession }
    private var mode: Mode {
        let list: Mode = store.listStyle == .compact ? .compactList : .list
        guard let session else { return list }
        // The full list's active card has room for an ending or an absence. The compact list does not,
        // so those show their own bubble until answered, then the compact list returns.
        if store.expanded, store.listStyle == .full { return .list }
        if session.status == .expired { return .expired }
        if store.absence != nil { return .away }
        return store.expanded ? list : .focus
    }
    private var paused: Bool { session?.status == .paused }
    private var expired: Bool { session?.status == .expired }
    private var activeTitle: String {
        store.engine.state.todos.first { $0.id == session?.todoId }?.title ?? ""
    }
    private var clockText: String {
        TodoTimeText.clock(store.engine.displaySeconds, countdown: session?.modeAtStart == .countdown)
    }
    // Remaining share of the current countdown segment.
    private var ringFraction: Double {
        guard let segment = session?.activeSegments.last, let configured = segment.configuredSeconds, configured > 0 else { return 0 }
        return store.engine.displaySeconds / configured
    }
    // A ring means a time limit. Count-up has none, so it shows the tomato alone in the same place.
    private var showsRing: Bool { session?.modeAtStart == .countdown }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        bubble
            .modifier(DockBounce(progress: hops, height: layout.bounceHeight, edge: layout.tailEdge))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
            .padding(TodoBubbleLayout.shadowMargin)
            .background(zoomShortcuts)
            .environment(\.bubbleZoom, zoom)
            .environment(\.bubblePointer, layout.pointer)
            .environment(\.locale, localization.locale)
            .onExitCommand(perform: handleEscape)
            .onChange(of: session?.status) { status in
                if status == .expired { resetExtension() }
            }
            .onAppear { if session?.status == .expired { resetExtension() } }
            .onChange(of: layout.focusRequest) { _ in
                if mode == .list { DispatchQueue.main.async { focusInput() } }
            }
            .onChange(of: store.zoom) { _ in flashZoomBadge() }
            .onChange(of: layout.bounce) { _ in
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: DockBounce.duration(height: layout.bounceHeight))) { hops += 1 }
            }
            // The notice appears from a timer tick, outside any animation.
            .animation(Self.motion, value: store.absence?.sessionID)
    }

    // The shape wraps the content, so it animates with it. The panel is a fixed canvas around it.
    private var bubble: some View {
        let shape = BubbleShape(edge: layout.tailEdge, offset: layout.tailOffset, tail: TodoBubbleLayout.tailLength * zoom,
                                radius: z(18), halfBase: z(11))
        return sizedContent
            .background(SizeReader { layout.reportContentSize($0) })
            .padding(tailInsets)
            .clipShape(shape)
            // Drawn with the shape instead of by the window, so it follows animations and does not
            // darken when the panel becomes key.
            .background(
                shape.fill(BubbleColor.surface)
                    .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 5)
                    .shadow(color: .black.opacity(0.06), radius: 1.5, x: 0, y: 0.5)
            )
            .overlay(BubbleShape(edge: layout.tailEdge, offset: layout.tailOffset, tail: TodoBubbleLayout.tailLength * zoom,
                                 radius: z(18), halfBase: z(11), inset: 0.5)
                .stroke(BubbleColor.line, lineWidth: 1))
            .overlay {
                if zoomBadgeVisible {
                    Text("\(store.zoomPercent)%")
                        .font(z.font(13, .bold, .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, z(12)).padding(.vertical, z(6))
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    // One view for every mode, so switching modes runs only the mode transition below.
    private var sizedContent: some View {
        // Error text needs a fixed width to wrap. Compact titles truncate at a narrower fixed width.
        let width: CGFloat? = store.errorMessage != nil || mode == .list ? z(320) : (mode == .compactList ? z(260) : nil)
        return modeContent
            .frame(width: width)
            .fixedSize(horizontal: width == nil, vertical: true)
    }

    @ViewBuilder private var modeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.errorMessage != nil { errorBanner }
            if !store.loadBlocked {
                switch mode {
                case .list: listView.transition(modeTransition)
                case .compactList: compactListView.transition(modeTransition)
                case .focus: focusView.transition(modeTransition)
                case .away: awayView.transition(modeTransition)
                case .expired: expiredView.transition(modeTransition)
                }
            }
        }
    }

    // The old content leaves quickly so it does not overlap the new one while the bubble reshapes.
    private var modeTransition: AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.1)),
                    removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    private var tailInsets: EdgeInsets {
        let tail = TodoBubbleLayout.tailLength * zoom
        switch layout.tailEdge {
        case .top: return EdgeInsets(top: tail, leading: 0, bottom: 0, trailing: 0)
        case .bottom: return EdgeInsets(top: 0, leading: 0, bottom: tail, trailing: 0)
        case .leading: return EdgeInsets(top: 0, leading: tail, bottom: 0, trailing: 0)
        case .trailing: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: tail)
        }
    }
    // Anchor the bubble at the pet so it grows and shrinks away from it.
    private var contentAlignment: Alignment {
        switch layout.tailEdge {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    // Shortcuts only reach the panel while it is key, which happens when the user types in it.
    private var zoomShortcuts: some View {
        ZStack {
            Button("") { store.zoomIn() }.keyboardShortcut("=", modifiers: .command)
            Button("") { store.zoomIn() }.keyboardShortcut("+", modifiers: .command)
            Button("") { store.zoomOut() }.keyboardShortcut("-", modifiers: .command)
            Button("") { store.resetZoom() }.keyboardShortcut("0", modifiers: .command)
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: List

    private var listView: some View {
        // The input sits on top, so the newest Todo appears right below it.
        let open = Array(store.engine.openTodos.reversed())
        let completed = store.engine.completedToday()
        return VStack(alignment: .leading, spacing: 0) {
            header(openCount: open.count, completedCount: completed.count)
                .padding(.leading, z(16)).padding(.trailing, z(10)).padding(.top, z(13)).padding(.bottom, z(9))
            if session != nil {
                activeCard.padding(.horizontal, z(10)).padding(.bottom, z(6))
            }
            addRow
                .padding(.horizontal, z(8)).padding(.bottom, z(4))
                .background(SizeReader { addRowHeight = $0.height })
            ScrollViewReader { proxy in
                CappedHeight(maxHeight: listCap) {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: z(1)) {
                            ForEach(open) { todo in
                                row(todo, completed: false).id(todo.id).transition(rowTransition)
                            }
                            if open.isEmpty { emptyState(hasCompleted: !completed.isEmpty).transition(.opacity) }
                            if !completed.isEmpty { completedSection(completed).transition(.opacity) }
                        }
                        .padding(.horizontal, z(8))
                        .padding(.bottom, z(10))
                        .background(SizeReader { listContentHeight = $0.height })
                    }
                    // A scroller would flash while rows animate in a list that still fits.
                    .modifier(ScrollIndicatorsWhenNeeded(visible: listContentHeight > listCap + 1))
                }
                .onChange(of: open.count) { count in
                    // Bring a new Todo into view only when the list scrolls, after the rows settle.
                    if count > lastOpenCount, let newest = open.first?.id {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            guard listContentHeight > listCap + 1 else { return }
                            withAnimation(Self.motion) { proxy.scrollTo(newest, anchor: .top) }
                        }
                    }
                    lastOpenCount = count
                }
                .onAppear { lastOpenCount = open.count }
            }
        }
        .frame(minHeight: pendingStart == nil ? 0 : z(190), alignment: .top)
        .overlay { if let id = pendingStart { switchConfirmation(id) } }
        .onAppear { if layout.windowIsKey { DispatchQueue.main.async { addFocused = true } } }
    }

    // A new row fades in below the input while the rows under it slide down.
    // A removed row fades out before the rows below slide over its place.
    private var rowTransition: AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.08)),
                    removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    private var listCap: CGFloat {
        let chrome: CGFloat = session == nil ? 60 : (expired || store.absence != nil ? 168 : 124)
        return max(z(120), layout.maxContentHeight - z(chrome) - addRowHeight - (store.errorMessage == nil ? 0 : z(110)))
    }

    private func header(openCount: Int, completedCount: Int) -> some View {
        HStack(alignment: .center, spacing: z(2)) {
            VStack(alignment: .leading, spacing: z(1)) {
                HStack(spacing: z(6)) {
                    Text(L("Today's Todos")).font(z.font(15, .bold, .rounded)).foregroundStyle(BubbleColor.ink)
                    if AppEnvironment.isDevelopment {
                        Text("DEV").font(z.font(8.5, .heavy, .rounded)).foregroundStyle(.white)
                            .padding(.horizontal, z(5)).padding(.vertical, z(1.5))
                            .background(Capsule().fill(Color.purple.opacity(0.75)))
                    }
                }
                Text(subtitle(openCount: openCount, completedCount: completedCount))
                    .font(z.font(11)).foregroundStyle(BubbleColor.muted).monospacedDigit()
                    .contentTransition(.identity)
            }
            Spacer(minLength: z(4))
            if session != nil {
                IconButton(symbol: "chevron.down", label: L("Collapse to Focus Bubble")) { setExpanded(false) }
            }
            IconButton(symbol: "arrow.down.right.and.arrow.up.left", label: L("Switch to Compact View")) { setListStyle(.compact) }
            zoomMenu
            IconButton(symbol: "minus", label: L("Hide Todos")) { store.hide() }
        }
    }

    private var zoomMenu: some View {
        IconMenu(symbol: "textformat.size", help: L("Bubble size · %1$@%", store.zoomPercent), accessibilityLabel: L("Bubble size")) {
            Button(L("Zoom In")) { store.zoomIn() }.keyboardShortcut("+", modifiers: .command).disabled(!store.canZoomIn)
            Button(L("Zoom Out")) { store.zoomOut() }.keyboardShortcut("-", modifiers: .command).disabled(!store.canZoomOut)
            Button(L("Actual Size (100%)")) { store.resetZoom() }.keyboardShortcut("0", modifiers: .command).disabled(store.zoom == 1)
            Divider()
            Text(L("Current %1$@%", store.zoomPercent))
        }
        .accessibilityValue("\(store.zoomPercent)%")
    }

    private func subtitle(openCount: Int, completedCount: Int) -> String {
        let day = TodoTimeText.day.string(from: Date())
        if openCount > 0 { return L("%1$@ · %2$@ remaining", day, openCount) }
        return completedCount > 0 ? L("%1$@ · All done", day) : day
    }

    private var activeCard: some View {
        VStack(alignment: .leading, spacing: z(10)) {
            HStack(spacing: z(10)) {
                TomatoRing(fraction: ringFraction, paused: paused, size: 34, showsRing: showsRing)
                VStack(alignment: .leading, spacing: z(1)) {
                    Text(expired ? L("Time's up") : store.absence.map { TodoTimeText.awayReason($0.reason) } ?? (paused ? L("Paused") : L("Focusing")))
                        .font(z.font(10.5, .bold)).foregroundStyle(paused ? BubbleColor.muted : BubbleColor.tomato)
                    Text(activeTitle).font(z.font(12.5, .semibold)).foregroundStyle(BubbleColor.ink)
                        .lineLimit(1).help(activeTitle)
                }
                Spacer(minLength: z(4))
                Text(clockText).font(z.font(18, .semibold, .rounded)).monospacedDigit()
                    .foregroundStyle(paused ? BubbleColor.muted : BubbleColor.ink)
                // The notice below has the same choices.
                if !expired, store.absence == nil {
                    HStack(spacing: 0) {
                        IconButton(symbol: paused ? "play.fill" : "pause.fill", label: paused ? L("Resume") : L("Pause"), tint: BubbleColor.ink, size: 26) { togglePause() }
                        IconButton(symbol: "stop.fill", label: L("Stop"), tint: BubbleColor.ink, size: 26) { finish() }
                    }
                }
            }
            if expired { extensionControls }
            if let absence = store.absence { awayNotice(absence) }
        }
        .padding(z(10))
        .background(RoundedRectangle(cornerRadius: z(12), style: .continuous).fill(BubbleColor.tomatoWash))
    }

    private func row(_ todo: TodoItem, completed: Bool) -> some View {
        let total = store.engine.totalSeconds(for: todo.id)
        return TodoRow(
            todo: todo,
            completed: completed,
            checked: completed || completing.contains(todo.id),
            isActive: session?.todoId == todo.id,
            totalText: TodoTimeText.total(total),
            hasTime: total >= 60,
            isEditing: editingID == todo.id,
            confirmingDelete: pendingDelete == todo.id,
            draftCount: editingID == todo.id ? editingTitle.count : nil,
            focusToken: titleFocusID == todo.id ? titleFocusToken : 0,
            onToggle: { toggle(todo, completed: completed) },
            onStart: { requestStart(todo.id) },
            onSelectPreference: { preference in store.change { $0.setPreference(preference, for: todo.id) } },
            onBeginEdit: { beginEdit(todo) },
            onTitleBegin: {
                pendingDelete = nil
                editingTitle = todo.title
                editingID = todo.id
            },
            onTitleDraft: { editingTitle = $0 },
            onTitleEnd: { value in
                if editingID == todo.id { editingID = nil }
                if let value { store.change { $0.rename(todo.id, to: value) } }
            },
            onRequestDelete: { editingID = nil; pendingDelete = todo.id },
            onConfirmDelete: {
                withAnimation(Self.motion) { store.change { $0.delete(todo.id) } }
                pendingDelete = nil
            },
            onCancelDelete: { pendingDelete = nil }
        )
    }

    // MARK: Compact list

    // Widget-sized: up to three Todos with checkboxes and nothing else.
    // The controls appear on hover, like the focus bubble's. Adding, editing, and timers are in the full view.
    private var compactListView: some View {
        let open = Array(store.engine.openTodos.reversed())
        // The active Todo leads, so the timer's subject stays in view.
        let ordered = open.filter { $0.id == session?.todoId } + open.filter { $0.id != session?.todoId }
        let shown = Array(ordered.prefix(3))
        let allDone = open.isEmpty && !store.engine.completedToday().isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { todo in compactRow(todo).transition(rowTransition) }
            if open.count > shown.count {
                Button { setListStyle(.full) } label: {
                    Text(L("+%1$@ more", open.count - shown.count)).font(z.font(11.5, .medium)).foregroundStyle(BubbleColor.muted)
                        .monospacedDigit().contentTransition(.identity)
                        .padding(.leading, z(34)).frame(maxWidth: .infinity, minHeight: z(24), alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help(L("Show All in Full View"))
                .transition(.opacity)
            }
            if open.isEmpty {
                Button {
                    setListStyle(.full)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focusInput() }
                } label: {
                    HStack(spacing: z(8)) {
                        Image(systemName: allDone ? "checkmark" : "plus").font(z.font(11, .semibold)).frame(width: z(20))
                        Text(allDone ? L("All Todos done today") : L("Add a Todo for today")).font(z.font(12.5))
                    }
                    .foregroundStyle(BubbleColor.muted)
                    .padding(.horizontal, z(6)).frame(maxWidth: .infinity, minHeight: z(28), alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help(L("Add a Todo in Full View"))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, z(8)).padding(.vertical, z(8))
        .pointerHover { compactHovering = $0 }
        .overlay(alignment: .topTrailing) {
            if compactHovering {
                HStack(spacing: z(2)) {
                    if session != nil {
                        IconButton(symbol: "chevron.down", label: L("Collapse to Focus Bubble"), size: 22) { setExpanded(false) }
                    }
                    IconButton(symbol: "arrow.up.left.and.arrow.down.right", label: L("Switch to Full View"), size: 22) { setListStyle(.full) }
                }
                // Wide enough to cover the active Todo's clock in the first row.
                .padding(.leading, z(44)).padding(.trailing, z(8)).padding(.vertical, z(9))
                .background(LinearGradient(stops: [
                    .init(color: BubbleColor.surface.opacity(0), location: 0),
                    .init(color: BubbleColor.surface, location: 0.4)
                ], startPoint: .leading, endPoint: .trailing))
                .transition(.opacity)
            }
        }
        // Starting a Todo while another timer runs asks first, as in the full view.
        .frame(minHeight: pendingStart == nil ? 0 : z(190), alignment: .top)
        .overlay { if let id = pendingStart { switchConfirmation(id) } }
        .animation(.easeOut(duration: 0.15), value: compactHovering)
        .contextMenu {
            Button(L("Switch to Full View")) { setListStyle(.full) }
            if session != nil { Button(L("Collapse to Focus Bubble")) { setExpanded(false) } }
            Button(L("Hide Todos")) { store.hide() }
        }
        .accessibilityAction(named: L("Switch to Full View")) { setListStyle(.full) }
    }

    private func compactRow(_ todo: TodoItem) -> some View {
        let checked = completing.contains(todo.id)
        let active = session?.todoId == todo.id
        return HStack(spacing: z(8)) {
            CheckCircle(checked: checked, label: L("Complete %1$@", todo.title)) { toggle(todo, completed: false) }
            Text(todo.title).font(z.font(12.5)).foregroundStyle(checked ? BubbleColor.muted : BubbleColor.ink)
                .lineLimit(1).truncationMode(.tail).help(todo.title)
            Spacer(minLength: z(4))
            if active {
                HStack(spacing: z(4)) {
                    Circle().fill(paused ? BubbleColor.faint : BubbleColor.tomato).frame(width: z(5), height: z(5))
                    Text(clockText).font(z.font(11, .semibold, .rounded)).monospacedDigit()
                        .foregroundStyle(paused ? BubbleColor.muted : BubbleColor.tomato)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(paused ? L("Paused %1$@", clockText) : L("Focusing %1$@", clockText))
            }
        }
        .padding(.horizontal, z(6)).frame(minHeight: z(28))
        .contentShape(Rectangle())
        .contextMenu { compactMenu(todo) }
    }

    // Right-click controls the timer without opening the full view:
    // pause or stop the running Todo, or start another with its saved setting, count-up, or 20 minutes.
    @ViewBuilder private func compactMenu(_ todo: TodoItem) -> some View {
        if session?.todoId == todo.id {
            if expired {
                Button(L("Finish")) { finish() }
            } else {
                Button(paused ? L("Resume") : L("Pause")) { togglePause() }
                Button(L("Stop")) { finish() }
            }
        } else {
            let others = [TimerPreference.countup, TimerPreference(seconds: 1200)].filter { $0 != todo.timerPreference }
            ForEach(Array(([todo.timerPreference] + others).enumerated()), id: \.offset) { _, preference in
                Button(TodoTimeText.start(preference)) { startFromMenu(todo, with: preference) }
            }
        }
        Divider()
        Button(L("Complete")) { toggle(todo, completed: false) }
        Button(L("Switch to Full View")) { setListStyle(.full) }
    }

    private func emptyState(hasCompleted: Bool) -> some View {
        VStack(alignment: .leading, spacing: z(3)) {
            Text(hasCompleted ? L("All Todos done today!") : L("What will you start with today?"))
                .font(z.font(13, .semibold)).foregroundStyle(BubbleColor.ink)
            Text(hasCompleted ? L("Add any new tasks above.") : L("Type a title and press Enter to add it."))
                .font(z.font(11.5)).foregroundStyle(BubbleColor.muted)
        }
        .padding(.horizontal, z(10)).padding(.top, z(4)).padding(.bottom, z(6))
    }

    // A ghost input: just a faint plus and placeholder until the pointer or a draft gives it a light wash.
    private var addRow: some View {
        let hasDraft = !trimmedDraft.isEmpty
        return HStack(alignment: .top, spacing: z(8)) {
            Image(systemName: "plus").font(z.font(12, .semibold))
                .foregroundStyle(hasDraft || addHovering ? BubbleColor.muted : BubbleColor.faint)
                .frame(width: z(20), height: z(16))
            TextField(L("Add a Todo…"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(z.font(13))
                .foregroundStyle(BubbleColor.ink)
                .lineLimit(1...3)
                // A long draft scrolls inside three lines instead of spilling below them.
                .clipped()
                .focused($addFocused)
                .onSubmit(addTodo)
                .textCursorRegion()
                .onChange(of: draft) { value in
                    let limited = TodoTitlePolicy.limitedDraft(value)
                    if limited != value { draft = limited }
                }
                .accessibilityLabel(L("Add Todo"))
            if draft.count >= TodoTitlePolicy.warningLength {
                TitleCounter(count: draft.count)
            } else if hasDraft {
                Text(L("↩︎ Add")).font(z.font(10.5, .medium)).foregroundStyle(BubbleColor.faint)
                    .frame(height: z(16))
            }
        }
        .padding(.horizontal, z(8)).padding(.vertical, z(9))
        .background(RoundedRectangle(cornerRadius: z(10), style: .continuous)
            .fill(BubbleColor.well.opacity(hasDraft ? 0.8 : (addHovering ? 0.55 : 0))))
        .animation(.easeOut(duration: 0.15), value: hasDraft)
        .animation(.easeOut(duration: 0.15), value: addHovering)
        .contentShape(Rectangle())
        .onTapGesture { focusInput() }
        .pointerHover { addHovering = $0 }
    }

    private func completedSection(_ completed: [TodoItem]) -> some View {
        VStack(alignment: .leading, spacing: z(1)) {
            Rectangle().fill(BubbleColor.line).frame(height: 1).padding(.horizontal, z(8)).padding(.vertical, z(6))
            Button {
                withAnimation(Self.motion) { completedExpanded.toggle() }
            } label: {
                HStack(spacing: z(6)) {
                    Image(systemName: "chevron.right").font(z.font(9, .bold))
                        .rotationEffect(.degrees(completedExpanded ? 90 : 0))
                    Text(L("Completed Today")).font(z.font(12, .semibold))
                    Text("\(completed.count)").font(z.font(10.5, .bold, .rounded)).monospacedDigit()
                        .contentTransition(.identity)
                        .padding(.horizontal, z(6)).padding(.vertical, z(1))
                        .background(Capsule().fill(BubbleColor.well))
                    Spacer()
                }
                .foregroundStyle(BubbleColor.muted)
                .padding(.horizontal, z(8)).frame(height: z(28))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Completed today: %1$@", completed.count))
            .accessibilityValue(completedExpanded ? L("Expanded") : L("Collapsed"))
            if completedExpanded {
                ForEach(completed) { todo in row(todo, completed: true).transition(.opacity) }
            }
        }
    }

    private func switchConfirmation(_ id: UUID) -> some View {
        let nextTitle = store.engine.state.todos.first { $0.id == id }?.title ?? ""
        return ZStack {
            Rectangle().fill(BubbleColor.surface.opacity(0.7))
            VStack(alignment: .leading, spacing: z(8)) {
                Text(L("Switch timers?")).font(z.font(14, .bold, .rounded)).foregroundStyle(BubbleColor.ink)
                Text(L("Stop the timer for “%1$@” and start “%2$@”%3$@?", TodoTimeText.quoted(activeTitle), TodoTimeText.quoted(nextTitle), TodoTimeText.objectParticle(after: TodoTimeText.quoted(nextTitle))))
                    .font(z.font(12)).foregroundStyle(BubbleColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: z(8)) {
                    Spacer()
                    PillButton(title: L("Cancel")) { pendingStart = nil }
                    PillButton(title: L("Switch"), role: .timer) {
                        start(id, confirmed: true)
                        pendingStart = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, z(4))
            }
            .padding(z(14))
            .background(
                RoundedRectangle(cornerRadius: z(14), style: .continuous).fill(BubbleColor.surface)
                    .shadow(color: .black.opacity(0.14), radius: z(14), y: z(4))
            )
            .overlay(RoundedRectangle(cornerRadius: z(14), style: .continuous).strokeBorder(BubbleColor.line))
            .padding(z(14))
        }
        .transition(.opacity)
    }

    // MARK: Focus

    private var focusView: some View {
        Button { setExpanded(true) } label: {
            HStack(spacing: z(12)) {
                TomatoRing(fraction: ringFraction, paused: paused, size: 42, showsRing: showsRing)
                VStack(alignment: .leading, spacing: 0) {
                    Text(activeTitle).font(z.font(12, .medium)).foregroundStyle(BubbleColor.muted)
                        .lineLimit(1).frame(maxWidth: z(176), alignment: .leading)
                    HStack(alignment: .firstTextBaseline, spacing: z(6)) {
                        Text(clockText).font(z.font(26, .semibold, .rounded)).monospacedDigit()
                            .foregroundStyle(paused ? BubbleColor.muted : BubbleColor.ink)
                        if paused {
                            Text(L("Paused")).font(z.font(11, .semibold)).foregroundStyle(BubbleColor.muted)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, z(12)).padding(.trailing, z(16)).padding(.vertical, z(11))
            .frame(minWidth: z(226))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("%1$@ · Click to expand the list", activeTitle))
        .accessibilityLabel(L("%1$@, expand list", activeTitle))
        .accessibilityValue(clockText)
        .pointerHover { focusHovering = $0 }
        .overlay(alignment: .trailing) {
            if focusHovering {
                HStack(spacing: z(2)) {
                    IconButton(symbol: paused ? "play.fill" : "pause.fill", label: paused ? L("Resume") : L("Pause"), tint: BubbleColor.ink, size: 28) { togglePause() }
                    IconButton(symbol: "stop.fill", label: L("Stop"), tint: BubbleColor.ink, size: 28) { finish() }
                }
                .padding(.leading, z(26)).padding(.trailing, z(8))
                .frame(maxHeight: .infinity)
                .background(LinearGradient(stops: [
                    .init(color: BubbleColor.surface.opacity(0), location: 0),
                    .init(color: BubbleColor.surface, location: 0.4)
                ], startPoint: .leading, endPoint: .trailing))
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: focusHovering)
        .contextMenu {
            Button(L("Expand List")) { setExpanded(true) }
            Button(L("Hide Todos")) { store.hide() }
        }
    }

    private var expiredView: some View {
        VStack(alignment: .leading, spacing: z(12)) {
            HStack(spacing: z(12)) {
                TomatoRing(fraction: 0, paused: false, size: 42, pops: true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(activeTitle).font(z.font(12, .medium)).foregroundStyle(BubbleColor.muted)
                        .lineLimit(1).frame(maxWidth: z(190), alignment: .leading).help(activeTitle)
                    HStack(alignment: .firstTextBaseline, spacing: z(8)) {
                        Text("00:00").font(z.font(26, .semibold, .rounded)).monospacedDigit()
                            .foregroundStyle(BubbleColor.ink)
                        Text(L("Focus time is up")).font(z.font(11.5, .semibold)).foregroundStyle(BubbleColor.tomato)
                    }
                }
                Spacer(minLength: 0)
            }
            extensionControls
        }
        .padding(.horizontal, z(14)).padding(.vertical, z(13))
        .contextMenu {
            // The compact list cannot show an ending or an absence, so it comes back once they are answered.
            if store.listStyle == .full { Button(L("Expand List")) { setExpanded(true) } }
            Button(L("Hide Todos")) { store.hide() }
        }
    }

    // Same frame as the expired bubble: what happened, then what to do about it.
    private var awayView: some View {
        VStack(alignment: .leading, spacing: z(12)) {
            HStack(spacing: z(12)) {
                TomatoRing(fraction: ringFraction, paused: true, size: 42, showsRing: showsRing)
                VStack(alignment: .leading, spacing: 0) {
                    Text(activeTitle).font(z.font(12, .medium)).foregroundStyle(BubbleColor.muted)
                        .lineLimit(1).frame(maxWidth: z(190), alignment: .leading).help(activeTitle)
                    HStack(alignment: .firstTextBaseline, spacing: z(8)) {
                        Text(clockText).font(z.font(26, .semibold, .rounded)).monospacedDigit()
                            .foregroundStyle(BubbleColor.muted)
                        Text(store.absence.map { TodoTimeText.awayReason($0.reason) } ?? "")
                            .font(z.font(11.5, .semibold)).foregroundStyle(BubbleColor.ink)
                    }
                }
                Spacer(minLength: 0)
            }
            if let absence = store.absence { awayNotice(absence) }
        }
        .padding(.horizontal, z(14)).padding(.vertical, z(13))
        .contextMenu {
            // The compact list cannot show an ending or an absence, so it comes back once they are answered.
            if store.listStyle == .full { Button(L("Expand List")) { setExpanded(true) } }
            Button(L("Hide Todos")) { store.hide() }
        }
    }

    // Every answer resolves the absence: continue without it, continue with it, or end the session.
    // Until then the timer stays paused and the time stays out.
    private func awayNotice(_ absence: TodoAbsence) -> some View {
        VStack(alignment: .leading, spacing: z(8)) {
            Text(TodoTimeText.away(absence.awaySeconds(now: Date())))
                .font(z.font(11.5)).foregroundStyle(BubbleColor.muted).monospacedDigit()
                .contentTransition(.identity)
            HStack(spacing: z(8)) {
                PillButton(title: L("Resume Timing"), role: .timer) { withAnimation(Self.motion) { store.change { $0.resume() } } }
                    .help(L("Continue without counting time away"))
                PillButton(title: L("Include Time Away")) { withAnimation(Self.motion) { store.includeAbsence() } }
                    .help(L("Count time away and continue timing"))
                PillButton(title: L("Finish")) { finish() }
                    .help(L("End this focus session without counting time away"))
                Spacer(minLength: 0)
            }
        }
    }

    private var extensionControls: some View {
        HStack(spacing: z(8)) {
            TimerSplitButton(preference: extensionPreference, suffix: L("Extend"), allowsCountup: false, prominent: true,
                onSelect: { extensionPreference = $0 },
                onStart: { store.change { $0.extend(minutes: Int((extensionPreference.seconds ?? 1200) / 60)) } })
            PillButton(title: L("Finish")) { finish() }
            Spacer(minLength: 0)
        }
    }

    // MARK: Errors

    private var errorBanner: some View {
        VStack(alignment: .leading, spacing: z(8)) {
            Label(store.loadBlocked ? L("Could not read Todo records") : L("Could not save Todo records"), systemImage: "exclamationmark.triangle.fill")
                .font(z.font(13, .bold)).foregroundStyle(BubbleColor.tomato)
            ScrollView {
                Text(store.errorMessage ?? "").font(z.font(11.5)).foregroundStyle(BubbleColor.ink)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: store.loadBlocked ? z(220) : z(64))
            HStack(spacing: z(8)) {
                if !store.loadBlocked { PillButton(title: L("Save Again"), role: .primary) { store.persist() } }
                PillButton(title: L("Show Record Data")) { revealData() }
            }
        }
        .padding(z(12))
        .background(RoundedRectangle(cornerRadius: z(12), style: .continuous).fill(BubbleColor.tomatoWash))
        .padding(z(10))
    }

    // MARK: Actions

    private func handleEscape() {
        if pendingStart != nil { pendingStart = nil }
        else if pendingDelete != nil { pendingDelete = nil }
        else if !draft.isEmpty { draft = "" }
        else if session != nil, store.expanded { setExpanded(false) }
    }
    private func setExpanded(_ value: Bool) {
        withAnimation(Self.motion) { store.expanded = value }
    }
    private func setListStyle(_ style: TodoListStyle) {
        // Save a title being edited before its field goes away.
        if editingID != nil { layout.window?.makeFirstResponder(nil) }
        addFocused = false
        pendingStart = nil
        pendingDelete = nil
        withAnimation(Self.motion) { store.setListStyle(style) }
    }
    private func focusInput() {
        layout.window?.makeKey()
        addFocused = true
    }
    private func flashZoomBadge() {
        zoomBadgeToken += 1
        let token = zoomBadgeToken
        withAnimation(.easeOut(duration: 0.12)) { zoomBadgeVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard token == zoomBadgeToken else { return }
            withAnimation(.easeIn(duration: 0.2)) { zoomBadgeVisible = false }
        }
    }
    private func resetExtension() {
        extensionPreference = TimerPreference(seconds: session?.activeSegments.last?.configuredSeconds ?? 1200)
    }
    private func addTodo() {
        let value = draft
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        withAnimation(Self.motion) { store.change { _ = $0.addTodo(value) } }
    }
    // Show the check first, then move the row so the completion is visible.
    private func toggle(_ todo: TodoItem, completed: Bool) {
        if completed {
            withAnimation(Self.motion) { store.change { $0.setCompleted(todo.id, completed: false) } }
            return
        }
        guard !completing.contains(todo.id) else { return }
        completing.insert(todo.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(Self.motion) {
                store.change { $0.setCompleted(todo.id, completed: true) }
                completing.remove(todo.id)
            }
        }
    }
    // Menus ask the row's field to take focus. A click on the title focuses it directly.
    private func beginEdit(_ todo: TodoItem) {
        guard todo.completedAt == nil else { return }
        titleFocusID = todo.id
        titleFocusToken += 1
    }
    private func togglePause() {
        store.change { engine in
            if engine.activeSession?.status == .paused { engine.resume() } else { engine.pause() }
        }
    }
    // The menu choice becomes the Todo's setting, the same as choosing it in the full view's timer popover.
    private func startFromMenu(_ todo: TodoItem, with preference: TimerPreference) {
        if preference != todo.timerPreference { store.change { $0.setPreference(preference, for: todo.id) } }
        requestStart(todo.id)
    }
    private func requestStart(_ id: UUID) {
        if let current = session, current.todoId != id { withAnimation(.easeOut(duration: 0.15)) { pendingStart = id } }
        else { start(id, confirmed: false) }
    }
    // One transaction, so the list turns straight into the focus bubble without showing the active card first.
    private func start(_ id: UUID, confirmed: Bool) {
        addFocused = false
        withAnimation(Self.motion) {
            var started = false
            store.change { started = $0.start(id, replaceActive: confirmed) }
            // A compact list keeps showing the Todo with its timer; the full list folds into the focus bubble.
            if started { store.expanded = store.listStyle == .compact }
        }
    }
    private func finish() {
        withAnimation(Self.motion) {
            store.change { $0.finish() }
            store.expanded = true
        }
    }
    private func revealData() { NSWorkspace.shared.activateFileViewerSelecting([store.storage.url]) }
}

// The bounce of a Dock icon asking for attention, measured frame by frame from the macOS Dock:
// three parabolic hops, each half as high as the one before, lasting 0.50, 0.32, and 0.22 seconds.
// A lower bounce keeps the same gravity, so its timing shrinks with the square root of its height.
// One whole step of `progress` is one bounce. It rests on whole numbers, so adding to it never jumps.
private struct DockBounce: ViewModifier, Animatable {
    var progress: CGFloat
    let height: CGFloat
    let edge: TodoBubbleEdge
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private static let hops: [(height: CGFloat, duration: Double)] = [(1, 0.50), (0.5, 0.32), (0.25, 0.22)]
    private static let total = hops.reduce(0) { $0 + $1.duration }

    static func duration(height: CGFloat) -> Double {
        total * sqrt(Double(min(max(height, 0), TodoBubbleLayout.attentionHopHeight) / TodoBubbleLayout.attentionHopHeight))
    }

    private static func lift(at phase: Double, height: CGFloat) -> CGFloat {
        var time = phase * total
        for hop in hops {
            if time < hop.duration {
                let f = time / hop.duration
                return height * hop.height * CGFloat(4 * f * (1 - f))
            }
            time -= hop.duration
        }
        return 0
    }

    func body(content: Content) -> some View {
        let lift = Self.lift(at: Double(progress - progress.rounded(.down)), height: height)
        switch edge {
        case .bottom: return content.offset(x: 0, y: -lift)
        case .top: return content.offset(x: 0, y: lift)
        case .leading: return content.offset(x: lift, y: 0)
        case .trailing: return content.offset(x: -lift, y: 0)
        }
    }
}

// Preferences do not cross the hosting view and scroll view reliably, so report sizes directly.
private struct SizeReader: View {
    let onChange: (CGSize) -> Void
    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.size) }
                .onChange(of: proxy.size) { onChange($0) }
        }
    }
}

private struct ScrollIndicatorsWhenNeeded: ViewModifier {
    let visible: Bool
    func body(content: Content) -> some View {
        // `.hidden` still flashes on macOS when the content size changes.
        if #available(macOS 14, *) { content.scrollIndicators(visible ? .automatic : .never) }
        else { content.scrollIndicators(visible ? .automatic : .hidden) }
    }
}

// Hugs the scroll content up to the cap in the same layout pass, so height changes animate with the rows.
private struct CappedHeight: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, maxHeight))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

// MARK: - Row

private struct TodoRow: View {
    @ObservedObject private var localization = AppLocalization.shared
    let todo: TodoItem
    let completed: Bool
    let checked: Bool
    let isActive: Bool
    let totalText: String
    let hasTime: Bool
    let isEditing: Bool
    let confirmingDelete: Bool
    let draftCount: Int?
    let focusToken: Int
    let onToggle: () -> Void
    let onStart: () -> Void
    let onSelectPreference: (TimerPreference) -> Void
    let onBeginEdit: () -> Void
    let onTitleBegin: () -> Void
    let onTitleDraft: (String) -> Void
    let onTitleEnd: (String?) -> Void
    let onRequestDelete: () -> Void
    let onConfirmDelete: () -> Void
    let onCancelDelete: () -> Void
    @Environment(\.bubbleZoom) private var zoom
    @State private var hovering = false

    private var z: Z { Z(zoom: zoom) }

    var body: some View {
        Group {
            if confirmingDelete { deleteConfirmation } else { content }
        }
        .padding(.horizontal, z(8)).padding(.vertical, z(6))
        .background(RoundedRectangle(cornerRadius: z(10), style: .continuous).fill(background))
        .pointerHover { hovering = $0 }
        .contextMenu {
            if !completed { Button(L("Edit Title")) { onBeginEdit() } }
            Button(L("Delete…"), role: .destructive) { onRequestDelete() }
        }
    }

    private var background: Color {
        if confirmingDelete { return BubbleColor.tomatoWash }
        return hovering || isEditing ? BubbleColor.well : .clear
    }

    private var content: some View {
        HStack(alignment: .top, spacing: z(8)) {
            CheckCircle(checked: checked, label: "\(todo.title) \(completed ? L("Mark Incomplete") : L("Complete"))", action: onToggle)
            VStack(alignment: .leading, spacing: z(2)) {
                HStack(alignment: .top, spacing: z(4)) {
                    title.frame(maxWidth: .infinity, minHeight: z(20), alignment: .leading)
                    moreMenu
                }
                if !completed || hasTime { meta }
            }
        }
    }

    @ViewBuilder private var title: some View {
        if completed {
            Text(todo.title)
                .font(z.font(13, .medium))
                .foregroundStyle(BubbleColor.muted)
                .strikethrough(true, color: BubbleColor.muted)
                .lineLimit(2)
                .help(todo.title)
        } else {
            InlineTitleField(
                title: todo.title,
                font: .systemFont(ofSize: 13 * zoom, weight: .medium),
                color: checked ? BubbleNSColor.muted : BubbleNSColor.ink,
                focusToken: focusToken,
                tooltip: isEditing ? L("Enter to save · Esc to cancel") : L("%1$@\nClick to edit title", todo.title),
                onBegin: onTitleBegin,
                onDraft: onTitleDraft,
                onEnd: onTitleEnd
            )
            .textCursorRegion()
            .accessibilityLabel(L("Todo title"))
            .accessibilityValue(todo.title)
            .accessibilityHint(L("Press Enter to save edits, or Esc to cancel"))
            .accessibilityAction(named: L("Complete")) { onToggle() }
            .accessibilityAction(named: L("Start Timer")) { onStart() }
            .accessibilityAction(named: L("Delete")) { onRequestDelete() }
        }
    }

    private var meta: some View {
        HStack(alignment: .center, spacing: z(6)) {
            if let draftCount, draftCount >= TodoTitlePolicy.warningLength {
                TitleCounter(count: draftCount)
            } else {
                Text(totalText).font(z.font(11)).monospacedDigit()
                    .foregroundStyle(hasTime ? BubbleColor.muted : BubbleColor.faint)
            }
            Spacer(minLength: z(4))
            if isActive {
                HStack(spacing: z(4)) {
                    Circle().fill(BubbleColor.tomato).frame(width: z(5), height: z(5))
                    Text(L("Focusing")).font(z.font(11, .semibold))
                }
                .foregroundStyle(BubbleColor.tomato)
                .padding(.horizontal, z(8)).frame(height: z(22))
                .background(Capsule().fill(BubbleColor.tomatoWash))
            } else if !completed {
                TimerSplitButton(preference: todo.timerPreference, suffix: L("Start"), allowsCountup: true, prominent: hovering,
                    onSelect: onSelectPreference, onStart: onStart)
            }
        }
    }

    private var moreMenu: some View {
        IconMenu(symbol: "ellipsis", help: L("More"), accessibilityLabel: L("%1$@ menu", todo.title), size: 22, hoverFill: BubbleColor.line) {
            if !completed { Button(L("Edit Title")) { onBeginEdit() } }
            Button(L("Delete…"), role: .destructive) { onRequestDelete() }
        }
        .opacity(hovering ? 1 : 0)
    }

    private var deleteConfirmation: some View {
        HStack(spacing: z(8)) {
            VStack(alignment: .leading, spacing: z(2)) {
                Text(todo.title).font(z.font(12.5, .semibold)).foregroundStyle(BubbleColor.ink).lineLimit(1)
                Text(L("Delete this Todo? Focus records will be kept.")).font(z.font(11)).foregroundStyle(BubbleColor.muted)
            }
            Spacer(minLength: z(4))
            PillButton(title: L("Cancel"), action: onCancelDelete)
            PillButton(title: L("Delete"), role: .destructive, action: onConfirmDelete)
        }
        .frame(minHeight: z(42))
    }
}

// MARK: - Timer split button

private struct TimerSplitButton: View {
    @ObservedObject private var localization = AppLocalization.shared
    let preference: TimerPreference
    let suffix: String
    let allowsCountup: Bool
    let prominent: Bool
    let onSelect: (TimerPreference) -> Void
    let onStart: () -> Void
    @Environment(\.bubbleZoom) private var zoom
    @State private var showingOptions = false

    private var z: Z { Z(zoom: zoom) }
    private var buttonTitle: String {
        preference.mode == .countup ? L("Count up %1$@", suffix) : L("%1$@ min %2$@", Int((preference.seconds ?? 1200) / 60), suffix)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onStart) {
                HStack(spacing: z(4)) {
                    Image(systemName: "play.fill").font(z.font(7, .black))
                    Text(buttonTitle)
                }
                .padding(.leading, z(9)).padding(.trailing, z(7))
                .frame(height: z(24))
                .contentShape(Rectangle())
            }
            .accessibilityLabel(buttonTitle)
            Rectangle().fill(prominent ? Color.white.opacity(0.35) : BubbleColor.line).frame(width: 1, height: z(12))
            Button { showingOptions.toggle() } label: {
                Image(systemName: "chevron.right").font(z.font(8.5, .bold))
                    .frame(width: z(20), height: z(24))
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L("%1$@ timer settings", suffix))
            .help(L("Timer Settings"))
            .popover(isPresented: $showingOptions, arrowEdge: .trailing) {
                TimerOptions(preference: preference, allowsCountup: allowsCountup,
                    onSelect: { onSelect($0); showingOptions = false },
                    onCancel: { showingOptions = false })
                    .environment(\.bubbleZoom, zoom)
            }
        }
        .buttonStyle(PressStyle())
        .font(z.font(11.5, .semibold, .rounded))
        .foregroundStyle(prominent ? Color.white : BubbleColor.muted)
        .background(RoundedRectangle(cornerRadius: z(8), style: .continuous).fill(prominent ? BubbleColor.tomato : BubbleColor.well))
        .animation(.easeOut(duration: 0.15), value: prominent)
        .fixedSize()
    }
}

private struct TimerOptions: View {
    @ObservedObject private var localization = AppLocalization.shared
    let preference: TimerPreference
    let allowsCountup: Bool
    let onSelect: (TimerPreference) -> Void
    let onCancel: () -> Void
    @Environment(\.bubbleZoom) private var zoom
    @State private var custom = false
    @State private var minutes = ""
    @FocusState private var fieldFocused: Bool

    private var z: Z { Z(zoom: zoom) }
    private var customValue: TimerPreference? {
        Int(minutes.trimmingCharacters(in: .whitespaces)).flatMap(TimerPreference.countdown(minutes:))
    }
    private var presetSelected: Bool { [10, 20, 30].contains { preference == .countdown(minutes: $0) } }
    private var customSelected: Bool { preference.mode == .countdown && !presetSelected }

    var body: some View {
        Group {
            if custom { customForm } else { options }
        }
        .frame(width: z(188))
        // The popover inherits the split button's style, which is white while the button is highlighted.
        .foregroundStyle(BubbleColor.ink)
    }

    // Highlights are concentric with the popover: inner radius = popover radius - inset.
    private var popoverRadius: CGFloat {
        if #available(macOS 26, *) { return 18 }
        return 10
    }

    private var options: some View {
        let inset = z(6)
        let radius = max(4, popoverRadius - inset)
        return VStack(alignment: .leading, spacing: z(1)) {
            ForEach([10, 20, 30], id: \.self) { value in
                OptionRow(title: L("%1$@ min", value), checked: preference == .countdown(minutes: value), cornerRadius: radius) {
                    onSelect(.countdown(minutes: value)!)
                }
            }
            OptionRow(title: customSelected ? L("Custom · %1$@ min", Int((preference.seconds ?? 0) / 60)) : L("Custom…"), checked: customSelected, cornerRadius: radius) {
                minutes = String(Int((preference.seconds ?? 1200) / 60))
                custom = true
            }
            if allowsCountup {
                Rectangle().fill(BubbleColor.line).frame(height: 1).padding(.vertical, z(4)).padding(.horizontal, z(10))
                OptionRow(title: L("Count Up"), subtitle: L("From 00:00"), checked: preference.mode == .countup, cornerRadius: radius) { onSelect(.countup) }
            }
        }
        .padding(inset)
    }

    private var customForm: some View {
        VStack(alignment: .leading, spacing: z(8)) {
            Text(L("Custom")).font(z.font(12.5, .semibold))
            HStack(spacing: z(6)) {
                TextField("20", text: $minutes)
                    .textFieldStyle(.plain)
                    .font(z.font(13)).monospacedDigit()
                    .padding(.horizontal, z(8)).padding(.vertical, z(5))
                    .frame(width: z(64))
                    .background(RoundedRectangle(cornerRadius: z(6), style: .continuous).fill(BubbleColor.well))
                    .focused($fieldFocused)
                    .onChange(of: minutes) { value in
                        let limited = TodoTitlePolicy.limitedDraft(value)
                        if limited != value { minutes = limited }
                    }
                    .onSubmit(apply)
                Text(L("min")).font(z.font(13)).foregroundStyle(BubbleColor.muted)
            }
            Text(customValue == nil ? L("Enter a whole number from 1 to 999.") : L("Choose from 1 to 999 minutes."))
                .font(z.font(10.5))
                .foregroundStyle(customValue == nil ? BubbleColor.tomato : BubbleColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("Cancel"), action: onCancel)
                Spacer()
                Button(L("Apply"), action: apply).keyboardShortcut(.defaultAction).disabled(customValue == nil)
            }
        }
        .padding(z(12))
        .background(KeyWindowRequest())
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
    }

    private func apply() {
        guard let value = customValue else { return }
        onSelect(value)
    }
}

private struct TitleCounter: View {
    @ObservedObject private var localization = AppLocalization.shared
    let count: Int
    @Environment(\.bubbleZoom) private var zoom

    var body: some View {
        let z = Z(zoom: zoom)
        Text("\(count)/\(TodoTitlePolicy.maxLength)")
            .font(z.font(10.5, .medium)).monospacedDigit()
            .foregroundStyle(count >= TodoTitlePolicy.maxLength ? BubbleColor.tomato : BubbleColor.faint)
            .frame(height: z(16))
            .accessibilityLabel(L("%2$@ of %1$@ characters", TodoTitlePolicy.maxLength, count))
    }
}

private struct OptionRow: View {
    @ObservedObject private var localization = AppLocalization.shared
    let title: String
    var subtitle: String?
    let checked: Bool
    var cornerRadius: CGFloat = 6
    let action: () -> Void
    @Environment(\.bubbleZoom) private var zoom
    @State private var hovering = false

    var body: some View {
        let z = Z(zoom: zoom)
        Button(action: action) {
            HStack(spacing: z(6)) {
                Image(systemName: "checkmark").font(z.font(10, .bold))
                    .foregroundStyle(BubbleColor.accent).opacity(checked ? 1 : 0).frame(width: z(14))
                Text(title).font(z.font(12.5, checked ? .semibold : .regular))
                if let subtitle { Text(subtitle).font(z.font(11)).foregroundStyle(BubbleColor.muted) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, z(8))
            .frame(height: z(28))
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(hovering ? BubbleColor.well : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .trackingHover { hovering = $0 }
    }
}

// MARK: - Controls

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

private struct IconButton: View {
    @ObservedObject private var localization = AppLocalization.shared
    let symbol: String
    let label: String
    var tint: Color = BubbleColor.muted
    var size: CGFloat = 24
    let action: () -> Void
    @Environment(\.bubbleZoom) private var zoom
    @State private var hovering = false

    var body: some View {
        let side = size * zoom
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: side * 0.42, weight: .bold))
                .foregroundStyle(hovering ? BubbleColor.ink : tint)
                .frame(width: side, height: side)
                .background(Circle().fill(hovering ? BubbleColor.well : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .help(label)
        .accessibilityLabel(label)
        .pointerHover { hovering = $0 }
    }
}

// A menu that looks and reacts like IconButton: a round wash and a darker glyph on hover.
private struct IconMenu<Items: View>: View {
    @ObservedObject private var localization = AppLocalization.shared
    let symbol: String
    let help: String
    let accessibilityLabel: String
    var size: CGFloat = 24
    // Rows already use the well color on hover, so menus inside them need a darker wash to show.
    var hoverFill = BubbleColor.well
    @ViewBuilder let items: () -> Items
    @Environment(\.bubbleZoom) private var zoom
    @State private var hovering = false

    var body: some View {
        let side = size * zoom
        Menu(content: items) {
            Image(systemName: symbol)
                .font(.system(size: side * 0.42, weight: .bold))
                .foregroundStyle(hovering ? BubbleColor.ink : BubbleColor.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: side, height: side)
        .background(Circle().fill(hovering ? hoverFill : .clear))
        .contentShape(Circle())
        .pointerHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct PillButton: View {
    @ObservedObject private var localization = AppLocalization.shared
    enum Role { case secondary, primary, timer, destructive }
    let title: String
    var role: Role = .secondary
    let action: () -> Void
    @Environment(\.bubbleZoom) private var zoom
    @State private var hovering = false

    var body: some View {
        let z = Z(zoom: zoom)
        Button(action: action) {
            Text(title)
                .font(z.font(12, .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, z(11))
                .frame(height: z(26))
                .background(RoundedRectangle(cornerRadius: z(8), style: .continuous).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .pointerHover { hovering = $0 }
    }

    private var foreground: Color {
        switch role {
        case .secondary: return BubbleColor.ink
        case .primary: return BubbleColor.onAccent
        case .timer, .destructive: return .white
        }
    }

    private var fill: Color {
        switch role {
        case .primary: return BubbleColor.accent.opacity(hovering ? 0.88 : 1)
        case .timer, .destructive: return BubbleColor.tomato.opacity(hovering ? 0.88 : 1)
        case .secondary: return hovering ? BubbleColor.line : BubbleColor.well
        }
    }
}

private struct CheckCircle: View {
    @ObservedObject private var localization = AppLocalization.shared
    let checked: Bool
    let label: String
    let action: () -> Void
    @Environment(\.bubbleZoom) private var zoom
    @State private var hovering = false

    var body: some View {
        let z = Z(zoom: zoom)
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(checked ? BubbleColor.done : (hovering ? BubbleColor.muted : BubbleColor.faint), lineWidth: 1.5)
                Circle().fill(BubbleColor.done).scaleEffect(checked ? 1 : 0.2).opacity(checked ? 1 : 0)
                Image(systemName: "checkmark").font(z.font(8.5, .heavy))
                    .foregroundStyle(checked ? Color.white : BubbleColor.muted)
                    .opacity(checked ? 1 : (hovering ? 0.7 : 0))
            }
            .frame(width: z(18), height: z(18))
            .frame(width: z(20), height: z(20))
            .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .animation(.spring(response: 0.28, dampingFraction: 0.6), value: checked)
        .pointerHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

// The pet controls use the same dark translucent capsule.
struct TodoEntryButton: View {
    @ObservedObject private var localization = AppLocalization.shared
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "checklist").font(.system(size: 11, weight: .bold))
                Text(L("Todos")).font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(Color.black.opacity(hovering ? 0.78 : 0.62)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .help(L("Todos"))
        .accessibilityLabel(L("Todos"))
        .trackingHover { hovering = $0 }
    }
}

// MARK: - Tomato

private struct TomatoRing: View {
    let fraction: Double
    var paused = false
    let size: CGFloat
    var showsRing = true
    var pops = false
    @Environment(\.bubbleZoom) private var zoom
    @State private var popped = false

    var body: some View {
        let side = size * zoom
        let lineWidth = side * 0.072
        ZStack {
            if showsRing {
                Circle().stroke(BubbleColor.tomato.opacity(0.16), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, fraction)))
                    .stroke(BubbleColor.tomato, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(fraction > 0.002 ? 1 : 0)
                    .animation(.linear(duration: 0.9), value: fraction)
            }
            TomatoIcon()
                .frame(width: side * 0.56, height: side * 0.56)
                .scaleEffect(pops && !popped ? 0.55 : 1)
        }
        .frame(width: side, height: side)
        .saturation(paused ? 0 : 1)
        .opacity(paused ? 0.6 : 1)
        .onAppear {
            guard pops else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.42)) { popped = true }
        }
    }
}

private struct TomatoIcon: View {
    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            ZStack {
                Ellipse()
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.47, blue: 0.38), Color(red: 0.88, green: 0.24, blue: 0.2)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: s, height: s * 0.86)
                    .offset(y: s * 0.07)
                Ellipse().fill(Color.white.opacity(0.5))
                    .frame(width: s * 0.2, height: s * 0.12)
                    .rotationEffect(.degrees(-35))
                    .offset(x: -s * 0.22, y: -s * 0.02)
                CalyxShape().fill(Color(red: 0.24, green: 0.64, blue: 0.45))
                    .frame(width: s * 0.56, height: s * 0.3)
                    .offset(y: -s * 0.3)
                Capsule().fill(Color(red: 0.18, green: 0.52, blue: 0.38))
                    .frame(width: s * 0.08, height: s * 0.16)
                    .offset(y: -s * 0.45)
            }
            .frame(width: s, height: s)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .accessibilityHidden(true)
    }
}

private struct CalyxShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for i in 0..<10 {
            let angle = CGFloat(i) * .pi / 5 - .pi / 2
            let radius: CGFloat = i.isMultiple(of: 2) ? 1 : 0.38
            let point = CGPoint(x: center.x + cos(angle) * rect.width / 2 * radius, y: center.y + sin(angle) * rect.height / 2 * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Shape and AppKit bridges

// One outline for the body and tail so the stroke has no seam.
private struct BubbleShape: Shape {
    let edge: TodoBubbleEdge
    let offset: CGFloat
    let tail: CGFloat
    var radius: CGFloat = 18
    var halfBase: CGFloat = 11
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var body = rect.insetBy(dx: inset, dy: inset)
        switch edge {
        case .top: body.origin.y += tail; body.size.height -= tail
        case .bottom: body.size.height -= tail
        case .leading: body.origin.x += tail; body.size.width -= tail
        case .trailing: body.size.width -= tail
        }
        let r = max(0, min(radius, body.width / 2, body.height / 2))
        let center: CGFloat
        switch edge {
        case .top, .bottom:
            center = min(max(body.midX + offset, body.minX + r + halfBase), body.maxX - r - halfBase)
        case .leading, .trailing:
            center = min(max(body.midY + offset, body.minY + r + halfBase), body.maxY - r - halfBase)
        }
        var path = Path()
        path.move(to: CGPoint(x: body.minX + r, y: body.minY))
        if edge == .top { addTail(&path, body: body, center: center) }
        path.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY + r), radius: r)
        if edge == .trailing { addTail(&path, body: body, center: center) }
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX - r, y: body.maxY), radius: r)
        if edge == .bottom { addTail(&path, body: body, center: center) }
        path.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY - r), radius: r)
        if edge == .leading { addTail(&path, body: body, center: center) }
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.minX + r, y: body.minY), radius: r)
        path.closeSubpath()
        return path
    }

    // `along` follows the clockwise path direction; `out` points away from the body.
    private func addTail(_ path: inout Path, body: CGRect, center: CGFloat) {
        let direction: CGFloat = (edge == .top || edge == .trailing) ? 1 : -1
        func point(_ along: CGFloat, _ out: CGFloat) -> CGPoint {
            switch edge {
            case .top: return CGPoint(x: along, y: body.minY - out)
            case .bottom: return CGPoint(x: along, y: body.maxY + out)
            case .leading: return CGPoint(x: body.minX - out, y: along)
            case .trailing: return CGPoint(x: body.maxX + out, y: along)
            }
        }
        let depth = tail - inset
        path.addLine(to: point(center - direction * halfBase, 0))
        path.addQuadCurve(to: point(center - direction * 1.8, depth - 1.2), control: point(center - direction * halfBase * 0.3, depth * 0.25))
        path.addQuadCurve(to: point(center + direction * 1.8, depth - 1.2), control: point(center, depth + 0.6))
        path.addQuadCurve(to: point(center + direction * halfBase, 0), control: point(center + direction * halfBase * 0.3, depth * 0.25))
    }
}

// SwiftUI hover can stop while this accessory app is inactive. Tracking areas keep working.
private struct HoverTracker: NSViewRepresentable {
    let cursor: NSCursor?
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.cursor = cursor
        view.onChange = onChange
        return view
    }
    func updateNSView(_ view: TrackingView, context: Context) {
        view.cursor = cursor
        view.onChange = onChange
    }

    // AppKit can skip the entered event, for example while a field editor is active or when the area is
    // rebuilt under the pointer. Moves inside the area and rebuilds both correct the state.
    final class TrackingView: NSView {
        var cursor: NSCursor?
        var onChange: ((Bool) -> Void)?
        private var area: NSTrackingArea?
        private var inside = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            var options: NSTrackingArea.Options = [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved]
            if cursor != nil { options.insert(.cursorUpdate) }
            let next = NSTrackingArea(rect: .zero, options: options, owner: self)
            addTrackingArea(next)
            area = next
            if let window { setInside(visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))) }
        }
        override func mouseEntered(with event: NSEvent) {
            guard event.trackingArea === area else { return }
            setInside(true)
        }
        override func mouseMoved(with event: NSEvent) {
            guard event.trackingArea === area, !inside else { return }
            setInside(true)
        }
        override func mouseExited(with event: NSEvent) {
            guard event.trackingArea === area else { return }
            setInside(false)
        }
        private func setInside(_ value: Bool) {
            guard value != inside else { return }
            inside = value
            if let cursor { (value ? cursor : NSCursor.arrow).set() }
            onChange?(value)
        }
        override func cursorUpdate(with event: NSEvent) {
            if let cursor { cursor.set() } else { super.cursorUpdate(with: event) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// The popover window must become key before its field can receive typing.
private struct KeyWindowRequest: NSViewRepresentable {
    final class RequestView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.window?.makeKey() }
        }
    }
    func makeNSView(context: Context) -> RequestView { RequestView() }
    func updateNSView(_ view: RequestView, context: Context) {}
}

// Hover from the shared pointer and this view's current frame in the hosting view.
private struct PointerHover: ViewModifier {
    let onChange: (Bool) -> Void
    @Environment(\.bubblePointer) private var pointer
    @State private var frame: CGRect = .zero
    @State private var inside = false

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { frame = proxy.frame(in: .global); update(pointer?.location) }
                    .onChange(of: proxy.frame(in: .global)) { value in
                        frame = value
                        update(pointer?.location)
                    }
            })
            .onReceive(pointer?.$location.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { update($0) }
            .onDisappear { if inside { inside = false; onChange(false) } }
    }

    private func update(_ location: CGPoint?) {
        let now = location.map { frame.contains($0) } ?? false
        guard now != inside else { return }
        inside = now
        onChange(now)
    }
}

// Registers this view's frame as a text input for the shared pointer's cursor.
private struct TextCursorRegion: ViewModifier {
    @Environment(\.bubblePointer) private var pointer
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content.background(GeometryReader { proxy in
            Color.clear
                .onAppear { pointer?.setTextRegion(proxy.frame(in: .global), for: id) }
                .onChange(of: proxy.frame(in: .global)) { pointer?.setTextRegion($0, for: id) }
                .onDisappear { pointer?.setTextRegion(nil, for: id) }
        })
    }
}

private extension View {
    func textCursorRegion() -> some View { modifier(TextCursorRegion()) }

    func pointerHover(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(PointerHover(onChange: action))
    }

    func trackingHover(cursor: NSCursor? = nil, _ action: @escaping (Bool) -> Void) -> some View {
        background(HoverTracker(cursor: cursor, onChange: action))
    }
}
