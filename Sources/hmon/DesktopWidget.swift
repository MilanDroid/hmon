import AppKit
import SwiftUI

/// Borderless floating panel that hosts `PopoverView` directly so the desktop
/// "widget" stays in sync with the in-app UI. Drag-to-move, visible on all
/// Spaces, level pinned above normal windows so it doesn't get buried.
///
/// We use a real NSPanel (not WidgetKit) because WidgetKit timelines update
/// at ~15 min granularity and run out-of-process — neither matches a 2 s
/// IOKit sensor poll.
final class DesktopWidget: NSObject, NSWindowDelegate {
    private let stats: StatsModel
    private var panel: NSPanel?
    private static let frameKey = "widgetFrame"

    init(stats: StatsModel) { self.stats = stats }

    var isVisible: Bool { panel?.isVisible ?? false }

    func setVisible(_ on: Bool) {
        if on { show() } else { hide() }
    }

    private func show() {
        if let p = panel {
            p.orderFrontRegardless()
            stats.setWidgetActive(true)
            return
        }
        let rootView = WidgetContainer(stats: stats)
        let host = NSHostingView(rootView: rootView)
        host.translatesAutoresizingMaskIntoConstraints = false

        let initialFrame = restoredFrame()
            ?? NSRect(x: 80, y: 80, width: 300, height: 420)
        let p = NSPanel(contentRect: initialFrame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.delegate = self
        p.isReleasedWhenClosed = false
        p.orderFrontRegardless()

        self.panel = p
        stats.setWidgetActive(true)
    }

    private func hide() {
        panel?.orderOut(nil)
        stats.setWidgetActive(false)
    }

    private func restoredFrame() -> NSRect? {
        guard let s = UserDefaults.standard.string(forKey: Self.frameKey) else {
            return nil
        }
        let r = NSRectFromString(s)
        return r == .zero ? nil : r
    }

    func windowDidMove(_ notification: Notification) {
        guard let p = panel else { return }
        UserDefaults.standard.set(NSStringFromRect(p.frame), forKey: Self.frameKey)
    }
}

/// Wraps `PopoverView` so it can stand alone on the desktop: rounded glass
/// background, no Quit button (closing the widget shouldn't kill the app).
private struct WidgetContainer: View {
    @ObservedObject var stats: StatsModel

    var body: some View {
        PopoverView(stats: stats, onQuit: {
            (NSApp.delegate as? AppDelegate)?.toggleDesktopWidget()
        })
        .background(WidgetBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}

private struct WidgetBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.state = .active
        v.blendingMode = .behindWindow
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
