import AppKit
import Observation

struct Location: Identifiable, Hashable {
    let url: URL
    let name: String
    /// Fraction of the volume in use; nil for plain folders.
    var usedFraction: Double?
    var detail: String?

    var id: URL { url }
    var isVolume: Bool { usedFraction != nil }
}

/// One location's scan result and browsing position. Kept for as long as the app runs.
@MainActor
@Observable
final class ScanSession {
    let location: Location

    /// Folders from the scan root down to the one on screen.
    var path: [FileNode] = []
    var selection: FileNode.ID?
    var scannedCount = 0
    var unreadableCount = 0
    var scanError: String?
    var storage: StorageBreakdown?
    private(set) var scanner: DiskScanner?

    @ObservationIgnored private var database: ScanDatabase?

    var current: FileNode? { path.last }
    var isScanning: Bool { scanner != nil }
    var isAtRoot: Bool { path.count == 1 }

    init(location: Location) {
        self.location = location
    }

    func start() {
        scanner?.cancel()
        scannedCount = 0
        unreadableCount = 0
        scanError = nil
        storage = nil
        path = []
        selection = nil
        database?.destroy()
        database = nil

        let reportProgress: @Sendable (Int) -> Void = { count in
            Task { @MainActor in
                if self.isScanning { self.scannedCount = count }
            }
        }

        let scanner = DiskScanner(onProgress: reportProgress)
        self.scanner = scanner
        let url = location.url
        let isVolume = location.isVolume

        Task {
            // scan() blocks, so it stays off the Swift cooperative pool.
            let outcome = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Self.runScan(scanner, url: url, isVolume: isVolume))
                }
            }

            guard self.scanner === scanner else {
                if case .finished(let finished) = outcome { finished.database.destroy() }
                return
            }
            self.scanner = nil

            switch outcome {
            case .finished(let finished):
                self.database = finished.database
                self.path = [finished.root]
                self.unreadableCount = finished.unreadableCount
                self.storage = finished.storage
            case .failed(let message):
                self.scanError = message
            case .cancelled:
                break
            }
        }
    }

    func cancel() {
        scanner?.cancel()
        scanner = nil
    }

    func open(_ node: FileNode) {
        if let id = node.directoryID, let database {
            path.append(database.loadDirectory(id: id, path: node.path, name: node.name, size: node.size))
            selection = nil
        } else {
            revealInFinder(node)
        }
    }

    func goUp() {
        guard path.count > 1 else { return }
        selection = path.removeLast().id
    }

    func revealInFinder(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    private struct FinishedScan: Sendable {
        let database: ScanDatabase
        let root: FileNode
        let unreadableCount: Int
        let storage: StorageBreakdown?
    }

    private enum ScanOutcome: Sendable {
        case finished(FinishedScan)
        case failed(String)
        case cancelled
    }

    private nonisolated static func runScan(_ scanner: DiskScanner, url: URL, isVolume: Bool) -> ScanOutcome {
        let database: ScanDatabase
        do {
            database = try ScanDatabase(url: ScanStorage.newDatabaseURL())
        } catch {
            return .failed(String(describing: error))
        }

        do {
            let name = url.path == "/" ? "/" : url.lastPathComponent
            guard let summary = try scanner.scan(url.path, name: name, into: database) else {
                database.destroy()
                return .cancelled
            }
            let root = database.loadDirectory(id: 1, path: url.path, name: name, size: summary.rootSize)
            let storage = isVolume ? StorageBreakdown.load(mountPath: url.path, scanned: summary.rootSize) : nil
            return .finished(
                FinishedScan(
                    database: database, root: root, unreadableCount: summary.unreadableCount, storage: storage))
        } catch {
            database.destroy()
            return .failed(String(describing: error))
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var locations: [Location]
    var selectedURL: URL?

    private var sessions: [URL: ScanSession] = [:]

    var selectedSession: ScanSession? { selectedURL.flatMap { sessions[$0] } }

    init() {
        locations = Self.loadLocations()
        for location in locations {
            sessions[location.url] = ScanSession(location: location)
        }
        selectedURL = locations.first?.url
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if sessions[url] == nil {
            let location = Location(url: url, name: url.lastPathComponent)
            locations.append(location)
            sessions[url] = ScanSession(location: location)
        }
        selectedURL = url
    }

    private static func loadLocations() -> [Location] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []

        let volumeLocations = volumes.compactMap { url -> Location? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                let total = values.volumeTotalCapacity, total > 0
            else { return nil }
            let available = values.volumeAvailableCapacityForImportantUsage ?? 0
            let used = max(0, Int64(total) - available)
            return Location(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                usedFraction: Double(used) / Double(total),
                detail: "Свободно \(formatSize(available)) из \(formatSize(Int64(total)))")
        }

        let home = Location(url: FileManager.default.homeDirectoryForCurrentUser, name: "Домашняя папка")
        return volumeLocations + [home]
    }
}

func formatSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
