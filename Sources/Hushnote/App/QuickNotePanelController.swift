import AppKit
import Carbon
import Observation
import SwiftUI

@MainActor
protocol QuickNoteApplicationFocusing {
    func frontmostApplication() -> NSRunningApplication?
    func activateHushnote()
    func restore(_ application: NSRunningApplication)
}

@MainActor
struct WorkspaceQuickNoteApplicationFocuser: QuickNoteApplicationFocusing {
    func frontmostApplication() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    func activateHushnote() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func restore(_ application: NSRunningApplication) {
        application.activate()
    }
}

@MainActor
@Observable
final class QuickNotePanelController: NSObject, NSWindowDelegate {
    @ObservationIgnored private let state: AppViewState
    @ObservationIgnored private let coordinator: AppCoordinator
    @ObservationIgnored private let focuser: any QuickNoteApplicationFocusing
    @ObservationIgnored private let panel: NSPanel
    @ObservationIgnored private var previousApplication: NSRunningApplication?

    init(
        state: AppViewState,
        coordinator: AppCoordinator,
        focuser: any QuickNoteApplicationFocusing = WorkspaceQuickNoteApplicationFocuser()
    ) {
        self.state = state
        self.coordinator = coordinator
        self.focuser = focuser
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 420, height: 112),
            styleMask: [.titled, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: QuickNotePanelView(
            save: { [weak self] draft in self?.save(draft) },
            cancel: { [weak self] in self?.dismissAndRestoreFocus() }
        ))
        panel.center()
    }

    func show() {
        guard state.recordingPhase.isCapturing, state.activeMeetingID != nil else { return }
        let candidate = focuser.frontmostApplication()
        previousApplication = candidate?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? nil
            : candidate
        focuser.activateHushnote()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        restoreFocus()
    }

    private func save(_ draft: String) {
        Task { [weak self] in
            guard let self, await self.coordinator.saveQuickNote(draft) else { return }
            self.dismissAndRestoreFocus()
        }
    }

    private func dismissAndRestoreFocus() {
        panel.orderOut(nil)
        restoreFocus()
    }

    private func restoreFocus() {
        guard let previousApplication else { return }
        self.previousApplication = nil
        let hushnotePID = ProcessInfo.processInfo.processIdentifier
        let currentPID = focuser.frontmostApplication()?.processIdentifier ?? hushnotePID
        guard QuickNoteFocusPolicy.shouldRestore(
            previousProcessID: previousApplication.processIdentifier,
            currentProcessID: currentPID,
            hushnoteProcessID: hushnotePID
        ) else { return }
        focuser.restore(previousApplication)
    }
}

private struct QuickNotePanelView: View {
    let save: @MainActor (String) -> Void
    let cancel: @MainActor () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HushnoteEyebrow("Quick note")
            TextField("What should you remember?", text: $draft)
                .textFieldStyle(HushnoteFieldStyle())
                .focused($focused)
                .hushnoteFocusRing(focused)
                .onSubmit(submit)
        }
        .padding(16)
        .background(HushnoteTheme.paper)
        .task { focused = true }
        .onExitCommand(perform: cancel)
    }

    private func submit() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let value = draft
        draft = ""
        save(value)
    }
}

@MainActor
final class GlobalQuickNoteShortcut: @unchecked Sendable {
    private let action: @MainActor () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let owner = Unmanaged<GlobalQuickNoteShortcut>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor in owner.action() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        let identifier = EventHotKeyID(signature: 0x48534E51, id: 1) // HSNQ
        RegisterEventHotKey(
            UInt32(kVK_ANSI_N),
            UInt32(controlKey | optionKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
