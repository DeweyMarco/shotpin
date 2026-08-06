import AppKit
import CoreServices

// ShotPin: keeps the newest screenshot pinned in the bottom-right corner of the
// screen until you actually do something with it. Replaces the native macOS
// thumbnail, which disappears after a few seconds.

private enum Style {
    static let maxDimension: CGFloat = 220
    static let padding: CGFloat = 12
    static let corner: CGFloat = 8
    static let screenMargin: CGFloat = 18
    static let stackSpacing: CGFloat = 10
}

private let watchedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "pdf"]

// MARK: - Where screenshots land

func screenshotDirectory() -> URL {
    if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
       !location.isEmpty {
        return URL(fileURLWithPath: (location as NSString).expandingTildeInPath)
    }
    return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
}

/// Spotlight knows whether a file came from the screenshot machinery. Returns nil
/// while the metadata has not been written yet, so callers can retry.
func isScreenCapture(_ url: URL) -> Bool? {
    guard let item = MDItemCreate(nil, url.path as CFString) else { return nil }
    guard let raw = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) else { return nil }
    return (raw as? NSNumber)?.boolValue ?? false
}

// MARK: - The pinned card

final class ShotView: NSView, NSDraggingSource {
    let url: URL
    private let imageView = NSImageView()
    private let card = NSView()
    private let closeButton = NSButton()
    private var mouseDownPoint: NSPoint?
    private var draggingOut = false
    weak var panel: PinPanel?

    init(url: URL, image: NSImage, cardSize: NSSize) {
        self.url = url
        let total = NSSize(width: cardSize.width + Style.padding * 2,
                           height: cardSize.height + Style.padding * 2)
        super.init(frame: NSRect(origin: .zero, size: total))
        wantsLayer = true

        card.frame = NSRect(x: Style.padding, y: Style.padding,
                            width: cardSize.width, height: cardSize.height)
        card.wantsLayer = true
        if let layer = card.layer {
            layer.cornerRadius = Style.corner
            layer.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer.borderWidth = 1
            layer.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.35
            layer.shadowRadius = 7
            layer.shadowOffset = CGSize(width: 0, height: -2)
            layer.masksToBounds = false
        }
        addSubview(card)

        imageView.frame = card.bounds
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Style.corner
        imageView.layer?.masksToBounds = true
        card.addSubview(imageView)

        let glyph = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")
        closeButton.image = glyph
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.contentTintColor = NSColor.secondaryLabelColor
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.frame = NSRect(x: 2, y: total.height - 22, width: 20, height: 20)
        closeButton.target = self
        closeButton.action = #selector(dismissPin)
        closeButton.isHidden = true
        addSubview(closeButton)

        let tracking = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways],
                                      owner: self,
                                      userInfo: nil)
        addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    @objc private func dismissPin() {
        guard let panel else { return }
        PinManager.shared.remove(panel)
    }

    // MARK: click to open, drag to hand the file to another app

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        draggingOut = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !draggingOut else { return }
        let now = event.locationInWindow
        if abs(now.x - start.x) < 4 && abs(now.y - start.y) < 4 { return }
        draggingOut = true

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let dragImage = imageView.image ?? NSImage(size: card.bounds.size)
        item.setDraggingFrame(convert(card.frame, to: nil), contents: dragImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !draggingOut else { return }
        NSWorkspace.shared.open(url)
        dismissPin()
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        draggingOut = false
        if !operation.isEmpty { dismissPin() }
    }

    // MARK: context menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openFile), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Image", action: #selector(copyImage), keyEquivalent: "")
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move to Trash", action: #selector(trashFile), keyEquivalent: "")
        menu.addItem(withTitle: "Dismiss", action: #selector(dismissPin), keyEquivalent: "")
        menu.addItem(withTitle: "Dismiss All", action: #selector(dismissAll), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ShotPin", action: #selector(quitApp), keyEquivalent: "")
        for item in menu.items where item.action != nil { item.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openFile() {
        NSWorkspace.shared.open(url)
        dismissPin()
    }

    @objc private func copyImage() {
        guard let image = imageView.image else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image, url as NSURL])
        dismissPin()
    }

    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        dismissPin()
    }

    @objc private func trashFile() {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        dismissPin()
    }

    @objc private func dismissAll() { PinManager.shared.dismissAll() }

    @objc private func quitApp() { NSApp.terminate(nil) }
}

// MARK: - Floating panel

final class PinPanel: NSPanel {
    let targetScreen: NSScreen

    init(url: URL, image: NSImage, screen: NSScreen) {
        self.targetScreen = screen

        var fit = image.size
        if fit.width <= 0 || fit.height <= 0 { fit = NSSize(width: 160, height: 100) }
        let scale = min(Style.maxDimension / fit.width, Style.maxDimension / fit.height, 1.0)
        let cardSize = NSSize(width: max(60, (fit.width * scale).rounded()),
                              height: max(48, (fit.height * scale).rounded()))
        let total = NSSize(width: cardSize.width + Style.padding * 2,
                           height: cardSize.height + Style.padding * 2)

        super.init(contentRect: NSRect(origin: .zero, size: total),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = false

        let view = ShotView(url: url, image: image, cardSize: cardSize)
        view.panel = self
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Stack of pins

final class PinManager {
    static let shared = PinManager()
    private var panels: [PinPanel] = []

    func add(url: URL, image: NSImage) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let panel = PinPanel(url: url, image: image, screen: screen)
        panels.append(panel)
        panel.alphaValue = 0
        layout()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    func remove(_ panel: PinPanel) {
        guard let index = panels.firstIndex(of: panel) else { return }
        panels.remove(at: index)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            self.layout()
        })
    }

    func dismissAll() {
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }

    /// Oldest pin sits on the bottom, newer ones stack upward. If the column runs
    /// out of room the newest ones pile on top of each other rather than walking
    /// off the top of the screen.
    func layout() {
        for screen in NSScreen.screens {
            let area = screen.visibleFrame
            var y = area.minY + Style.screenMargin
            for panel in panels where panel.targetScreen === screen {
                let size = panel.frame.size
                let clampedY = min(y, area.maxY - size.height - Style.screenMargin)
                let x = area.maxX - size.width - Style.screenMargin
                panel.setFrameOrigin(NSPoint(x: x, y: clampedY))
                y = clampedY + size.height + Style.stackSpacing
            }
        }
    }
}

// MARK: - Directory watching

private func watcherCallback(stream: ConstFSEventStreamRef,
                             info: UnsafeMutableRawPointer?,
                             numEvents: Int,
                             eventPaths: UnsafeMutableRawPointer,
                             flags: UnsafePointer<FSEventStreamEventFlags>,
                             ids: UnsafePointer<FSEventStreamEventId>) {
    guard let info else { return }
    let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
    watcher.handler(paths)
}

final class DirectoryWatcher {
    let handler: ([String]) -> Void
    private var stream: FSEventStreamRef?

    init(path: String, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0,
                                          info: Unmanaged.passUnretained(self).toOpaque(),
                                          retain: nil,
                                          release: nil,
                                          copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault,
                                               watcherCallback,
                                               &context,
                                               [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               0.15,
                                               flags) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var watcher: DirectoryWatcher?
    private var handled = Set<String>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let directory = screenshotDirectory()
        watcher = DirectoryWatcher(path: directory.path) { [weak self] paths in
            for path in paths { self?.consider(path: path) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in PinManager.shared.layout() }
    }

    private func consider(path: String) {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), watchedExtensions.contains(url.pathExtension.lowercased()) else { return }
        guard !handled.contains(url.path) else { return }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let created = attributes[.creationDate] as? Date,
              Date().timeIntervalSince(created) < 15 else { return }
        handled.insert(url.path)
        pin(url: url, attempt: 0, lastSize: -1)
    }

    /// Spotlight metadata and the file bytes both land slightly after the create
    /// event, so retry briefly before giving up or pinning on the fallback path.
    private func pin(url: URL, attempt: Int, lastSize: Int) {
        let maxAttempts = 8
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        let stable = size > 0 && size == lastSize
        let capture = isScreenCapture(url)

        if capture == false { return }
        let exhausted = attempt >= maxAttempts
        // Metadata that never arrives falls back to "a fresh image file counts".
        if (stable && capture == true) || (exhausted && (capture == true || stable)) {
            show(url: url)
            return
        }
        guard !exhausted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pin(url: url, attempt: attempt + 1, lastSize: size)
        }
    }

    private func show(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url), image.size.width > 0 else { return }
        PinManager.shared.add(url: url, image: image)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
