import AppKit
import CoreServices
import Darwin
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
private let recordingExtensions: Set<String> = ["mov", "mp4"]
private let shotFileManager = Foundation.FileManager()

// MARK: - Private capture workspace

/// Redirects macOS' normal screenshot machinery into a private, per-run folder.
/// The original destination is restored when ShotPin exits, and stale state from
/// an interrupted prior run is repaired the next time ShotPin launches.
final class CaptureWorkspace {
    static let shared = CaptureWorkspace()

    enum WorkspaceError: LocalizedError {
        case alreadyRunning
        case lockFailed(String, Int32)
        case unsafeRoot(String)
        case preferencesUpdateFailed

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "another ShotPin instance is already running"
            case .lockFailed(let path, let code):
                return "could not lock \(path) (errno \(code))"
            case .unsafeRoot(let path):
                return "refusing to use unsafe workspace root \(path)"
            case .preferencesUpdateFailed:
                return "could not update the macOS screenshot location"
            }
        }
    }

    private enum Key {
        static let active = "captureWorkspace.active"
        static let path = "captureWorkspace.path"
        static let token = "captureWorkspace.token"
        static let endedAt = "captureWorkspace.endedAt"
        static let previousLocation = "captureWorkspace.previousLocation"
        static let previousLocationExisted = "captureWorkspace.previousLocationExisted"
        static let staleWorkspaces = "captureWorkspace.staleWorkspaces"
    }

    private struct StaleWorkspace {
        let path: String
        let token: String?
        let previousLocation: String?
        let previousLocationExisted: Bool
        let endedAt: Date

        init(path: String,
             token: String?,
             previousLocation: String?,
             previousLocationExisted: Bool,
             endedAt: Date) {
            self.path = path
            self.token = token
            self.previousLocation = previousLocation
            self.previousLocationExisted = previousLocationExisted
            self.endedAt = endedAt
        }

        init?(propertyList: [String: Any]) {
            guard let path = propertyList["path"] as? String,
                  let existed = propertyList["previousLocationExisted"] as? Bool,
                  let endedAt = propertyList["endedAt"] as? Date else { return nil }
            self.init(path: path,
                      token: propertyList["token"] as? String,
                      previousLocation: propertyList["previousLocation"] as? String,
                      previousLocationExisted: existed,
                      endedAt: endedAt)
        }

        var propertyList: [String: Any] {
            var value: [String: Any] = [
                "path": path,
                "previousLocationExisted": previousLocationExisted,
                "endedAt": endedAt
            ]
            if let token { value["token"] = token }
            if let previousLocation { value["previousLocation"] = previousLocation }
            return value
        }
    }

    private let appDefaults = UserDefaults.standard
    private let captureDomain = "com.apple.screencapture" as CFString
    private let stateRoot = (shotFileManager.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
        ?? shotFileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true))
        .appendingPathComponent("ShotPin", isDirectory: true)
    private var workspaceRoot: URL {
        stateRoot.appendingPathComponent("Capture Workspaces", isDirectory: true)
    }
    private var ownershipRoot: URL {
        stateRoot.appendingPathComponent("Workspace Ownership", isDirectory: true)
    }
    private var lockDescriptor: Int32 = -1
    private var ownsSession = false
    private var sessionToken: String?
    private var staleCleanupRunning = false
    private let cleanupQueue = DispatchQueue(label: "app.shotpin.workspace-cleanup", qos: .utility)
    private let terminationCleanupQueue = DispatchQueue(
        label: "app.shotpin.termination-cleanup",
        qos: .userInitiated
    )
    private(set) var directory: URL?

    private init() {}

    func begin() throws {
        try shotFileManager.createDirectory(at: stateRoot,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        try validateDirectory(stateRoot)
        try acquireProcessLock()

        do {
            try shotFileManager.createDirectory(at: workspaceRoot,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
            try validateDirectory(workspaceRoot)
            try shotFileManager.createDirectory(at: ownershipRoot,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
            try validateDirectory(ownershipRoot)
            try recoverInterruptedSession()

            let previousLocation = currentCaptureLocation()
            let workspace = workspaceRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let token = UUID().uuidString
            try shotFileManager.createDirectory(at: workspace,
                                                withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
            try token.write(to: ownershipMarker(for: workspace),
                            atomically: true,
                            encoding: .utf8)

            // Persist recovery information before changing the global capture setting.
            appDefaults.set(true, forKey: Key.active)
            appDefaults.set(workspace.path, forKey: Key.path)
            appDefaults.set(token, forKey: Key.token)
            appDefaults.set(previousLocation != nil, forKey: Key.previousLocationExisted)
            if let previousLocation {
                appDefaults.set(previousLocation, forKey: Key.previousLocation)
            } else {
                appDefaults.removeObject(forKey: Key.previousLocation)
            }
            guard appDefaults.synchronize() else {
                throw WorkspaceError.preferencesUpdateFailed
            }

            directory = workspace
            sessionToken = token
            ownsSession = true
        } catch {
            releaseProcessLock()
            throw error
        }
    }

    /// Activate the redirect only after the watcher is live. Captures made during
    /// startup then remain in the user's normal destination instead of entering an
    /// unwatched workspace.
    func activate() throws {
        guard ownsSession, let directory else { return }
        guard setCaptureLocation(directory.path) else {
            throw WorkspaceError.preferencesUpdateFailed
        }
    }

    /// Honor a destination change made while ShotPin is running, then resume the
    /// private redirect so subsequent captures continue to be watched. The new
    /// destination becomes the one restored at shutdown.
    func maintainRedirect() -> Bool {
        guard ownsSession, let directory else { return false }
        guard CFPreferencesAppSynchronize(captureDomain) else { return false }
        let current = currentCaptureLocation()
        guard !locationsMatch(current, directory.path) else { return true }
        savePreviousLocation(current)
        guard appDefaults.synchronize() else { return false }
        return setCaptureLocation(directory.path)
    }

    func end(completion: @escaping () -> Void) {
        guard ownsSession, let workspace = directory, let token = sessionToken else {
            DispatchQueue.main.async(execute: completion)
            return
        }
        appDefaults.set(Date(), forKey: Key.endedAt)
        let restored = restorePreviousLocation(expectedWorkspace: workspace)
        if !restored {
            NSLog("ShotPin: could not restore the screenshot destination; recovery remains active")
        }
        let destination = previousCaptureDirectory()

        // Delete closed screenshots without waiting behind a stale recording copy.
        // Recordings and recently changing files remain under the durable active
        // record for the next launch to retire after its normal grace period.
        terminationCleanupQueue.async { [self] in
            let complete = discardWorkspace(at: workspace,
                                            token: token,
                                            destination: destination,
                                            allowCrossVolumeRecordingMoves: false,
                                            removeWorkspace: false,
                                            processRecordings: false)
            DispatchQueue.main.async { [self] in
                finishSession(workspace: workspace, cleanupComplete: complete)
                completion()
            }
        }
    }

    private func finishSession(workspace: URL, cleanupComplete: Bool) {
        if cleanupComplete {
            clearRecoveryState()
        } else {
            // Keep a trustworthy recovery pointer so the next launch can retry.
            appDefaults.set(true, forKey: Key.active)
            appDefaults.set(workspace.path, forKey: Key.path)
            if let sessionToken { appDefaults.set(sessionToken, forKey: Key.token) }
            NSLog("ShotPin: workspace cleanup is incomplete; it will be retried at %@",
                  workspace.path)
        }
        directory = nil
        sessionToken = nil
        ownsSession = false
        if !appDefaults.synchronize() {
            NSLog("ShotPin: could not flush workspace recovery state before exit")
        }
        // Keep the process lock until exit. A stale-cleanup callback from this
        // process must not race a new instance's recovery-state update.
    }

    private func recoverInterruptedSession() throws {
        guard appDefaults.bool(forKey: Key.active) else { return }
        if let path = appDefaults.string(forKey: Key.path) {
            guard restorePreviousLocation(expectedWorkspace: URL(fileURLWithPath: path)) else {
                throw WorkspaceError.preferencesUpdateFailed
            }
            enqueueStaleWorkspace(StaleWorkspace(
                path: path,
                token: appDefaults.string(forKey: Key.token),
                previousLocation: appDefaults.string(forKey: Key.previousLocation),
                previousLocationExisted: appDefaults.bool(forKey: Key.previousLocationExisted),
                endedAt: (appDefaults.object(forKey: Key.endedAt) as? Date) ?? Date()
            ))
        }
        clearRecoveryState()
    }

    func cleanupStaleWorkspaces() {
        guard !staleCleanupRunning else { return }
        let records = staleWorkspaces()
        guard !records.isEmpty else { return }
        staleCleanupRunning = true

        cleanupQueue.async { [self] in
            let remaining = records.filter { record in
                guard Date().timeIntervalSince(record.endedAt) >= 6 else { return true }
                let destination = captureDirectory(location: record.previousLocation,
                                                   existed: record.previousLocationExisted)
                return !discardWorkspace(at: URL(fileURLWithPath: record.path),
                                         token: record.token,
                                         destination: destination,
                                         allowCrossVolumeRecordingMoves: true,
                                         removeWorkspace: true)
            }
            DispatchQueue.main.async { [self] in
                appDefaults.set(remaining.map(\.propertyList), forKey: Key.staleWorkspaces)
                if !appDefaults.synchronize() {
                    NSLog("ShotPin: could not flush the stale-workspace queue")
                }
                staleCleanupRunning = false
            }
        }
    }

    private func enqueueStaleWorkspace(_ record: StaleWorkspace) {
        var records = staleWorkspaces().filter { $0.path != record.path }
        records.append(record)
        appDefaults.set(records.map(\.propertyList), forKey: Key.staleWorkspaces)
    }

    private func staleWorkspaces() -> [StaleWorkspace] {
        (appDefaults.array(forKey: Key.staleWorkspaces) as? [[String: Any]] ?? [])
            .compactMap(StaleWorkspace.init(propertyList:))
    }

    private func validateDirectory(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw WorkspaceError.unsafeRoot(directory.path)
        }
    }

    private func acquireProcessLock() throws {
        let lockPath = stateRoot.appendingPathComponent("runtime.lock").path
        let descriptor = open(lockPath,
                              O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                              S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw WorkspaceError.lockFailed(lockPath, errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { throw WorkspaceError.alreadyRunning }
            throw WorkspaceError.lockFailed(lockPath, code)
        }
        lockDescriptor = descriptor
    }

    private func releaseProcessLock() {
        guard lockDescriptor >= 0 else { return }
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }

    @discardableResult
    private func restorePreviousLocation(expectedWorkspace: URL) -> Bool {
        guard CFPreferencesAppSynchronize(captureDomain) else { return false }
        let current = currentCaptureLocation()
        if !locationsMatch(current, expectedWorkspace.path) {
            // A user or another tool changed the destination after our redirect.
            // Preserve that choice rather than overwriting it with stale state.
            savePreviousLocation(current)
            return appDefaults.synchronize()
        }
        if appDefaults.bool(forKey: Key.previousLocationExisted),
           let location = appDefaults.string(forKey: Key.previousLocation) {
            return setCaptureLocation(location)
        } else {
            CFPreferencesSetAppValue("location" as CFString, nil, captureDomain)
            guard CFPreferencesAppSynchronize(captureDomain) else { return false }
            return currentCaptureLocation() == nil
        }
    }

    private func currentCaptureLocation() -> String? {
        CFPreferencesCopyAppValue("location" as CFString, captureDomain) as? String
    }

    private func savePreviousLocation(_ location: String?) {
        appDefaults.set(location != nil, forKey: Key.previousLocationExisted)
        if let location {
            appDefaults.set(location, forKey: Key.previousLocation)
        } else {
            appDefaults.removeObject(forKey: Key.previousLocation)
        }
    }

    private func locationsMatch(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        let left = URL(fileURLWithPath: (lhs as NSString).expandingTildeInPath).standardizedFileURL
        let right = URL(fileURLWithPath: (rhs as NSString).expandingTildeInPath).standardizedFileURL
        return left == right
    }

    @discardableResult
    private func setCaptureLocation(_ path: String) -> Bool {
        CFPreferencesSetAppValue("location" as CFString, path as CFString, captureDomain)
        guard CFPreferencesAppSynchronize(captureDomain) else { return false }
        return locationsMatch(currentCaptureLocation(), path)
    }

    /// The screenshot preference also controls screen recordings made through
    /// Command-Shift-5. Preserve those in the user's original destination while
    /// deleting screenshots and other private workspace contents.
    @discardableResult
    private func ownershipMarker(for workspace: URL) -> URL {
        ownershipRoot.appendingPathComponent(workspace.lastPathComponent + ".token")
    }

    private func discardWorkspace(at workspace: URL,
                                  token: String?,
                                  destination: URL,
                                  allowCrossVolumeRecordingMoves: Bool,
                                  removeWorkspace: Bool,
                                  processRecordings: Bool = true) -> Bool {
        let candidate = workspace.standardizedFileURL
        guard UUID(uuidString: candidate.lastPathComponent) != nil else {
            NSLog("ShotPin: refusing to clean unowned workspace %@", workspace.path)
            return false
        }
        if token != nil {
            let expectedRoot = workspaceRoot.standardizedFileURL
            guard candidate.deletingLastPathComponent() == expectedRoot,
                  candidate.resolvingSymlinksInPath().deletingLastPathComponent()
                    == expectedRoot.resolvingSymlinksInPath() else {
                NSLog("ShotPin: refusing to clean workspace outside the private root %@",
                      workspace.path)
                return false
            }
        } else {
            // Compatibility for recovery state written before ownership markers existed.
            let legacyRoot = shotFileManager.temporaryDirectory
                .appendingPathComponent("ShotPin", isDirectory: true)
                .standardizedFileURL
            guard candidate.deletingLastPathComponent() == legacyRoot,
                  candidate.resolvingSymlinksInPath().deletingLastPathComponent()
                    == legacyRoot.resolvingSymlinksInPath() else {
                NSLog("ShotPin: refusing to clean unowned legacy workspace %@", workspace.path)
                return false
            }
        }
        let marker = ownershipMarker(for: candidate)
        guard shotFileManager.fileExists(atPath: candidate.path) else {
            try? shotFileManager.removeItem(at: marker)
            try? shotFileManager.removeItem(at: moveJournalURL(for: candidate))
            return true
        }
        guard let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            NSLog("ShotPin: refusing to clean unsafe workspace %@", workspace.path)
            return false
        }
        if let token {
            guard let markerToken = try? String(contentsOf: marker, encoding: .utf8),
                  markerToken == token else {
                NSLog("ShotPin: refusing to clean workspace with invalid ownership marker %@",
                      workspace.path)
                return false
            }
        }
        guard var moveJournal = loadMoveJournal(for: candidate),
              let contents = try? shotFileManager.contentsOfDirectory(
            at: candidate,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else { return false }

        var complete = true
        for url in contents {
            let isRecording = recordingExtensions.contains(url.pathExtension.lowercased())
            if isRecording {
                guard processRecordings else {
                    complete = false
                    continue
                }
                do {
                    let fileValues = try url.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey
                    ])
                    guard fileValues.isRegularFile == true,
                          fileValues.isSymbolicLink != true else {
                        complete = false
                        NSLog("ShotPin: refusing to preserve non-regular recording at %@", url.path)
                        continue
                    }
                    try shotFileManager.createDirectory(at: destination,
                                                        withIntermediateDirectories: true)
                    let resolvedDestination = destination.resolvingSymlinksInPath()
                        .standardizedFileURL
                    let destinationValues = try resolvedDestination.resourceValues(forKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey
                    ])
                    guard destinationValues.isDirectory == true,
                          destinationValues.isSymbolicLink != true,
                          !isContained(resolvedDestination, in: candidate) else {
                        complete = false
                        NSLog("ShotPin: refusing an unsafe recording directory at %@",
                              destination.path)
                        continue
                    }
                    let crossesVolumes = !sameVolume(url, resolvedDestination)
                    if isFileOpen(url) != false {
                        complete = false
                        NSLog("ShotPin: deferring open recording at %@", url.path)
                        continue
                    }
                    if crossesVolumes && !allowCrossVolumeRecordingMoves {
                        complete = false
                        NSLog("ShotPin: deferring cross-volume recording move at %@", url.path)
                        continue
                    }
                    if crossesVolumes || moveJournal[url.lastPathComponent] != nil {
                        guard let target = journaledDestination(for: url,
                                                                workspace: candidate,
                                                                destination: resolvedDestination,
                                                                journal: &moveJournal) else {
                            complete = false
                            continue
                        }
                        let staging = resolvedDestination.appendingPathComponent(
                            ".shotpin-\(candidate.lastPathComponent).partial"
                        )
                        try preserveCrossVolumeRecording(at: url,
                                                       to: target,
                                                       through: staging)
                        moveJournal.removeValue(forKey: url.lastPathComponent)
                        if !persistMoveJournal(moveJournal, for: candidate) {
                            complete = false
                        }
                    } else {
                        let target = uniqueDestination(for: url.lastPathComponent,
                                                       in: resolvedDestination)
                        try shotFileManager.moveItem(at: url, to: target)
                    }
                } catch {
                    complete = false
                    NSLog("ShotPin: could not preserve recording at %@: %@",
                          url.path, error.localizedDescription)
                }
            } else {
                if let attributes = try? shotFileManager.attributesOfItem(atPath: url.path),
                   let modified = attributes[.modificationDate] as? Date,
                   Date().timeIntervalSince(modified) < 2 {
                    complete = false
                    NSLog("ShotPin: deferring cleanup of recently modified file at %@", url.path)
                    continue
                }
                if unlink(url.path) != 0 {
                    complete = false
                    let code = errno
                    NSLog("ShotPin: could not unlink workspace item at %@ (errno %d)",
                          url.path, code)
                }
            }
        }

        if complete && removeWorkspace {
            if rmdir(candidate.path) == 0 {
                try? shotFileManager.removeItem(at: marker)
                try? shotFileManager.removeItem(at: moveJournalURL(for: candidate))
            } else {
                complete = false
                NSLog("ShotPin: workspace changed during cleanup at %@", candidate.path)
            }
        } else if !removeWorkspace {
            // Keep the path and ownership record through process exit so a native
            // capture that already selected this directory can still publish safely.
            complete = false
        }
        return complete
    }

    private func moveJournalURL(for workspace: URL) -> URL {
        ownershipRoot.appendingPathComponent(workspace.lastPathComponent + ".moves.plist")
    }

    /// A destination is committed before a cross-volume copy starts. If ShotPin
    /// stops after publishing the copy but before deleting the source, the next
    /// pass retries source removal against the same file instead of making a new
    /// uniquely named duplicate.
    private func journaledDestination(for source: URL,
                                      workspace: URL,
                                      destination: URL,
                                      journal: inout [String: String]) -> URL? {
        let key = source.lastPathComponent
        let expectedParent = destination.standardizedFileURL
        if let savedPath = journal[key] {
            let saved = URL(fileURLWithPath: savedPath).resolvingSymlinksInPath()
                .standardizedFileURL
            guard validJournalDestination(saved,
                                          for: source,
                                          workspace: workspace,
                                          destination: expectedParent,
                                          journal: journal) else {
                NSLog("ShotPin: refusing an invalid recording destination at %@", saved.path)
                return nil
            }
            return saved
        }

        let reserved = Set(journal.values.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        })
        let target = uniqueDestination(for: key, in: expectedParent, reserved: reserved)
        guard validJournalDestination(target,
                                      for: source,
                                      workspace: workspace,
                                      destination: expectedParent,
                                      journal: journal) else {
            NSLog("ShotPin: refusing an unsafe recording destination at %@", target.path)
            return nil
        }
        journal[key] = target.path
        guard persistMoveJournal(journal, for: workspace) else {
            journal.removeValue(forKey: key)
            return nil
        }
        return target
    }

    private func validJournalDestination(_ target: URL,
                                         for source: URL,
                                         workspace: URL,
                                         destination: URL,
                                         journal: [String: String]) -> Bool {
        let normalized = target.standardizedFileURL
        let staging = destination.appendingPathComponent(
            ".shotpin-\(workspace.lastPathComponent).partial"
        ).standardizedFileURL
        guard normalized.deletingLastPathComponent() == destination,
              normalized != source.standardizedFileURL,
              normalized != staging,
              !normalized.lastPathComponent.hasPrefix("."),
              !isContained(normalized, in: workspace),
              !isContained(staging, in: workspace) else { return false }

        return !journal.contains { key, savedPath in
            key != source.lastPathComponent
                && URL(fileURLWithPath: savedPath).resolvingSymlinksInPath()
                    .standardizedFileURL == normalized
        }
    }

    private func isContained(_ candidate: URL, in directory: URL) -> Bool {
        let candidateParts = candidate.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let directoryParts = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard candidateParts.count >= directoryParts.count else { return false }
        return zip(directoryParts, candidateParts).allSatisfy(==)
    }

    private func loadMoveJournal(for workspace: URL) -> [String: String]? {
        let url = moveJournalURL(for: workspace)
        guard shotFileManager.fileExists(atPath: url.path) else { return [:] }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey,
                                                           .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                NSLog("ShotPin: refusing an unsafe recording move journal at %@", url.path)
                return nil
            }
            let data = try Data(contentsOf: url)
            guard let value = try PropertyListSerialization.propertyList(from: data,
                                                                          format: nil)
                    as? [String: String] else {
                NSLog("ShotPin: could not read recording move journal at %@", url.path)
                return nil
            }
            return value
        } catch {
            NSLog("ShotPin: could not read recording move journal at %@: %@",
                  url.path, error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    private func persistMoveJournal(_ journal: [String: String], for workspace: URL) -> Bool {
        let url = moveJournalURL(for: workspace)
        do {
            if shotFileManager.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey,
                                                               .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    NSLog("ShotPin: refusing to replace an unsafe recording move journal at %@",
                          url.path)
                    return false
                }
            }
            if journal.isEmpty {
                try? shotFileManager.removeItem(at: url)
            } else {
                let data = try PropertyListSerialization.data(fromPropertyList: journal,
                                                               format: .binary,
                                                               options: 0)
                try data.write(to: url, options: .atomic)
            }
            return true
        } catch {
            NSLog("ShotPin: could not update recording move journal at %@: %@",
                  url.path, error.localizedDescription)
            return false
        }
    }

    private func preserveCrossVolumeRecording(at source: URL,
                                              to target: URL,
                                              through staging: URL) throws {
        let workspace = source.deletingLastPathComponent()
        guard target.standardizedFileURL != staging.standardizedFileURL,
              target.standardizedFileURL != source.standardizedFileURL,
              !isContained(target, in: workspace),
              !isContained(staging, in: workspace) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if shotFileManager.fileExists(atPath: target.path) {
            let values = try target.resourceValues(forKeys: [.isRegularFileKey,
                                                              .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  sameFileIdentity(source, target) == false,
                  shotFileManager.contentsEqual(atPath: source.path,
                                                andPath: target.path),
                  isFileOpen(source) == false else {
                throw CocoaError(.fileWriteFileExists)
            }
            try shotFileManager.removeItem(at: source)
            try? shotFileManager.removeItem(at: staging)
            return
        }

        try? shotFileManager.removeItem(at: staging)
        try shotFileManager.copyItem(at: source, to: staging)
        guard isFileOpen(source) == false,
              sameFileIdentity(source, staging) == false,
              !isContained(staging, in: workspace),
              shotFileManager.contentsEqual(atPath: source.path,
                                            andPath: staging.path) else {
            try? shotFileManager.removeItem(at: staging)
            throw CocoaError(.fileReadCorruptFile)
        }
        try shotFileManager.moveItem(at: staging, to: target)
        guard sameFileIdentity(source, target) == false,
              !isContained(target, in: workspace),
              shotFileManager.contentsEqual(atPath: source.path,
                                            andPath: target.path),
              isFileOpen(source) == false else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try shotFileManager.removeItem(at: source)
    }

    private func sameFileIdentity(_ first: URL, _ second: URL) -> Bool? {
        guard let firstAttributes = try? shotFileManager.attributesOfItem(atPath: first.path),
              let secondAttributes = try? shotFileManager.attributesOfItem(atPath: second.path),
              let firstDevice = firstAttributes[.systemNumber] as? NSNumber,
              let secondDevice = secondAttributes[.systemNumber] as? NSNumber,
              let firstInode = firstAttributes[.systemFileNumber] as? NSNumber,
              let secondInode = secondAttributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return firstDevice == secondDevice && firstInode == secondInode
    }

    private func sameVolume(_ file: URL, _ directory: URL) -> Bool {
        guard let fileDevice = (try? shotFileManager.attributesOfItem(atPath: file.path))?[.systemNumber]
                as? NSNumber,
              let directoryDevice = (try? shotFileManager.attributesOfItem(atPath: directory.path))?[.systemNumber]
                as? NSNumber else { return false }
        return fileDevice == directoryDevice
    }

    /// Cross-volume moves are copy-and-delete operations, so only start one after
    /// no process has the recording open. An unavailable or inconclusive lsof check
    /// is treated conservatively and retried by the stale-workspace queue.
    private func isFileOpen(_ url: URL) -> Bool? {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", url.path]
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        if process.terminationStatus == 0 { return true }
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 1 && errorData.isEmpty { return false }
        return nil
    }

    private func previousCaptureDirectory() -> URL {
        captureDirectory(location: appDefaults.string(forKey: Key.previousLocation),
                         existed: appDefaults.bool(forKey: Key.previousLocationExisted))
    }

    private func captureDirectory(location: String?, existed: Bool) -> URL {
        if existed, let path = location, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        return shotFileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    private func uniqueDestination(for name: String,
                                   in directory: URL,
                                   reserved: Set<String> = []) -> URL {
        let original = directory.appendingPathComponent(name)
        guard shotFileManager.fileExists(atPath: original.path)
                || reserved.contains(original.standardizedFileURL.path) else { return original }
        let source = URL(fileURLWithPath: name)
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        for index in 2...10_000 {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !shotFileManager.fileExists(atPath: candidate.path),
               !reserved.contains(candidate.standardizedFileURL.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    private func clearRecoveryState() {
        appDefaults.removeObject(forKey: Key.active)
        appDefaults.removeObject(forKey: Key.path)
        appDefaults.removeObject(forKey: Key.token)
        appDefaults.removeObject(forKey: Key.endedAt)
        appDefaults.removeObject(forKey: Key.previousLocation)
        appDefaults.removeObject(forKey: Key.previousLocationExisted)
    }
}

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

        let glyph = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Delete Screenshot")
        closeButton.image = glyph
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.contentTintColor = NSColor.systemRed
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.frame = NSRect(x: 2, y: total.height - 22, width: 20, height: 20)
        closeButton.target = self
        closeButton.action = #selector(trashFile)
        closeButton.isHidden = true
        addSubview(closeButton)

        let tracking = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways],
                                      owner: self,
                                      userInfo: nil)
        addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    /// The card and image view are visual-only. Keep the close button interactive,
    /// but route the rest of the thumbnail's mouse sequence through ShotView so its
    /// click and drag handling cannot be swallowed by an NSImageView/NSControl.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        let closePoint = closeButton.convert(point, from: self)
        if !closeButton.isHidden, closeButton.bounds.contains(closePoint) {
            return closeButton
        }
        return self
    }

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
        item.setDraggingFrame(card.frame, contents: dragImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let shouldOpen = !draggingOut && bounds.contains(point)
        mouseDownPoint = nil
        draggingOut = false
        if shouldOpen {
            openFile()
        }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .copy
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // AppKit may end the dragging session before delivering the source
        // view's mouseUp. Keep the flag set so that mouseUp cannot interpret
        // the completed drag as a click and open the screenshot.
    }

    // MARK: context menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openFile), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Image", action: #selector(copyImage), keyEquivalent: "")
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete Screenshot", action: #selector(trashFile), keyEquivalent: "")
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
        if !NSWorkspace.shared.open(url) {
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
                if !pasteboard.writeObjects([item]) {
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
    }

    @objc private func trashFile() {
        do {
            try shotFileManager.removeItem(at: url)
            dismissPin()
        } catch {
            showError("Couldn't delete the screenshot")
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
        sharingType = .none

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

    func add(url: URL, image: NSImage, targetDisplayID: CGDirectDisplayID) {
        let screen = NSScreen.screens.first(where: { $0.displayID == targetDisplayID })
            ?? NSScreen.main
            ?? NSScreen.screens.first
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
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var terminationPending = false
    private var pending: [FileIdentity: UUID] = [:]
    private var handled = Set<FileIdentity>()

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
        let creationDate: Date

        init?(attributes: [FileAttributeKey: Any]) {
            guard let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let creationDate = attributes[.creationDate] as? Date else { return nil }
            self.device = device.uint64Value
            self.inode = inode.uint64Value
            self.creationDate = creationDate
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try CaptureWorkspace.shared.begin()
        } catch {
            NSLog("ShotPin: could not create private capture workspace: %@", error.localizedDescription)
            NSApp.terminate(nil)
            return
        }
        installTerminationSignalHandlers()
        guard configureWatcher(force: true) else {
            NSApp.terminate(nil)
            return
        }
        do {
            try CaptureWorkspace.shared.activate()
        } catch {
            NSLog("ShotPin: could not redirect screenshots: %@", error.localizedDescription)
            NSApp.terminate(nil)
            return
        }
        CaptureWorkspace.shared.cleanupStaleWorkspaces()
        watcherRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard CaptureWorkspace.shared.maintainRedirect() else {
                NSApp.terminate(nil)
                return
            }
            CaptureWorkspace.shared.cleanupStaleWorkspaces()
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        watcherRefreshTimer?.invalidate()
        watcher = nil
        CaptureWorkspace.shared.end {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// launchctl normally stops agents with SIGTERM. Convert that signal into a
    /// normal AppKit termination so the capture location is always restored.
    private func installTerminationSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    @discardableResult
    private func configureWatcher(force: Bool) -> Bool {
        let directory = (CaptureWorkspace.shared.directory ?? screenshotDirectory()).standardizedFileURL
        guard force || directory != watchedDirectory || watcher == nil else { return true }
        watcher = nil
        watchedDirectory = directory
        do {
            watcher = try DirectoryWatcher(path: directory.path) { [weak self] events in
                self?.receive(events)
            }
            NSLog("ShotPin: watching %@", directory.path)
            // The stream starts at "now", so scan after it is live to close the
            // redirect-to-watcher startup gap without losing intervening captures.
            rescanWatchedDirectory()
            return true
        } catch {
            NSLog("ShotPin: watcher unavailable for %@: %@; retrying", directory.path, error.localizedDescription)
            return false
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
              let identity = FileIdentity(attributes: attributes) else { return }
        let isPrivateDirectory = CaptureWorkspace.shared.directory?.standardizedFileURL == directory
        if !isPrivateDirectory {
            let age = Date().timeIntervalSince(identity.creationDate)
            guard age >= 0, age < 15 else { return }
        }
        guard pending[identity] == nil, !handled.contains(identity) else { return }
        let token = UUID()
        let pointer = NSEvent.mouseLocation
        let targetDisplayID = NSScreen.screens.first(where: { $0.frame.contains(pointer) })?.displayID
            ?? NSScreen.main?.displayID
            ?? NSScreen.screens.first?.displayID
            ?? 0
        pending[identity] = token
        pin(url: url,
            identity: identity,
            token: token,
            targetDisplayID: targetDisplayID,
            attempt: 0,
            lastSize: -1,
            stableSamples: 0)
    }

    /// Spotlight metadata and the file bytes both land slightly after the create
    /// event, so retry briefly before giving up or pinning on the fallback path.
    private func pin(url: URL,
                     identity: FileIdentity,
                     token: UUID,
                     targetDisplayID: CGDirectDisplayID,
                     attempt: Int,
                     lastSize: Int,
                     stableSamples: Int) {
        guard pending[identity] == token else { return }
        let maxAttempts = 20
        let attributes = try? shotFileManager.attributesOfItem(atPath: url.path)
        guard let attributes, FileIdentity(attributes: attributes) == identity else {
            pending.removeValue(forKey: identity)
            return
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let nextStableSamples = size > 0 && size == lastSize ? stableSamples + 1 : 0
        let stable = nextStableSamples >= 2
        let capture = isScreenCapture(url)
        let isPrivateCapture = CaptureWorkspace.shared.directory?.standardizedFileURL
            == url.deletingLastPathComponent().standardizedFileURL

        if !isPrivateCapture && capture == false {
            pending.removeValue(forKey: identity)
            handled.insert(identity)
            return
        }
        let exhausted = attempt >= maxAttempts
        // When Spotlight is unavailable, only macOS' generated filename is accepted.
        // Arbitrarily named screencapture CLI output normally carries Spotlight's
        // capture attribute and follows the authoritative branch above.
        let generatedNameFallback = capture == nil && hasGeneratedScreenshotName(url)
        if (stable && isPrivateCapture)
            || (stable && capture == true)
            || (exhausted && stable && generatedNameFallback) {
            show(url: url,
                 identity: identity,
                 token: token,
                 targetDisplayID: targetDisplayID,
                 attempt: attempt,
                 size: size)
            return
        }
        guard !exhausted else {
            pending.removeValue(forKey: identity)
            handled.insert(identity)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pin(url: url,
                      identity: identity,
                      token: token,
                      targetDisplayID: targetDisplayID,
                      attempt: attempt + 1,
                      lastSize: size,
                      stableSamples: nextStableSamples)
        }
    }

    private func show(url: URL,
                      identity: FileIdentity,
                      token: UUID,
                      targetDisplayID: CGDirectDisplayID,
                      attempt: Int,
                      size: Int) {
        guard pending[identity] == token,
              shotFileManager.fileExists(atPath: url.path) else {
            pending.removeValue(forKey: identity)
            return
        }
        ThumbnailLoader.load(url) { [weak self] image in
            guard let self, self.pending[identity] == token else { return }
            guard let attributes = try? shotFileManager.attributesOfItem(atPath: url.path),
                  FileIdentity(attributes: attributes) == identity else {
                self.pending.removeValue(forKey: identity)
                return
            }
            if let image, image.size.width > 0, image.size.height > 0 {
                self.pending.removeValue(forKey: identity)
                self.handled.insert(identity)
                PinManager.shared.add(url: url,
                                      image: image,
                                      targetDisplayID: targetDisplayID)
                return
            }

            let maxAttempts = 20
            guard attempt < maxAttempts else {
                self.pending.removeValue(forKey: identity)
                self.handled.insert(identity)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.pin(url: url,
                          identity: identity,
                          token: token,
                          targetDisplayID: targetDisplayID,
                          attempt: attempt + 1,
                          lastSize: size,
                          stableSamples: 2)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
