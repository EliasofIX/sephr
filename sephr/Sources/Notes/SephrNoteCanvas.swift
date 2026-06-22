import AppKit
import SwiftUI
import SephrKit

/// Arc-easel-style freeform canvas — Sephr calls them Notes. Hosted in
/// the content area by SephrWindowController when a `.note` tab is
/// active. Monochrome ink on the system canvas color; the tool strip is
/// a floating Liquid Glass capsule (real `.glassEffect` on macOS 26,
/// dcGlass fallback earlier).
///
/// All committed geometry — strokes, shapes, arrows, images, and
/// non-editing text — renders inside a single `Canvas` in z order, so an
/// annotation drawn over a screenshot actually paints over it. Only the
/// text element currently being edited is a live TextField view.
@MainActor
struct SephrNoteCanvas: View {

    let tab: SephrTab
    @StateObject private var store: SephrNoteStore
    @State private var title: String

    // In-progress gesture state (never persisted).
    @State private var draftPoints: [CGPoint] = []     // draw tool, absolute
    @State private var draftShape: CGRect?             // rect/ellipse, normalized
    @State private var draftArrow: (start: CGPoint, end: CGPoint)?
    @State private var gestureBegan = false
    @State private var moveBaseFrame: CGRect?          // selected frame at drag start
    /// Full element snapshot at resize-gesture start. Resize math MUST
    /// derive from this, never from the live element: scaling the live
    /// points by a base-relative factor compounds multiplicatively per
    /// drag event and blows the geometry up within one gesture.
    @State private var resizeBase: SephrNoteElement?
    @State private var didSnapshotGesture = false
    @State private var lastClick: (time: TimeInterval, point: CGPoint)?

    @FocusState private var focusedTextID: UUID?
    @State private var keyMonitor: Any?
    @State private var toolbarAppeared = false

    /// Geometry namespace for the toolbar's selected-tool pill. With
    /// matchedGeometryEffect bound to whichever ToolButton is active,
    /// switching tools makes the fill glide between them instead of
    /// snapping in place.
    @Namespace private var toolbarSelection

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let ink = Color.primary
    private static let inkWidth: CGFloat = 2.5
    private static let minElementSide: CGFloat = 24
    /// Marching-ants speed for the selection outline. Below 2 px/s the
    /// motion reads as a static dash; above 12 it draws the eye away
    /// from the content.
    private static let marchingAntsRate: CGFloat = 7

    @StateObject private var titleDebouncer = TextDebouncer()

    init(tab: SephrTab) {
        self.tab = tab
        _store = StateObject(wrappedValue: SephrNoteStore(noteID: tab.id))
        _title = State(initialValue: tab.title)
    }

    // MARK: — Body

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .windowBackgroundColor)
                inkCanvas
                editingTextField
                selectionHandle
            }
            .contentShape(Rectangle())
            .gesture(canvasGesture)
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers, location in
                handleImageDrop(providers, at: location)
            }
            .overlay(alignment: .top) { titleField }
            .overlay(alignment: .bottom) {
                toolbar(canvasCenter: CGPoint(x: geo.size.width / 2,
                                              y: geo.size.height / 2))
                    .padding(.bottom, 16)
            }
        }
        // The window is .fullSizeContentView, so AppKit reports a
        // title-bar safe area and NSHostingView insets SwiftUI content
        // below it — leaving a see-through strip at the top that the
        // plain-NSView CALWebView never shows. The canvas must paint
        // edge to edge of the content host, exactly like a page does.
        .ignoresSafeArea()
        .onAppear { installKeyMonitor() }
        .onDisappear {
            removeKeyMonitor()
            commitTextEditing()
            // Flush any pending debounced rename before the canvas tears
            // down — otherwise a typing burst followed by a tab switch
            // could drop the final character of the title.
            titleDebouncer.flush()
            store.flush()
        }
        .onChange(of: title) { _, new in
            // Debounce: every keystroke previously posted a TabEvent +
            // changeCounter persist + sidebar cell title refresh, all
            // synchronously. 250 ms is below interactive perception and
            // squashes a typing burst into one update.
            titleDebouncer.schedule {
                let resolved = new.trimmingCharacters(in: .whitespaces)
                SephrTabModel.shared.renameTab(
                    tab, title: resolved.isEmpty ? "Untitled Note" : resolved)
            }
        }
        .onChange(of: store.editingTextID) { _, new in
            focusedTextID = new
        }
        .onChange(of: focusedTextID) { old, new in
            // Focus left the in-place text editor (click-away, Tab, …) —
            // commit, and drop the element entirely if it ended up empty.
            if new == nil, old != nil, store.editingTextID != nil {
                commitTextEditing()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sephrNotePaste)) {
            note in
            guard note.object as? UUID == tab.id else { return }
            pasteFromGeneralPasteboard()
        }
    }

    // MARK: — Ink layer

    private var inkCanvas: some View {
        // TimelineView drives a continuously-walking dash phase for the
        // selection outline (marching ants). Paused when nothing is
        // selected or Reduce Motion is on, so an idle/static canvas
        // doesn't redraw at 24fps for no reason.
        let isPaused = reduceMotion || store.selectedID == nil
        return TimelineView(
            .animation(minimumInterval: 1.0 / 24.0, paused: isPaused)
        ) { timeline in
            Canvas { context, _ in
                let phase = isPaused
                    ? 0
                    : CGFloat(timeline.date.timeIntervalSinceReferenceDate
                              .truncatingRemainder(dividingBy: 7))
                        * Self.marchingAntsRate
                // Cached sort — the draft path causes continuous redraws on
                // an unchanged element list, and the previous code re-sorted
                // every frame.
                for el in store.elementsSortedByZ {
                    draw(el, in: &context, dashPhase: -phase)
                }
                drawDrafts(in: &context)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ el: SephrNoteElement,
                      in context: inout GraphicsContext,
                      dashPhase: CGFloat) {
        let selected = el.id == store.selectedID
        switch el.kind {
        case .stroke:
            guard let pts = el.points, !pts.isEmpty else { return }
            let path = Self.smoothedPath(pts, offset: el.frame.origin)
            context.stroke(path, with: .color(Self.ink),
                           style: StrokeStyle(lineWidth: Self.inkWidth,
                                              lineCap: .round,
                                              lineJoin: .round))
        case .rect:
            context.stroke(
                Path(roundedRect: el.frame, cornerRadius: 3),
                with: .color(Self.ink), lineWidth: Self.inkWidth)
        case .ellipse:
            context.stroke(Path(ellipseIn: el.frame),
                           with: .color(Self.ink), lineWidth: Self.inkWidth)
        case .arrow:
            guard let pts = el.points, pts.count == 2 else { return }
            let a = CGPoint(x: pts[0].x + el.x, y: pts[0].y + el.y)
            let b = CGPoint(x: pts[1].x + el.x, y: pts[1].y + el.y)
            context.stroke(Self.arrowPath(from: a, to: b),
                           with: .color(Self.ink),
                           style: StrokeStyle(lineWidth: Self.inkWidth,
                                              lineCap: .round,
                                              lineJoin: .round))
        case .image:
            if let name = el.imageName, let nsImage = store.images[name] {
                context.draw(Image(nsImage: nsImage), in: el.frame)
            } else {
                // Asset still decoding — quiet placeholder, no spinner.
                context.fill(Path(roundedRect: el.frame, cornerRadius: 6),
                             with: .color(Self.ink.opacity(0.06)))
            }
        case .text:
            // The actively-edited element renders as a live TextField
            // overlay instead — drawing it here too would double it.
            guard el.id != store.editingTextID else { break }
            let text = Text(el.text ?? "")
                .font(.system(size: el.fontSize ?? 18))
                .foregroundColor(Self.ink)
            context.draw(text,
                         in: el.frame.insetBy(dx: 4, dy: 2))
        }

        if selected {
            // Marching-ants: dashPhase is fed in from the TimelineView so
            // the dash pattern slides along the stroke. Subtle (1pt
            // stroke, 0.45 ink) so it never competes with the content.
            var style = StrokeStyle(lineWidth: 1, dash: [4, 3])
            style.dashPhase = dashPhase
            context.stroke(
                Path(roundedRect: el.frame.insetBy(dx: -5, dy: -5),
                     cornerRadius: 6),
                with: .color(Self.ink.opacity(0.55)),
                style: style)
        }
    }

    private func drawDrafts(in context: inout GraphicsContext) {
        if draftPoints.count > 1 {
            let path = Self.smoothedPath(draftPoints, offset: .zero)
            context.stroke(path, with: .color(Self.ink),
                           style: StrokeStyle(lineWidth: Self.inkWidth,
                                              lineCap: .round,
                                              lineJoin: .round))
        }
        if let r = draftShape {
            if store.tool == .ellipse {
                context.stroke(Path(ellipseIn: r),
                               with: .color(Self.ink), lineWidth: Self.inkWidth)
            } else {
                context.stroke(Path(roundedRect: r, cornerRadius: 3),
                               with: .color(Self.ink), lineWidth: Self.inkWidth)
            }
        }
        if let a = draftArrow {
            context.stroke(Self.arrowPath(from: a.start, to: a.end),
                           with: .color(Self.ink),
                           style: StrokeStyle(lineWidth: Self.inkWidth,
                                              lineCap: .round,
                                              lineJoin: .round))
        }
    }

    /// Freehand ink: quad curves through segment midpoints so strokes
    /// read as drawn, not as polylines.
    private static func smoothedPath(_ pts: [CGPoint],
                                     offset: CGPoint) -> Path {
        var path = Path()
        let abs = pts.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
        guard let first = abs.first else { return path }
        path.move(to: first)
        guard abs.count > 2 else {
            abs.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for i in 1..<abs.count - 1 {
            let mid = CGPoint(x: (abs[i].x + abs[i + 1].x) / 2,
                              y: (abs[i].y + abs[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: abs[i])
        }
        path.addLine(to: abs[abs.count - 1])
        return path
    }

    private static func arrowPath(from a: CGPoint, to b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        let angle = atan2(b.y - a.y, b.x - a.x)
        let head: CGFloat = 12
        let spread: CGFloat = .pi / 7
        path.move(to: CGPoint(x: b.x - head * cos(angle - spread),
                              y: b.y - head * sin(angle - spread)))
        path.addLine(to: b)
        path.addLine(to: CGPoint(x: b.x - head * cos(angle + spread),
                                 y: b.y - head * sin(angle + spread)))
        return path
    }

    // MARK: — Gesture (all tools)

    private var canvasGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !gestureBegan {
                    gestureBegan = true
                    beginGesture(at: value.startLocation)
                }
                continueGesture(value)
            }
            .onEnded { value in
                endGesture(value)
                gestureBegan = false
                didSnapshotGesture = false
                moveBaseFrame = nil
            }
    }

    private func beginGesture(at point: CGPoint) {
        switch store.tool {
        case .select:
            // Clicking anywhere outside the live text editor commits it.
            if store.editingTextID != nil { commitTextEditing() }
            if let hit = store.topElement(at: point) {
                store.selectedID = hit.id
                store.bringToFront(hit.id)
                moveBaseFrame = store.element(hit.id)?.frame
            } else {
                store.selectedID = nil
            }
        case .draw:
            draftPoints = [point]
        case .text, .rect, .ellipse, .arrow:
            break   // committed on end; shapes preview via continueGesture
        }
    }

    private func continueGesture(_ value: DragGesture.Value) {
        let start = value.startLocation
        let cur = value.location
        switch store.tool {
        case .select:
            guard let base = moveBaseFrame,
                  let id = store.selectedID,
                  var el = store.element(id) else { return }
            guard hypot(value.translation.width, value.translation.height) > 2
            else { return }
            if !didSnapshotGesture {
                didSnapshotGesture = true
                store.snapshotUndo()
            }
            el.frame.origin = CGPoint(x: base.minX + value.translation.width,
                                      y: base.minY + value.translation.height)
            store.update(el)
        case .draw:
            // Drop sub-pixel jitter; keeps stroke arrays lean.
            if let last = draftPoints.last,
               hypot(cur.x - last.x, cur.y - last.y) < 1.5 { return }
            draftPoints.append(cur)
        case .rect, .ellipse:
            draftShape = Self.normalizedRect(from: start, to: cur)
        case .arrow:
            draftArrow = (start, cur)
        case .text:
            break
        }
    }

    private func endGesture(_ value: DragGesture.Value) {
        let start = value.startLocation
        let end = value.location
        let span = hypot(end.x - start.x, end.y - start.y)

        switch store.tool {
        case .select:
            if span < 4 { handleClick(at: start) }
        case .draw:
            commitStroke()
        case .rect, .ellipse:
            defer { draftShape = nil }
            guard let r = draftShape, span >= 8 else { break }
            store.snapshotUndo()
            store.add(SephrNoteElement(
                id: UUID(),
                kind: store.tool == .rect ? .rect : .ellipse,
                x: r.minX, y: r.minY, width: r.width, height: r.height,
                points: nil, text: nil, fontSize: nil, imageName: nil, z: 0))
            store.tool = .select
        case .arrow:
            defer { draftArrow = nil }
            guard let a = draftArrow, span >= 8 else { break }
            let frame = Self.normalizedRect(from: a.start, to: a.end)
            store.snapshotUndo()
            store.add(SephrNoteElement(
                id: UUID(), kind: .arrow,
                x: frame.minX, y: frame.minY,
                width: max(frame.width, 1), height: max(frame.height, 1),
                points: [CGPoint(x: a.start.x - frame.minX,
                                 y: a.start.y - frame.minY),
                         CGPoint(x: a.end.x - frame.minX,
                                 y: a.end.y - frame.minY)],
                text: nil, fontSize: nil, imageName: nil, z: 0))
            store.tool = .select
        case .text:
            createTextElement(at: start)
        }
    }

    /// Select-tool click that didn't move: a second click on the same
    /// text element within double-click time opens it for editing.
    private func handleClick(at point: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastClick = (now, point) }
        guard let prev = lastClick,
              now - prev.time < 0.45,
              hypot(point.x - prev.point.x, point.y - prev.point.y) < 8,
              let hit = store.topElement(at: point),
              hit.kind == .text else { return }
        store.editingTextID = hit.id
    }

    private static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func commitStroke() {
        defer { draftPoints = [] }
        guard draftPoints.count > 1 else {
            // A click with the pen: leave a dot.
            if let p = draftPoints.first {
                store.snapshotUndo()
                store.add(SephrNoteElement(
                    id: UUID(), kind: .stroke,
                    x: p.x - 1, y: p.y - 1, width: 3, height: 3,
                    points: [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 1)],
                    text: nil, fontSize: nil, imageName: nil, z: 0))
            }
            return
        }
        let xs = draftPoints.map(\.x), ys = draftPoints.map(\.y)
        let frame = CGRect(x: xs.min()!, y: ys.min()!,
                           width: max(xs.max()! - xs.min()!, 1),
                           height: max(ys.max()! - ys.min()!, 1))
        let rel = draftPoints.map {
            CGPoint(x: $0.x - frame.minX, y: $0.y - frame.minY)
        }
        store.snapshotUndo()
        store.add(SephrNoteElement(
            id: UUID(), kind: .stroke,
            x: frame.minX, y: frame.minY,
            width: frame.width, height: frame.height,
            points: rel, text: nil, fontSize: nil, imageName: nil, z: 0))
    }

    // MARK: — Text elements

    private static func measureText(_ text: String,
                                    fontSize: CGFloat) -> CGSize {
        let font = NSFont.systemFont(ofSize: fontSize)
        let probe = text.isEmpty ? " " : text
        let bounds = (probe as NSString).boundingRect(
            with: NSSize(width: 600,
                         height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font])
        return CGSize(width: max(ceil(bounds.width) + 14, 48),
                      height: max(ceil(bounds.height) + 8, fontSize + 10))
    }

    private func createTextElement(at point: CGPoint) {
        let fontSize: CGFloat = 18
        let size = Self.measureText("", fontSize: fontSize)
        let el = SephrNoteElement(
            id: UUID(), kind: .text,
            x: point.x, y: point.y - size.height / 2,
            width: size.width, height: size.height,
            points: nil, text: "", fontSize: fontSize, imageName: nil, z: 0)
        store.snapshotUndo()
        store.add(el)
        store.selectedID = el.id
        store.editingTextID = el.id
        store.tool = .select
    }

    /// Live editor for the text element in edit mode. Sized to the
    /// element; remeasures (and persists) as the user types.
    @ViewBuilder
    private var editingTextField: some View {
        if let id = store.editingTextID, let el = store.element(id) {
            TextField("", text: Binding(
                get: { store.element(id)?.text ?? "" },
                set: { newText in
                    guard var live = store.element(id) else { return }
                    live.text = newText
                    let size = Self.measureText(
                        newText, fontSize: live.fontSize ?? 18)
                    live.width = size.width
                    live.height = size.height
                    store.update(live)
                }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: el.fontSize ?? 18))
                .foregroundStyle(Self.ink)
                .focused($focusedTextID, equals: id)
                .frame(width: max(el.width, 48), alignment: .topLeading)
                .position(x: el.frame.midX, y: el.frame.midY)
                .onSubmit { commitTextEditing() }
        }
    }

    private func commitTextEditing() {
        guard let id = store.editingTextID else { return }
        store.editingTextID = nil
        focusedTextID = nil
        guard let el = store.element(id) else { return }
        let trimmed = (el.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Abandoned empty editor — leave no invisible husk behind.
            store.delete(id)
        }
    }

    // MARK: — Selection resize handle

    @ViewBuilder
    private var selectionHandle: some View {
        if let id = store.selectedID, let el = store.element(id),
           store.editingTextID == nil {
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(Circle().strokeBorder(Self.ink.opacity(0.7),
                                               lineWidth: 1.5))
                .frame(width: 12, height: 12)
                .position(x: el.frame.maxX + 5, y: el.frame.maxY + 5)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if resizeBase == nil {
                                resizeBase = el
                            }
                            if !didSnapshotGesture {
                                didSnapshotGesture = true
                                store.snapshotUndo()
                            }
                            resizeSelected(by: value.translation)
                        }
                        .onEnded { _ in
                            resizeBase = nil
                            didSnapshotGesture = false
                        })
        }
    }

    private func resizeSelected(by translation: CGSize) {
        // Everything derives from the gesture-start snapshot: the live
        // element only ever holds base-geometry × one absolute factor,
        // so repeated drag events can't compound.
        guard let base = resizeBase,
              var el = store.element(base.id) else { return }
        let minSide = Self.minElementSide
        var newW = max(base.width + translation.width, minSide)
        var newH = max(base.height + translation.height, minSide)

        switch el.kind {
        case .image:
            // Keep the asset's aspect — width leads.
            let aspect = base.width / max(base.height, 1)
            newH = newW / max(aspect, 0.01)
        case .text:
            // Text scales typographically: the handle drives font size,
            // the measured bounds follow.
            let scale = newW / max(base.width, 1)
            let newFont = min(max((base.fontSize ?? 18) * scale, 9), 160)
            // Only commit meaningful changes — measure is not free.
            guard abs(newFont - (el.fontSize ?? 18)) > 0.2 else { return }
            el.fontSize = newFont
            let size = Self.measureText(el.text ?? "", fontSize: newFont)
            el.width = size.width
            el.height = size.height
            store.update(el)
            return
        case .stroke, .arrow:
            // Scale the BASE geometry by the absolute factor.
            let sx = newW / max(base.width, 1)
            let sy = newH / max(base.height, 1)
            if let pts = base.points {
                el.points = pts.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
            }
        case .rect, .ellipse:
            break
        }
        el.width = newW
        el.height = newH
        store.update(el)
    }

    // MARK: — Title

    private var titleField: some View {
        TextField("Untitled Note", text: $title)
            .textFieldStyle(.plain)
            .font(.system(size: 28, weight: .bold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.primary)
            .frame(maxWidth: 460)
            .padding(.top, 24)
    }

    // MARK: — Toolbar

    private func toolbar(canvasCenter: CGPoint) -> some View {
        let bar = HStack(spacing: 2) {
            toolButton(.select, symbol: "cursorarrow",
                       help: "Select and move")
            actionButton(symbol: "photo", help: "Insert image…") {
                insertImageFromPanel(center: canvasCenter)
            }
            toolButton(.text, symbol: "textformat", help: "Text")
            toolButton(.ellipse, symbol: "circle", help: "Ellipse")
            toolButton(.rect, symbol: "square", help: "Rectangle")
            toolButton(.arrow, symbol: "arrow.up.right", help: "Arrow")
            toolButton(.draw, symbol: "scribble.variable", help: "Draw")
            Divider().frame(height: 18).padding(.horizontal, DC.Space.xs)
            actionButton(symbol: "camera.viewfinder",
                         help: "Insert snapshot of your last web tab",
                         disabled: Self.captureCandidate() == nil) {
                captureLastWebTab(center: canvasCenter)
            }
        }
        .padding(.horizontal, DC.Space.s + 2)
        .padding(.vertical, 6)

        // Asymmetric rise: the toolbar lifts in from 12pt below on first
        // appearance so the canvas reads as "the workspace lands, then
        // the tools arrive". Subsequent recomputes (tool switch, hover)
        // keep `toolbarAppeared = true` and skip the entry animation.
        return Group {
            if #available(macOS 26.0, *) {
                bar.glassEffect(.regular, in: Capsule())
            } else {
                bar.dcGlass(cornerRadius: 22)
            }
        }
        .opacity(toolbarAppeared ? 1 : 0)
        .offset(y: toolbarAppeared ? 0 : 12)
        .onAppear {
            guard !toolbarAppeared else { return }
            if reduceMotion {
                toolbarAppeared = true
                return
            }
            withAnimation(DC.Motion.spring.delay(0.08)) {
                toolbarAppeared = true
            }
        }
    }

    private func toolButton(_ tool: SephrNoteTool, symbol: String,
                            help: String) -> some View {
        NoteToolButton(symbol: symbol,
                       help: help,
                       isSelected: store.tool == tool,
                       namespace: toolbarSelection,
                       reduceMotion: reduceMotion) {
            commitTextEditing()
            withAnimation(reduceMotion ? nil : DC.Motion.spring) {
                store.tool = tool
            }
            if tool != .select { store.selectedID = nil }
        }
    }

    private func actionButton(symbol: String, help: String,
                              disabled: Bool = false,
                              action: @escaping () -> Void) -> some View {
        NoteActionButton(symbol: symbol,
                         help: help,
                         disabled: disabled,
                         reduceMotion: reduceMotion,
                         action: action)
    }

    // MARK: — Images in

    private func insertImageFromPanel(center: CGPoint) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let image = NSImage(contentsOf: url) else { return }
            store.addImage(image, centeredAt: center)
        }
    }

    private func handleImageDrop(_ providers: [NSItemProvider],
                                 at location: CGPoint) -> Bool {
        var handled = false
        for provider in providers
        where provider.canLoadObject(ofClass: NSImage.self) {
            handled = true
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                Task { @MainActor in
                    store.addImage(image, centeredAt: location)
                }
            }
        }
        return handled
    }

    private func pasteFromGeneralPasteboard() {
        let pb = NSPasteboard.general
        if let images = pb.readObjects(forClasses: [NSImage.self])
            as? [NSImage], let image = images.first {
            store.addImage(image, centeredAt: CGPoint(x: 320, y: 240))
            return
        }
        if let string = pb.string(forType: .string), !string.isEmpty {
            let fontSize: CGFloat = 18
            let size = Self.measureText(string, fontSize: fontSize)
            store.snapshotUndo()
            store.add(SephrNoteElement(
                id: UUID(), kind: .text,
                x: 80, y: 120, width: size.width, height: size.height,
                points: nil, text: string, fontSize: fontSize,
                imageName: nil, z: 0))
        }
    }

    /// Most recently used web tab that has a content snapshot — the
    /// thumbnail captured the moment the user switched away from it.
    private static func captureCandidate() -> SephrTab? {
        SephrTabModel.shared.allTabs
            .filter { $0.kind == .web && $0.thumbnail != nil }
            .max { $0.lastAccessedAt < $1.lastAccessedAt }
    }

    private func captureLastWebTab(center: CGPoint) {
        guard let snapshot = Self.captureCandidate()?.thumbnail else { return }
        store.addImage(snapshot, centeredAt: center)
    }

    // MARK: — Keyboard (Delete / Esc / arrow nudge)

    /// Cmd-chords for notes (undo/redo/paste) are rerouted by
    /// SephrKeyboardShortcutMonitor; this local monitor covers the
    /// unmodified keys that only mean something while the canvas is up.
    /// It acts only while this note is the active tab and no text control
    /// has focus, and passes everything else through untouched.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            event in
            MainActor.assumeIsolated {
                handleKey(event)
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard tab.isActive,
              !event.modifierFlags.contains(.command) else { return event }
        // A focused field editor (the in-canvas text editor, the title,
        // the sidebar URL bar) owns its own keys.
        let textEditing =
            NSApp.keyWindow?.firstResponder is NSTextView
        switch event.keyCode {
        case 51, 117:   // delete / forward delete
            guard !textEditing, let sel = store.selectedID else { return event }
            store.delete(sel)
            return nil
        case 53:        // escape
            if textEditing, store.editingTextID != nil {
                commitTextEditing()
                return nil
            }
            if store.selectedID != nil {
                store.selectedID = nil
                return nil
            }
            if store.tool != .select {
                store.tool = .select
                return nil
            }
            return event
        case 123...126: // arrows — nudge the selection 1pt (10 with Shift)
            guard !textEditing, let sel = store.selectedID,
                  var el = store.element(sel) else { return event }
            let step: CGFloat =
                event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 123: el.x -= step
            case 124: el.x += step
            case 125: el.y += step
            case 126: el.y -= step
            default: break
            }
            store.update(el)
            return nil
        default:
            return event
        }
    }
}

// MARK: — Toolbar buttons

/// One tool button inside the floating Liquid Glass toolbar capsule.
/// Local @State hovering so the hover-fill is scoped per button (the
/// surrounding HStack would otherwise share state across siblings if the
/// hover were declared on the parent view). The selected button's circle
/// uses matchedGeometryEffect so switching tools makes the active fill
/// glide between buttons instead of snapping in place.
private struct NoteToolButton: View {
    let symbol: String
    let help: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let reduceMotion: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background {
                    if isSelected {
                        Circle()
                            .fill(Color.primary.opacity(0.18))
                            .matchedGeometryEffect(
                                id: "tool-selection", in: namespace)
                    } else if hovering {
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                    }
                }
                .scaleEffect(hovering && !isSelected ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : DC.Motion.hover, value: hovering)
    }
}

/// Toolbar action buttons (insert image, snapshot). No selection state —
/// they fire-and-return — but they get the same hover treatment so the
/// toolbar reads coherently and the user doesn't wonder why some buttons
/// respond and others don't.
private struct NoteActionButton: View {
    let symbol: String
    let help: String
    let disabled: Bool
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(disabled ? .tertiary : .primary)
                .frame(width: 34, height: 34)
                .background {
                    if hovering && !disabled {
                        Circle().fill(Color.primary.opacity(0.08))
                    }
                }
                .scaleEffect(hovering && !disabled ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : DC.Motion.hover, value: hovering)
    }
}
