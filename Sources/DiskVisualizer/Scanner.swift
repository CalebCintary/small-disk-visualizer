import Darwin
import Foundation

/// One entry shown in the UI. Only the folder on screen has `children` loaded;
/// the full tree lives in `ScanDatabase`.
final class FileNode: Identifiable, Hashable, @unchecked Sendable {
    let path: String
    let name: String
    let size: Int64
    /// Row in `ScanDatabase`; nil for files.
    let directoryID: Int64?
    /// Sorted by size, largest first.
    let children: [FileNode]

    var id: String { path }
    var isDirectory: Bool { directoryID != nil }
    var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }

    init(path: String, name: String, size: Int64, directoryID: Int64?, children: [FileNode]) {
        self.path = path
        self.name = name
        self.size = size
        self.directoryID = directoryID
        self.children = children
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ScanSummary: Sendable {
    let rootSize: Int64
    let unreadableCount: Int
}

/// Directories are listed by a pool of threads pulling from a shared stack, and rows
/// reach SQLite through a bounded queue, so memory stays flat however large the disk is.
///
/// What is counted: real files and directories on the scanned volume. Symlinks are never
/// followed, any directory on another device (mount points, other disks) is skipped, and
/// a hard-linked file is counted once.
final class DiskScanner: @unchecked Sendable {
    private struct PendingDirectory {
        let id: Int64
        let path: String
    }

    private enum Attr {
        static let bitmapCount: UInt16 = 5
        static let returnedAttrs: UInt32 = 0x8000_0000
        static let error: UInt32 = 0x2000_0000
        static let name: UInt32 = 0x0000_0001
        static let objectType: UInt32 = 0x0000_0008
        static let fileID: UInt32 = 0x0200_0000
        static let fileLinkCount: UInt32 = 0x0000_0001
        static let fileAllocSize: UInt32 = 0x0000_0004
        static let packInvalid: UInt64 = 0x0000_0008
        static let typeRegular: UInt32 = 1
        static let typeDirectory: UInt32 = 2
    }

    private static let progressStep = 2000
    private static let batchRows = 8192
    private static let maxQueuedBatches = 32
    private static let bulkBufferSize = 256 * 1024

    private let onProgress: @Sendable (Int) -> Void

    // All guarded by `condition`.
    private let condition = NSCondition()
    private var stack: [PendingDirectory] = []
    private var activeWorkers = 0
    private var isCancelled = false
    private var scannedCount = 0
    private var unreadableCount = 0
    private var queuedBatches: [RowBatch] = []
    private var workersFinished = false
    private var writeError: Error?
    /// Index 0 is unused so directory ids can start at 1.
    private var directoryParents: [Int64] = [0]
    private var directorySizes: [Int64] = [0]

    private let hardLinkLock = NSLock()
    private var seenHardLinks: Set<UInt64> = []

    // Set before the workers start, read-only afterwards.
    private var allowedDevices: Set<dev_t> = []
    private var excludedPaths: Set<String> = []

    init(onProgress: @escaping @Sendable (Int) -> Void) {
        self.onProgress = onProgress
    }

    func cancel() {
        condition.withLock {
            isCancelled = true
            condition.broadcast()
        }
    }

    /// Blocks until finished. Returns nil if cancelled.
    func scan(_ rootPath: String, name: String, into database: ScanDatabase) throws -> ScanSummary? {
        configureBoundaries(rootPath: rootPath)

        var firstBatch = RowBatch()
        firstBatch.append(id: 1, parent: 0, size: 0, name: Array(name.utf8))
        queuedBatches = [firstBatch]
        directoryParents.append(0)
        directorySizes.append(0)
        stack = [PendingDirectory(id: 1, path: rootPath)]

        let writerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            self.runWriter(database)
            writerDone.signal()
        }

        DispatchQueue.concurrentPerform(iterations: ProcessInfo.processInfo.activeProcessorCount) { _ in
            runWorker()
        }

        condition.withLock {
            workersFinished = true
            condition.broadcast()
        }
        writerDone.wait()

        let state = condition.withLock { (isCancelled, writeError, scannedCount, unreadableCount) }
        if let error = state.1 { throw error }
        if state.0 { return nil }

        // A child's id is always greater than its parent's, so one reverse pass rolls sizes up.
        var sizes = directorySizes
        var id = sizes.count - 1
        while id > 1 {
            sizes[Int(directoryParents[id])] += sizes[id]
            id -= 1
        }

        try database.finish(directorySizes: sizes)
        onProgress(state.2)
        return ScanSummary(rootSize: sizes[1], unreadableCount: state.3)
    }

    private func configureBoundaries(rootPath: String) {
        var devices: Set<dev_t> = []
        var info = stat()
        if stat(rootPath, &info) == 0 { devices.insert(info.st_dev) }

        var excluded: Set<String> = []
        if rootPath == "/" {
            // "/" spans the read-only system volume and, through firmlinks, the Data volume.
            if stat("/System/Volumes/Data", &info) == 0 { devices.insert(info.st_dev) }
            // Reaching Data here too would count everything twice.
            excluded = ["/System/Volumes", "/Volumes"]
        }
        if let ownFiles = realpath(ScanStorage.directory.path, nil) {
            excluded.insert(String(cString: ownFiles))
            free(ownFiles)
        }
        allowedDevices = devices
        excludedPaths = excluded
    }

    private func runWriter(_ database: ScanDatabase) {
        while true {
            condition.lock()
            while queuedBatches.isEmpty && !workersFinished && !isCancelled {
                condition.wait()
            }
            if isCancelled || queuedBatches.isEmpty {
                condition.unlock()
                return
            }
            let batch = queuedBatches.removeFirst()
            condition.broadcast()
            condition.unlock()

            do {
                try database.write(batch)
            } catch {
                condition.withLock {
                    writeError = error
                    isCancelled = true
                    condition.broadcast()
                }
                return
            }
        }
    }

    private func runWorker() {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.bulkBufferSize, alignment: 8)
        defer { buffer.deallocate() }
        var batch = RowBatch()

        while let directory = nextDirectory() {
            process(directory, buffer: buffer, batch: &batch)
            if batch.count >= Self.batchRows {
                enqueue(batch)
                batch = RowBatch()
            }
        }
        if batch.count > 0 { enqueue(batch) }
    }

    /// Blocks while the writer is behind, which is what bounds memory.
    private func enqueue(_ batch: RowBatch) {
        condition.lock()
        defer { condition.unlock() }
        while queuedBatches.count >= Self.maxQueuedBatches && !isCancelled {
            condition.wait()
        }
        guard !isCancelled else { return }
        queuedBatches.append(batch)
        condition.broadcast()
    }

    /// Blocks until work is available; nil means the scan is finished or cancelled.
    private func nextDirectory() -> PendingDirectory? {
        condition.lock()
        defer { condition.unlock() }

        while true {
            if isCancelled { return nil }
            if let directory = stack.popLast() {
                activeWorkers += 1
                return directory
            }
            if activeWorkers == 0 {
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
    }

    private func process(
        _ directory: PendingDirectory, buffer: UnsafeMutableRawBufferPointer, batch: inout RowBatch
    ) {
        var subdirectoryNames: [String] = []
        var scanned = 0
        var unreadable = 0
        var filesSize: Int64 = 0

        // O_NOFOLLOW plus the device check on the opened descriptor can't be raced by a
        // path changing underneath us, and catches every kind of mount point.
        let descriptor = excludedPaths.contains(directory.path)
            ? -1 : open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()

        if descriptor < 0 {
            if !excludedPaths.contains(directory.path) { unreadable += 1 }
        } else {
            defer { close(descriptor) }
            if fstat(descriptor, &info) == 0, allowedDevices.contains(info.st_dev) {
                var request = attrlist()
                request.bitmapcount = Attr.bitmapCount
                request.commonattr = Attr.returnedAttrs | Attr.error | Attr.name | Attr.objectType | Attr.fileID
                request.fileattr = Attr.fileLinkCount | Attr.fileAllocSize
                let device = info.st_dev

                while true {
                    let count = getattrlistbulk(
                        descriptor, &request, buffer.baseAddress, buffer.count, Attr.packInvalid)
                    if count < 0 { unreadable += 1 }
                    if count <= 0 { break }

                    var entry = 0
                    for _ in 0..<count {
                        let length = Int(buffer.loadUnaligned(fromByteOffset: entry, as: UInt32.self))
                        defer { entry += length }

                        // Layout: length, attribute_set_t (20 bytes), then attributes in bit order.
                        var cursor = entry + 24
                        let error = buffer.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                        cursor += 4
                        if error != 0 {
                            unreadable += 1
                            continue
                        }

                        let nameReference = cursor
                        let nameOffset = Int(buffer.loadUnaligned(fromByteOffset: cursor, as: Int32.self))
                        let nameLength = Int(buffer.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self))
                        cursor += 8
                        let type = buffer.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                        cursor += 4
                        let fileID = buffer.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)
                        cursor += 8
                        let linkCount = buffer.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                        cursor += 4
                        var size = buffer.loadUnaligned(fromByteOffset: cursor, as: Int64.self)

                        // The stored length includes the trailing NUL.
                        let nameStart = nameReference + nameOffset
                        let name = UnsafeRawBufferPointer(rebasing: buffer[nameStart..<(nameStart + nameLength - 1)])

                        if type == Attr.typeDirectory {
                            subdirectoryNames.append(String(decoding: name, as: UTF8.self))
                        } else if type == Attr.typeRegular {
                            if linkCount > 1 && !claimHardLink(device: device, fileID: fileID) { size = 0 }
                            filesSize += size
                            batch.append(id: 0, parent: directory.id, size: size, name: name)
                        } else {
                            // Symlinks, sockets, devices.
                            continue
                        }
                        scanned += 1
                    }
                }
            }
        }

        finishDirectory(
            directory, filesSize: filesSize, subdirectoryNames: subdirectoryNames,
            scanned: scanned, unreadable: unreadable, batch: &batch)
    }

    /// True the first time this inode is seen.
    private func claimHardLink(device: dev_t, fileID: UInt64) -> Bool {
        let key = fileID ^ (UInt64(UInt32(bitPattern: device)) << 44)
        return hardLinkLock.withLock { seenHardLinks.insert(key).inserted }
    }

    private func finishDirectory(
        _ directory: PendingDirectory, filesSize: Int64, subdirectoryNames: [String],
        scanned: Int, unreadable: Int, batch: inout RowBatch
    ) {
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"

        var firstChildID: Int64 = 0
        var progress: Int?
        condition.withLock {
            firstChildID = Int64(directorySizes.count)
            directorySizes[Int(directory.id)] = filesSize
            directorySizes.append(contentsOf: repeatElement(0, count: subdirectoryNames.count))
            directoryParents.append(contentsOf: repeatElement(directory.id, count: subdirectoryNames.count))

            for (offset, name) in subdirectoryNames.enumerated() {
                stack.append(PendingDirectory(id: firstChildID + Int64(offset), path: prefix + name))
            }

            let previous = scannedCount
            scannedCount += scanned
            unreadableCount += unreadable
            if scannedCount / Self.progressStep != previous / Self.progressStep { progress = scannedCount }

            activeWorkers -= 1
            condition.broadcast()
        }

        for (offset, name) in subdirectoryNames.enumerated() {
            batch.append(id: firstChildID + Int64(offset), parent: directory.id, size: 0, name: Array(name.utf8))
        }
        if let progress { onProgress(progress) }
    }
}
