import AppKit
import Combine

enum EditorTool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, ellipse, line, text, counter, highlight, redact, crop

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .text: "textformat"
        case .counter: "1.circle"
        case .highlight: "highlighter"
        case .redact: "eye.slash"
        case .crop: "crop"
        }
    }

    var title: String {
        switch self {
        case .select: "Auswählen"
        case .arrow: "Pfeil"
        case .rectangle: "Rechteck"
        case .ellipse: "Ellipse"
        case .line: "Linie"
        case .text: "Text"
        case .counter: "Nummerierung"
        case .highlight: "Markieren"
        case .redact: "Zensieren"
        case .crop: "Zuschneiden"
        }
    }

    var key: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        case .line: "l"
        case .text: "t"
        case .counter: "n"
        case .highlight: "h"
        case .redact: "x"
        case .crop: "c"
        }
    }

    var annotationKind: AnnotationKind? {
        switch self {
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .line: .line
        case .text: .text
        case .counter: .counter
        case .highlight: .highlight
        case .redact: .redact
        case .select, .crop: nil
        }
    }
}

@MainActor final class EditorModel: ObservableObject {
    let item: CaptureItem
    let base: CGImage
    let scale: CGFloat
    let effects: EffectsCache

    @Published var annotations: [Annotation]
    @Published var crop: CGRect?
    @Published var cropDraft: CGRect?
    @Published var tool: EditorTool {
        didSet {
            guard tool != oldValue else { return }
            if tool == .crop {
                cropDraft = crop ?? fullRect
                selectedID = nil
            } else if oldValue == .crop {
                cropDraft = nil
            }
            if tool != .crop { UserDefaults.standard.set(tool.rawValue, forKey: "editorTool") }
        }
    }
    @Published var color: RGBA
    @Published var size: StrokeSize
    @Published var redactStyle: RedactStyle
    @Published var filled = false
    @Published var selectedID: UUID?
    @Published var dirty = false
    @Published var busy: String?
    @Published var toast: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private struct Snapshot { var annotations: [Annotation]; var crop: CGRect? }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var toastWork: DispatchWorkItem?
    private var toolBeforeCrop: EditorTool = .arrow

    init(item: CaptureItem, base: CGImage, document: ImageDocument, initialTool: EditorTool? = nil) {
        self.item = item
        self.base = base
        self.scale = CGFloat(max(1, item.scale))
        self.effects = EffectsCache(base: base, scale: CGFloat(max(1, item.scale)))
        self.annotations = document.annotations
        self.crop = document.crop
        let d = UserDefaults.standard
        self.tool = initialTool ?? EditorTool(rawValue: d.string(forKey: "editorTool") ?? "") ?? .arrow
        if let data = d.data(forKey: "editorColor"), let c = try? JSONDecoder().decode(RGBA.self, from: data) {
            self.color = c
        } else {
            self.color = .red
        }
        self.size = StrokeSize(rawValue: d.integer(forKey: "editorSize")) ?? .medium
        self.redactStyle = AppSettings.shared.redactStyle
    }

    var fullRect: CGRect { CGRect(x: 0, y: 0, width: base.width, height: base.height) }
    var document: ImageDocument { ImageDocument(annotations: annotations, crop: crop) }
    var selected: Annotation? { annotations.first { $0.id == selectedID } }

    // MARK: Undo

    func checkpoint() {
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
        dirty = true
        refreshUndoState()
    }

    /// Verwirft den letzten Checkpoint, wenn die Aktion doch nichts verändert hat (z. B. Klick ohne Ziehen).
    func dropCheckpoint() {
        _ = undoStack.popLast()
        refreshUndoState()
    }

    func undo() {
        guard let snap = undoStack.popLast() else { return }
        redoStack.append(Snapshot(annotations: annotations, crop: crop))
        annotations = snap.annotations
        crop = snap.crop
        if let id = selectedID, !annotations.contains(where: { $0.id == id }) { selectedID = nil }
        dirty = true
        refreshUndoState()
    }

    func redo() {
        guard let snap = redoStack.popLast() else { return }
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        annotations = snap.annotations
        crop = snap.crop
        dirty = true
        refreshUndoState()
    }

    private func refreshUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Anmerkungen

    func makeAnnotation(kind: AnnotationKind, at p: CGPoint) -> Annotation {
        var a = Annotation(kind: kind, start: p, end: p, color: color, size: size)
        switch kind {
        case .redact: a.redactStyle = redactStyle
        case .highlight: if color == .red { a.color = .yellow }
        case .counter: a.number = nextCounterNumber()
        case .rectangle, .ellipse: a.filled = filled
        default: break
        }
        return a
    }

    func nextCounterNumber() -> Int {
        (annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1
    }

    func update(_ id: UUID, _ change: (inout Annotation) -> Void) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        change(&annotations[i])
        dirty = true
    }

    func remove(_ id: UUID) {
        annotations.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        dirty = true
    }

    func deleteSelection() {
        guard let id = selectedID else { return }
        checkpoint()
        remove(id)
    }

    // MARK: Stil (wirkt auch auf die Auswahl)

    func setColor(_ c: RGBA) {
        color = c
        if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: "editorColor") }
        guard let sel = selected, sel.kind != .redact else { return }
        checkpoint()
        update(sel.id) { $0.color = c }
    }

    func setSize(_ s: StrokeSize) {
        size = s
        UserDefaults.standard.set(s.rawValue, forKey: "editorSize")
        guard let sel = selected, sel.kind != .redact, sel.kind != .highlight else { return }
        checkpoint()
        update(sel.id) { $0.size = s }
    }

    func setRedactStyle(_ style: RedactStyle) {
        redactStyle = style
        AppSettings.shared.redactStyle = style
        guard let sel = selected, sel.kind == .redact else { return }
        checkpoint()
        update(sel.id) { $0.redactStyle = style }
    }

    func setFilled(_ value: Bool) {
        filled = value
        guard let sel = selected, sel.kind == .rectangle || sel.kind == .ellipse else { return }
        checkpoint()
        update(sel.id) { $0.filled = value }
    }

    // MARK: Zuschneiden

    func applyCrop() {
        guard let draft = cropDraft?.integral.intersection(fullRect), draft.width >= 4, draft.height >= 4 else {
            tool = toolBeforeCrop
            return
        }
        let newCrop: CGRect? = draft == fullRect ? nil : draft
        if newCrop != crop {
            checkpoint()
            crop = newCrop
        }
        tool = toolBeforeCrop
    }

    func cancelCrop() { tool = toolBeforeCrop }

    func startCrop() {
        if tool != .crop { toolBeforeCrop = tool == .crop ? .arrow : tool }
        tool = .crop
    }

    func resetCrop() { cropDraft = fullRect }

    // MARK: Auto-Zensur

    func autoRedact() {
        guard busy == nil else { return }
        busy = "Suche nach sensiblen Daten …"
        let image = base
        let style = redactStyle
        let scale = scale
        Task {
            let findings = await SensitiveDetector.detect(in: image)
            busy = nil
            let existing = annotations.filter { $0.kind == .redact }.map(\.rect)
            let fresh = findings.filter { f in !existing.contains { $0.intersection(f.rect).area > f.rect.area * 0.6 } }
            guard !fresh.isEmpty else {
                showToast(findings.isEmpty ? "Nichts Sensibles gefunden" : "Schon alles zensiert")
                return
            }
            checkpoint()
            for f in fresh {
                let r = f.rect.insetBy(dx: -3 * scale, dy: -2 * scale).intersection(fullRect)
                var a = Annotation(kind: .redact, start: r.origin, end: CGPoint(x: r.maxX, y: r.maxY))
                a.redactStyle = style
                a.auto = true
                annotations.append(a)
            }
            let kinds = Set(fresh.map(\.kind.title)).sorted().joined(separator: ", ")
            showToast("\(fresh.count) Stelle\(fresh.count == 1 ? "" : "n") zensiert · \(kinds)")
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }

    func rendered() -> CGImage? {
        Renderer.render(base: base, document: document, scale: scale, effects: effects)
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
