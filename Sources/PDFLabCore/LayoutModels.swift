import CoreGraphics

public enum LayoutRegionSource: Equatable, Sendable {
    case heuristic
    case system
}

public enum LayoutRegionKind: Equatable, Sendable {
    case body
    case title
    case list
    case table
    case header
    case footer
}

public enum LayoutBlockKind: Equatable, Sendable {
    case text
    case paragraph
    case title
    case listItem
    case tableRow
}

public struct LayoutTableCell: Equatable, Sendable {
    public var columnIndex: Int
    public var lines: [TextLine]

    public init(columnIndex: Int, lines: [TextLine]) {
        self.columnIndex = columnIndex
        self.lines = lines
    }
}

public struct LayoutBlock: Equatable, Sendable {
    public var id: LayoutBlockID
    public var kind: LayoutBlockKind
    public var bbox: CGRect
    public var lines: [TextLine]
    public var tableCells: [LayoutTableCell]

    public init(
        id: LayoutBlockID,
        kind: LayoutBlockKind,
        lines: [TextLine],
        bbox: CGRect? = nil,
        tableCells: [LayoutTableCell] = []
    ) {
        self.id = id
        self.kind = kind
        self.lines = lines
        self.tableCells = tableCells
        self.bbox = bbox ?? Self.bounds(of: lines)
    }

    public static func bounds(of lines: [TextLine]) -> CGRect {
        lines.reduce(CGRect.null) { $0.union($1.bbox) }.standardized
    }
}

public struct LayoutRegion: Equatable, Sendable {
    public var id: String
    public var kind: LayoutRegionKind
    public var source: LayoutRegionSource
    public var bbox: CGRect
    public var blocks: [LayoutBlock]

    public init(id: String, kind: LayoutRegionKind, source: LayoutRegionSource, blocks: [LayoutBlock], bbox: CGRect? = nil) {
        self.id = id
        self.kind = kind
        self.source = source
        self.blocks = blocks
        self.bbox = bbox ?? blocks.reduce(CGRect.null) { $0.union($1.bbox) }.standardized
    }

    public var flattenedLines: [TextLine] { blocks.flatMap(\.lines) }
}

public struct PageLayout: Equatable, Sendable {
    public var pageIndex: Int
    /// Clockwise right-angle correction applied before recognition.
    public var rotationDegrees: Int
    public var regions: [LayoutRegion]
    private var orderedLineProjection: [TextLine]?

    public init(pageIndex: Int, rotationDegrees: Int = 0, regions: [LayoutRegion], orderedLines: [TextLine]? = nil) {
        self.pageIndex = pageIndex
        self.rotationDegrees = rotationDegrees
        self.regions = regions
        self.orderedLineProjection = orderedLines
    }

    public var blocks: [LayoutBlock] { regions.flatMap(\.blocks) }
    public var flattenedLines: [TextLine] { orderedLineProjection ?? regions.flatMap(\.flattenedLines) }
}
