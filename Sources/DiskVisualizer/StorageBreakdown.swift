import Darwin
import Foundation
import SwiftUI

struct StorageSegment: Identifiable, Sendable {
    let title: String
    let bytes: Int64
    let color: Color
    var detail: String?

    var id: String { title }
}

/// Where a whole volume's space goes, including what a file walk can't see.
struct StorageBreakdown: Sendable {
    let capacity: Int64
    let segments: [StorageSegment]

    /// `mountPath` must be the root of a volume; `scanned` is what the walk found on it.
    static func load(mountPath: String, scanned: Int64) -> StorageBreakdown? {
        apfs(mountPath: mountPath, scanned: scanned) ?? plain(mountPath: mountPath, scanned: scanned)
    }

    private static func filesSegment(_ scanned: Int64) -> StorageSegment {
        StorageSegment(title: "Файлы", bytes: scanned, color: .blue)
    }

    private static func freeSegment(_ bytes: Int64) -> StorageSegment {
        StorageSegment(title: "Свободно", bytes: bytes, color: Color(nsColor: .quaternaryLabelColor))
    }

    private static func unaccountedSegment(_ bytes: Int64) -> StorageSegment {
        StorageSegment(
            title: "Снимки, скрытое и без доступа", bytes: bytes, color: .gray,
            detail: "Занятое место, которого нет среди прочитанных файлов: снимки APFS, файлы без доступа и т. п.")
    }

    private static func apfs(mountPath: String, scanned: Int64) -> StorageBreakdown? {
        guard let device = deviceName(mountPath: mountPath), let containers = apfsContainers() else { return nil }
        guard
            let container = containers.first(where: {
                ($0["ContainerReference"] as? String).map { device.hasPrefix($0 + "s") } ?? false
            }),
            let capacity = (container["CapacityCeiling"] as? NSNumber)?.int64Value,
            let free = (container["CapacityFree"] as? NSNumber)?.int64Value,
            let volumes = container["Volumes"] as? [[String: Any]]
        else { return nil }

        var swap: Int64 = 0
        var service: Int64 = 0
        var serviceNames: [String] = []
        var otherVolumes: Int64 = 0
        var otherNames: [String] = []

        for volume in volumes {
            let identifier = volume["DeviceIdentifier"] as? String ?? ""
            let roles = volume["Roles"] as? [String] ?? []
            let used = (volume["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
            let name = volume["Name"] as? String ?? identifier

            let isScannedVolume =
                device == identifier || device.hasPrefix(identifier + "s")
                || (mountPath == "/" && (roles.contains("System") || roles.contains("Data")))
            if isScannedVolume { continue }

            if roles.contains("VM") {
                swap += used
            } else if roles.isEmpty {
                otherVolumes += used
                otherNames.append(name)
            } else {
                service += used
                serviceNames.append(name)
            }
        }

        let used = capacity - free
        let unaccounted = max(0, used - scanned - swap - service - otherVolumes)

        var segments = [filesSegment(min(scanned, used))]
        if swap > 0 {
            segments.append(
                StorageSegment(
                    title: "Swap", bytes: swap, color: .orange,
                    detail: swapUsed().map { "Сейчас используется \(formatSize($0))" }))
        }
        if service > 0 {
            segments.append(
                StorageSegment(
                    title: "Служебные тома", bytes: service, color: .purple,
                    detail: serviceNames.joined(separator: ", ")))
        }
        if otherVolumes > 0 {
            segments.append(
                StorageSegment(
                    title: "Другие тома", bytes: otherVolumes, color: .teal,
                    detail: otherNames.joined(separator: ", ")))
        }
        if unaccounted > 0 { segments.append(unaccountedSegment(unaccounted)) }
        segments.append(freeSegment(free))
        return StorageBreakdown(capacity: capacity, segments: segments)
    }

    private static func plain(mountPath: String, scanned: Int64) -> StorageBreakdown? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let values = try? URL(fileURLWithPath: mountPath).resourceValues(forKeys: keys),
            let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity
        else { return nil }

        let capacity = Int64(total)
        let free = Int64(available)
        let used = capacity - free
        var segments = [filesSegment(min(scanned, used))]
        if used > scanned { segments.append(unaccountedSegment(used - scanned)) }
        segments.append(freeSegment(free))
        return StorageBreakdown(capacity: capacity, segments: segments)
    }

    /// e.g. "disk3s3s1" for "/".
    private static func deviceName(mountPath: String) -> String? {
        var info = statfs()
        guard statfs(mountPath, &info) == 0 else { return nil }
        let name = withUnsafeBytes(of: &info.f_mntfromname) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return name.hasPrefix("/dev/") ? String(name.dropFirst(5)) : nil
    }

    private static func apfsContainers() -> [[String: Any]]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["apfs", "list", "-plist"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["Containers"] as? [[String: Any]]
    }

    private static func swapUsed() -> Int64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return Int64(usage.xsu_used)
    }
}
