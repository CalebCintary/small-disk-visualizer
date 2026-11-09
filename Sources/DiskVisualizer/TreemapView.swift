import SwiftUI

struct TreemapTile {
    let node: FileNode
    let rect: CGRect
}

/// Squarified treemap (Bruls, Huizing, van Wijk). `nodes` must be sorted largest first.
func layoutTreemap(_ nodes: [FileNode], in bounds: CGRect) -> [TreemapTile] {
    let visible = nodes.filter { $0.size > 0 }
    let totalSize = visible.reduce(0.0) { $0 + Double($1.size) }
    guard totalSize > 0, bounds.width > 0, bounds.height > 0 else { return [] }

    let scale = bounds.width * bounds.height / totalSize
    let areas = visible.map { Double($0.size) * scale }

    func worstRatio(sum: Double, smallest: Double, largest: Double, side: Double) -> Double {
        max(side * side * largest / (sum * sum), sum * sum / (side * side * smallest))
    }

    var tiles: [TreemapTile] = []
    tiles.reserveCapacity(visible.count)
    var rect = bounds
    var start = 0

    while start < areas.count {
        let side = Double(min(rect.width, rect.height))
        var end = start + 1
        var sum = areas[start]
        var worst = worstRatio(sum: sum, smallest: areas[start], largest: areas[start], side: side)

        // Areas are descending, so the newest item is always the row's smallest.
        while end < areas.count {
            let nextSum = sum + areas[end]
            let nextWorst = worstRatio(sum: nextSum, smallest: areas[end], largest: areas[start], side: side)
            if nextWorst > worst { break }
            sum = nextSum
            worst = nextWorst
            end += 1
        }

        let thickness = sum / side
        var offset = 0.0
        let isColumn = rect.width >= rect.height

        for index in start..<end {
            let length = areas[index] / thickness
            let tileRect =
                isColumn
                ? CGRect(x: rect.minX, y: rect.minY + offset, width: thickness, height: length)
                : CGRect(x: rect.minX + offset, y: rect.minY, width: length, height: thickness)
            tiles.append(TreemapTile(node: visible[index], rect: tileRect))
            offset += length
        }

        if isColumn {
            rect = CGRect(x: rect.minX + thickness, y: rect.minY, width: max(0, rect.width - thickness), height: rect.height)
        } else {
            rect = CGRect(x: rect.minX, y: rect.minY + thickness, width: rect.width, height: max(0, rect.height - thickness))
        }
        start = end
    }
    return tiles
}

struct TreemapView: View {
    /// Tiles past this are too thin to see and only slow down drawing.
    private static let maxTiles = 600
    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .red, .mint, .cyan]

    let node: FileNode
    @Binding var selection: FileNode.ID?
    let onOpen: (FileNode) -> Void

    @State private var hovered: FileNode?

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let tiles = layoutTreemap(Array(node.children.prefix(Self.maxTiles)), in: bounds)

            Canvas { context, _ in
                for tile in tiles {
                    draw(tile, in: &context)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): hovered = tile(at: point, in: tiles)?.node
                case .ended: hovered = nil
                }
            }
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in
                        if let hit = tile(at: value.location, in: tiles) { onOpen(hit.node) }
                    }
                    .exclusively(
                        before: SpatialTapGesture()
                            .onEnded { value in
                                selection = tile(at: value.location, in: tiles)?.node.id
                            })
            )
        }
        .overlay(alignment: .bottomLeading) {
            if let hovered {
                Text("\(hovered.name) — \(formatSize(hovered.size))")
                    .font(.callout)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    private func tile(at point: CGPoint, in tiles: [TreemapTile]) -> TreemapTile? {
        tiles.first { $0.rect.contains(point) }
    }

    private func color(for node: FileNode) -> Color {
        guard node.isDirectory else { return .gray }
        let hash = node.name.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value }
        return Self.palette[Int(hash % UInt32(Self.palette.count))]
    }

    private func draw(_ tile: TreemapTile, in context: inout GraphicsContext) {
        let rect = tile.rect.insetBy(dx: 0.5, dy: 0.5)
        guard rect.width > 0, rect.height > 0 else { return }

        let isSelected = tile.node.id == selection
        let shape = Path(roundedRect: rect, cornerRadius: min(3, min(rect.width, rect.height) / 2))
        context.fill(shape, with: .color(color(for: tile.node).opacity(hovered == tile.node ? 1 : 0.8)))
        if isSelected {
            context.stroke(shape, with: .color(.primary), lineWidth: 2)
        }

        guard rect.width > 44, rect.height > 20 else { return }
        var clipped = context
        clipped.clip(to: Path(rect.insetBy(dx: 4, dy: 3)))

        var label = Text(tile.node.name).font(.caption.weight(.semibold))
        if rect.height > 36 {
            label = label + Text("\n\(formatSize(tile.node.size))").font(.caption2)
        }
        clipped.draw(
            label.foregroundColor(.white),
            at: CGPoint(x: rect.minX + 5, y: rect.minY + 3),
            anchor: .topLeading)
    }
}
