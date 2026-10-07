import AppKit
import Combine

/// Symbol in der Menüleiste. Klick öffnet das Knips-Panel (`MenuPanelController`);
/// während einer Aufnahme stoppt ein Linksklick sofort.
@MainActor final class StatusBarController: NSObject {
    static var shared: StatusBarController?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        super.init()
        item.button?.image = Self.icon
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        RecordingController.shared.$elapsed
            .combineLatest(RecordingController.shared.$phase)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshRecordingState() }
            .store(in: &cancellables)
    }

    static let icon: NSImage = {
        let img = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Knips") ?? NSImage()
        let configured = img.withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) ?? img
        configured.isTemplate = true
        return configured
    }()

    @objc private func statusClicked() {
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp
        if RecordingController.shared.isRecording, !rightClick {
            RecordingController.shared.stop(save: true)
            return
        }
        guard let button = item.button else { return }
        MenuPanelController.shared.toggle(below: button)
    }

    func togglePanel() {
        guard let button = item.button else { return }
        MenuPanelController.shared.toggle(below: button)
    }

    func refreshRecordingState() {
        let rc = RecordingController.shared
        switch rc.phase {
        case .recording:
            item.button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Aufnahme stoppen")?
                .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            item.button?.attributedTitle = NSAttributedString(string: " " + Format.duration(rc.elapsed), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            ])
        case .countdown(let n):
            item.button?.image = Self.icon
            item.button?.title = " \(n)"
        default:
            item.button?.image = Self.icon
            item.button?.title = ""
        }
    }
}
