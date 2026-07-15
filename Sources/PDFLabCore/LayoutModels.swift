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

public struct LayoutBlock: Equatable, Sendable {
    public var id: LayoutBlockID
    public var kind: LayoutBlockKind
    public var bbox: CGRect
    public var lines: [TextLine]

    public init(id: LayoutBlockID, kind: LayoutBlockKind, lines: [TextLine], bbox: CGRect? = nil) {
        self.id = id
        self.kind = kind
        self.lines = lines
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
    public var regions: [LayoutRegion]

    public init(pageIndex: Int, regions: [LayoutRegion]) {
        self.pageIndex = pageIndex
        self.regions = regions
    }

    public var blocks: [LayoutBlock] { regions.flatMap(\.blocks) }
    public var flattenedLines: [TextLine] { regions.flatMap(\.flattenedLines) }
}
