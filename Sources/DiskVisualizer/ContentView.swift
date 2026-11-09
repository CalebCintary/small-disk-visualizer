import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(model.locations, selection: $model.selectedURL) { location in
                LocationRow(location: location)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                Button("Выбрать папку…", systemImage: "folder.badge.plus") {
                    model.chooseFolder()
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
        } detail: {
            if let session = model.selectedSession {
                SessionView(session: session)
            } else {
                ContentUnavailableView("Выберите диск или папку", systemImage: "internaldrive")
            }
        }
    }
}

/// Finder's own icon, which follows the system's appearance and icon style.
private struct FileIcon: View {
    let path: String
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .id(colorScheme)
    }
}

private struct LocationRow: View {
    let location: Location

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(location.name)
                if let fraction = location.usedFraction {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                }
                if let detail = location.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            FileIcon(path: location.url.path, size: 20)
        }
        .padding(.vertical, 2)
    }
}

private struct SessionView: View {
    let session: ScanSession

    var body: some View {
        Group {
            if session.isScanning {
                ScanProgressView(session: session)
            } else if let current = session.current {
                FolderView(session: session, folder: current)
            } else {
                ContentUnavailableView {
                    Label {
                        Text(session.location.name)
                    } icon: {
                        FileIcon(path: session.location.url.path, size: 48)
                    }
                } description: {
                    Text(session.scanError.map { "Ошибка сканирования: \($0)" } ?? "Размер ещё не рассчитан.")
                } actions: {
                    Button("Рассчитать") { session.start() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
        .navigationTitle(session.current?.name ?? session.location.name)
        .navigationSubtitle(session.current.map { formatSize($0.size) } ?? "")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Наверх", systemImage: "chevron.up") { session.goUp() }
                    .disabled(session.path.count <= 1)
                    .keyboardShortcut(.upArrow, modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Пересчитать", systemImage: "arrow.clockwise") { session.start() }
                    .disabled(session.path.isEmpty || session.isScanning)
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

private struct ScanProgressView: View {
    let session: ScanSession

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Сканирование \(session.location.url.path)")
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Просмотрено объектов: \(session.scannedCount.formatted())")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Отменить") { session.cancel() }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StorageBar: View {
    let storage: StorageBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(storage.segments) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(2, geometry.size.width * share(of: segment)))
                            .help(tooltip(for: segment))
                    }
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(storage.segments) { segment in
                    HStack(spacing: 6) {
                        Circle().fill(segment.color).frame(width: 8, height: 8)
                        Text(segment.title).lineLimit(1)
                        Text(formatSize(segment.bytes))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .help(tooltip(for: segment))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func share(of segment: StorageSegment) -> Double {
        storage.capacity > 0 ? Double(segment.bytes) / Double(storage.capacity) : 0
    }

    private func tooltip(for segment: StorageSegment) -> String {
        segment.detail.map { "\(segment.title): \($0)" } ?? segment.title
    }
}

private struct FolderView: View {
    let session: ScanSession
    let folder: FileNode

    @State private var sortOrder = [KeyPathComparator(\FileNode.size, order: .reverse)]

    var body: some View {
        @Bindable var session = session

        VStack(spacing: 0) {
            if session.isAtRoot, let storage = session.storage {
                StorageBar(storage: storage)
                Divider()
            }

            VSplitView {
                if folder.children.contains(where: { $0.size > 0 }) {
                    TreemapView(node: folder, selection: $session.selection) { session.open($0) }
                        .padding(6)
                        .frame(minHeight: 220, idealHeight: 380)
                } else {
                    ContentUnavailableView("Папка пуста", systemImage: "folder")
                        .frame(minHeight: 220, idealHeight: 380)
                }

                Table(folder.children.sorted(using: sortOrder), selection: $session.selection, sortOrder: $sortOrder) {
                    TableColumn("Имя", value: \.name) { node in
                        Label {
                            Text(node.name)
                        } icon: {
                            FileIcon(path: node.path)
                        }
                    }
                    TableColumn("Размер", value: \.size) { node in
                        Text(formatSize(node.size)).monospacedDigit()
                    }
                    .width(min: 70, ideal: 90, max: 120)
                    TableColumn("Доля", value: \.size) { node in
                        ProgressView(value: share(of: node))
                    }
                    .width(min: 70, ideal: 120, max: 200)
                }
                .contextMenu(forSelectionType: FileNode.ID.self) { ids in
                    if let node = node(in: ids) {
                        Button("Показать в Finder") { session.revealInFinder(node) }
                    }
                } primaryAction: { ids in
                    if let node = node(in: ids) { session.open(node) }
                }
                .frame(minHeight: 140)
            }

            if session.unreadableCount > 0 {
                Divider()
                Label(
                    "Нет доступа к объектам: \(session.unreadableCount.formatted()). Размер может быть занижен — проверьте «Полный доступ к диску».",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func share(of node: FileNode) -> Double {
        folder.size > 0 ? Double(node.size) / Double(folder.size) : 0
    }

    private func node(in ids: Set<FileNode.ID>) -> FileNode? {
        guard let id = ids.first else { return nil }
        return folder.children.first { $0.id == id }
    }
}
