import AppKit
import CoreServices
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
private let shotFileManager = Foundation.FileManager()

// MARK: - Where screenshots land

func screenshotDirectory() -> URL {
    if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
       !location.isEmpty {
        return URL(fileURLWithPath: (location as NSString).expandingTildeInPath)
    }
    return shotFileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
}

/// Spotlight knows whether a file came from the screenshot machinery. Returns nil
/// while the metadata has not been written yet, so callers can retry.
func isScreenCapture(_ url: URL) -> Bool? {
    guard let item = MDItemCreate(nil, url.path as CFString) else { return nil }
    guard let raw = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) else { return nil }
    return (raw as? NSNumber)?.boolValue ?? false
}

/// Spotlight is authoritative when it has an answer. This fallback is deliberately
/// narrow: it only recognizes macOS' generated screenshot names, never arbitrary
/// fresh images dropped into the watched directory.
func hasGeneratedScreenshotName(_ url: URL, defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.screencapture")) -> Bool {
    let configuredName = defaults?.string(forKey: "name")?.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefixes = [configuredName, "Screen Shot", "Screenshot"].compactMap { value -> String? in
        guard let value, !value.isEmpty else { return nil }
        return value
    }
    let stem = url.deletingPathExtension().lastPathComponent
    return prefixes.contains { prefix in
        guard stem.hasPrefix(prefix + " ") else { return false }
        return stem.dropFirst(prefix.count + 1).contains(where: \Character.isNumber)
    }
}

// MARK: - The pinned card

final class ShotView: NSView, NSDraggingSource {
    private static let copyQueue = DispatchQueue(label: "app.shotpin.copy-loader", qos: .userInitiated)

    let url: URL
    private let imageView = NSImageView()
    private let card = NSView()
    private let closeButton = NSButton()
    private let errorLabel = NSTextField(labelWithString: "")
    private var hideErrorWorkItem: DispatchWorkItem?
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

        errorLabel.alignment = .center
        errorLabel.font = .systemFont(ofSize: 11, weight: .medium)
        errorLabel.textColor = .white
        errorLabel.maximumNumberOfLines = 2
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.frame = NSRect(x: 6, y: 6, width: card.bounds.width - 12, height: 34)
        errorLabel.wantsLayer = true
        errorLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        errorLabel.layer?.cornerRadius = 5
        errorLabel.isHidden = true
        card.addSubview(errorLabel)

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
        openFile()
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
        guard shotFileManager.fileExists(atPath: url.path) else {
            showError("The file no longer exists")
            return
        }
        if NSWorkspace.shared.open(url) {
            dismissPin()
        } else {
            showError("Couldn't open the screenshot")
        }
    }

    @objc private func copyImage() {
        guard shotFileManager.fileExists(atPath: url.path),
              let contentType = UTType(filenameExtension: url.pathExtension),
              contentType.conforms(to: .image) || contentType.conforms(to: .pdf) else {
            showError("Couldn't read the screenshot")
            return
        }

        let url = url
        Self.copyQueue.async { [weak self] in
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data else {
                    self.showError("Couldn't read the screenshot")
                    return
                }

                let item = NSPasteboardItem()
                let type = NSPasteboard.PasteboardType(contentType.identifier)
                guard item.setData(data, forType: type) else {
                    self.showError("Couldn't copy the screenshot")
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                if pasteboard.writeObjects([item]) {
                    self.dismissPin()
                } else {
                    self.showError("Couldn't copy the screenshot")
                }
            }
        }
    }

    @objc private func revealInFinder() {
        guard shotFileManager.fileExists(atPath: url.path) else {
            showError("The file no longer exists")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        dismissPin()
    }

    @objc private func trashFile() {
        do {
            try shotFileManager.trashItem(at: url, resultingItemURL: nil)
            dismissPin()
        } catch {
            showError("Couldn't move the file to Trash")
        }
    }

    private func showError(_ message: String) {
        hideErrorWorkItem?.cancel()
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        errorLabel.superview?.addSubview(errorLabel, positioned: .above, relativeTo: nil)

        let workItem = DispatchWorkItem { [weak self] in
            self?.errorLabel.isHidden = true
        }
        hideErrorWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    @objc private func dismissAll() { PinManager.shared.dismissAll() }

    @objc private func quitApp() { NSApp.terminate(nil) }
}

// MARK: - Floating panel

final class PinPanel: NSPanel {
    var targetDisplayID: CGDirectDisplayID

    init(url: URL, image: NSImage, screen: NSScreen) {
        self.targetDisplayID = screen.displayID

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
        let availableScreens = NSScreen.screens
        guard !availableScreens.isEmpty else { return }
        let fallbackScreen = NSScreen.main ?? availableScreens[0]

        for panel in panels where !availableScreens.contains(where: { $0.displayID == panel.targetDisplayID }) {
            panel.targetDisplayID = fallbackScreen.displayID
        }

        for screen in availableScreens {
            let area = screen.visibleFrame
            var y = area.minY + Style.screenMargin
            for panel in panels where panel.targetDisplayID == screen.displayID {
                let size = panel.frame.size
                let clampedY = min(y, area.maxY - size.height - Style.screenMargin)
                let x = area.maxX - size.width - Style.screenMargin
                panel.setFrameOrigin(NSPoint(x: x, y: clampedY))
                y = clampedY + size.height + Style.stackSpacing
            }
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - Thumbnail decoding

private enum ThumbnailLoader {
    private static let queue = DispatchQueue(label: "app.shotpin.thumbnail-loader", qos: .userInitiated)
    private static let maxPixelDimension = Int(Style.maxDimension * 2)

    static func load(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        queue.async {
            let image: NSImage? = autoreleasepool {
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension
                    ]
                    if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                        return displayImage(from: cgImage)
                    }
                }
                return pdfThumbnail(url)
            }
            DispatchQueue.main.async { completion(image) }
        }
    }

    private static func pdfThumbnail(_ url: URL) -> NSImage? {
        guard url.pathExtension.lowercased() == "pdf",
              let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1) else { return nil }
        let bounds = page.getBoxRect(.mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(CGFloat(maxPixelDimension) / bounds.width,
                        CGFloat(maxPixelDimension) / bounds.height,
                        1)
        let width = max(1, Int((bounds.width * scale).rounded(.up)))
        let height = max(1, Int((bounds.height * scale).rounded(.up)))
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.concatenate(page.getDrawingTransform(.mediaBox,
                                                     rect: target,
                                                     rotate: 0,
                                                     preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let cgImage = context.makeImage() else { return nil }
        return displayImage(from: cgImage)
    }

    private static func displayImage(from cgImage: CGImage) -> NSImage {
        let pixelSize = NSSize(width: cgImage.width, height: cgImage.height)
        let scale = min(Style.maxDimension / pixelSize.width,
                        Style.maxDimension / pixelSize.height,
                        1)
        let displaySize = NSSize(width: pixelSize.width * scale,
                                 height: pixelSize.height * scale)
        return NSImage(cgImage: cgImage, size: displaySize)
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
    let events = (0..<min(numEvents, paths.count)).map {
        DirectoryWatcher.Event(path: paths[$0], flags: flags[$0])
    }
    watcher.receive(events)
}

final class DirectoryWatcher {
    struct Event {
        let path: String
        let flags: FSEventStreamEventFlags

        var isFile: Bool { flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 }
        var isCreatedOrMoved: Bool {
            flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
        }
        var requiresRescan: Bool {
            flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged) != 0
        }
    }

    enum WatchError: LocalizedError {
        case creationFailed(String)
        case startFailed(String)

        var errorDescription: String? {
            switch self {
            case .creationFailed(let path): return "Could not create an FSEvents stream for \(path)"
            case .startFailed(let path): return "Could not start the FSEvents stream for \(path)"
            }
        }
    }

    let handler: ([Event]) -> Void
    private var stream: FSEventStreamRef?

    init(path: String, handler: @escaping ([Event]) -> Void) throws {
        self.handler = handler
        var context = FSEventStreamContext(version: 0,
                                          info: Unmanaged.passUnretained(self).toOpaque(),
                                          retain: nil,
                                          release: nil,
                                          copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault,
                                               watcherCallback,
                                               &context,
                                               [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               0.15,
                                               flags) else { throw WatchError.creationFailed(path) }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            throw WatchError.startFailed(path)
        }
    }

    fileprivate func receive(_ events: [Event]) { handler(events) }

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
    private var watchedDirectory: URL?
    private var watcherRefreshTimer: Timer?
    private var pending: [FileIdentity: UUID] = [:]
    private var recentlyHandled: [FileIdentity: Date] = [:]

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64

        init?(attributes: [FileAttributeKey: Any]) {
            guard let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
            self.device = device.uint64Value
            self.inode = inode.uint64Value
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureWatcher(force: true)
        watcherRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.configureWatcher(force: false)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { _ in
            DispatchQueue.main.async { PinManager.shared.layout() }
        }
    }

    private func configureWatcher(force: Bool) {
        let directory = screenshotDirectory().standardizedFileURL
        guard force || directory != watchedDirectory || watcher == nil else { return }
        watcher = nil
        watchedDirectory = directory
        do {
            watcher = try DirectoryWatcher(path: directory.path) { [weak self] events in
                self?.receive(events)
            }
            NSLog("ShotPin: watching %@", directory.path)
        } catch {
            NSLog("ShotPin: watcher unavailable for %@: %@; retrying", directory.path, error.localizedDescription)
        }
    }

    private func receive(_ events: [DirectoryWatcher.Event]) {
        if events.contains(where: \DirectoryWatcher.Event.requiresRescan) {
            NSLog("ShotPin: FSEvents reported dropped or invalidated events; rescanning")
            rescanWatchedDirectory()
            configureWatcher(force: true)
        }
        for event in events where event.isFile && event.isCreatedOrMoved {
            consider(path: event.path)
        }
    }

    private func rescanWatchedDirectory() {
        guard let directory = watchedDirectory,
              let contents = try? shotFileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
              ) else { return }
        for url in contents { consider(path: url.path) }
    }

    private func consider(path: String) {
        guard let directory = watchedDirectory else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // FSEvents watches directory trees. Screenshots only land directly in the
        // configured destination, so accepting descendants catches unrelated files.
        guard url.deletingLastPathComponent() == directory else { return }
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), watchedExtensions.contains(url.pathExtension.lowercased()) else { return }
        guard let attributes = try? shotFileManager.attributesOfItem(atPath: path),
              let identity = FileIdentity(attributes: attributes),
              let created = attributes[.creationDate] as? Date,
              Date().timeIntervalSince(created) < 15 else { return }
        let now = Date()
        recentlyHandled = recentlyHandled.filter { now.timeIntervalSince($0.value) < 60 }
        guard pending[identity] == nil, recentlyHandled[identity] == nil else { return }
        let token = UUID()
        pending[identity] = token
        pin(url: url, identity: identity, token: token, attempt: 0, lastSize: -1)
    }

    /// Spotlight metadata and the file bytes both land slightly after the create
    /// event, so retry briefly before giving up or pinning on the fallback path.
    private func pin(url: URL, identity: FileIdentity, token: UUID, attempt: Int, lastSize: Int) {
        guard pending[identity] == token else { return }
        let maxAttempts = 20
        let attributes = try? shotFileManager.attributesOfItem(atPath: url.path)
        guard let attributes, FileIdentity(attributes: attributes) == identity else {
            pending.removeValue(forKey: identity)
            return
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let stable = size > 0 && size == lastSize
        let capture = isScreenCapture(url)

        if capture == false {
            pending.removeValue(forKey: identity)
            recentlyHandled[identity] = Date()
            return
        }
        let exhausted = attempt >= maxAttempts
        // When Spotlight is unavailable, only macOS' generated filename is accepted.
        // Arbitrarily named screencapture CLI output normally carries Spotlight's
        // capture attribute and follows the authoritative branch above.
        let generatedNameFallback = capture == nil && hasGeneratedScreenshotName(url)
        if (stable && capture == true) || (exhausted && stable && generatedNameFallback) {
            pending.removeValue(forKey: identity)
            recentlyHandled[identity] = Date()
            show(url: url)
            return
        }
        guard !exhausted else {
            pending.removeValue(forKey: identity)
            recentlyHandled[identity] = Date()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pin(url: url, identity: identity, token: token, attempt: attempt + 1, lastSize: size)
        }
    }

    private func show(url: URL) {
        guard shotFileManager.fileExists(atPath: url.path) else { return }
        ThumbnailLoader.load(url) { image in
            guard shotFileManager.fileExists(atPath: url.path),
                  let image, image.size.width > 0, image.size.height > 0 else { return }
            PinManager.shared.add(url: url, image: image)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
