import AppKit
import SwiftUI

@main
struct SpectrumApp: App {
    @State private var viewModel = SpectrumViewModel()

    init() {
        _ = NSHelpManager.shared.registerBooks(in: .main)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear {
                    AlwaysOnTopSupport.install(viewModel: viewModel)
                }
        }
        .defaultSize(width: 1120, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Spectrum") {
                    AboutPanel.present()
                }
            }
            CommandGroup(after: .windowArrangement) {
                Toggle("Always on Top", isOn: $viewModel.alwaysOnTop)
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Spectrum Help") {
                    HelpBook.open()
                }
                .keyboardShortcut("?", modifiers: .command)
                Divider()
                Button("Privacy & Permissions") {
                    HelpBook.open(anchor: "permissions")
                }
                Button("Choosing an Audio Source") {
                    HelpBook.open(anchor: "audio-sources")
                }
                Button("The Analyzer Display") {
                    HelpBook.open(anchor: "analyzer")
                }
                Button("Troubleshooting") {
                    HelpBook.open(anchor: "troubleshooting")
                }
            }
        }

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}

@MainActor
enum AlwaysOnTopSupport {
    private static var viewModel: SpectrumViewModel?
    private static var observer: NSObjectProtocol?
    private static weak var mainWindow: NSWindow?

    static func install(viewModel: SpectrumViewModel) {
        self.viewModel = viewModel
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor in
                disableIfAuxiliaryWindow(window)
            }
        }
    }

    static func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
    }

    static func disableIfNeeded() {
        guard let viewModel, viewModel.alwaysOnTop else { return }
        viewModel.alwaysOnTop = false
        lowerFloatingWindows()
    }

    private static func disableIfAuxiliaryWindow(_ window: NSWindow) {
        guard isAuxiliaryDialog(window) else { return }
        disableIfNeeded()
        window.makeKeyAndOrderFront(nil)
    }

    private static func isAuxiliaryDialog(_ window: NSWindow) -> Bool {
        guard window.isVisible, window.styleMask.contains(.titled) else { return false }
        if let mainWindow {
            return window !== mainWindow
        }
        switch window.title {
        case "About Spectrum", "Spectrum Help", "Settings":
            return true
        default:
            return window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true
        }
    }

    private static func lowerFloatingWindows() {
        for window in NSApp.windows where window.level == .floating {
            window.level = .normal
        }
    }
}

@MainActor
enum AboutPanel {
    static let copyright = "© Thomas Byrdal, 2026. www.byrdal.dk/spectrum"

    private static var window: AboutWindow?
    private static var coordinator: AboutWindowCoordinator?

    static func present() {
        AlwaysOnTopSupport.disableIfNeeded()
        let about = existingWindow()
        if about.isVisible {
            return
        }

        if let view = about.contentView {
            view.layoutSubtreeIfNeeded()
            let fitting = view.fittingSize
            if fitting.width > 0, fitting.height > 0 {
                about.setContentSize(fitting)
            }
        }
        about.hostWindow = spectrumWindow(excluding: about)
        NSApp.activate()
        NSApp.runModal(for: about)
    }

    private static func existingWindow() -> AboutWindow {
        if let window {
            return window
        }

        let hosting = NSHostingController(rootView: AboutView())
        hosting.sizingOptions = [.preferredContentSize, .intrinsicContentSize]

        let window = AboutWindow(
            contentRect: NSRect(x: 0, y: 0, width: 656, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Spectrum"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = hosting
        window.styleMask.remove(.resizable)

        let coordinator = AboutWindowCoordinator()
        window.delegate = coordinator
        self.coordinator = coordinator
        self.window = window
        return window
    }

    private static func spectrumWindow(excluding about: NSWindow) -> NSWindow? {
        let excludedTitles: Set<String> = ["About Spectrum", "Spectrum Help", "Settings"]
        func isCandidate(_ window: NSWindow) -> Bool {
            window !== about && window.isVisible && !excludedTitles.contains(window.title)
        }

        if let main = NSApp.mainWindow, isCandidate(main) {
            return main
        }
        if let key = NSApp.keyWindow, isCandidate(key) {
            return key
        }

        let candidates = NSApp.windows.filter { window in
            isCandidate(window) && window.canBecomeMain
        }
        return candidates.max { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }
    }
}

/// `runModal(for:)` always calls `center()`, which AppKit defines as the screen.
/// Override that so About sits on the Spectrum window instead.
@MainActor
private final class AboutWindow: NSWindow {
    weak var hostWindow: NSWindow?

    override func center() {
        guard let parent = hostWindow else {
            super.center()
            return
        }

        let size = frame.size
        var origin = NSPoint(
            x: parent.frame.midX - size.width / 2,
            y: parent.frame.midY - size.height / 2
        )
        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        setFrameOrigin(origin)
    }
}

@MainActor
private final class AboutWindowCoordinator: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow != nil {
            NSApp.stopModal()
        }
    }
}
