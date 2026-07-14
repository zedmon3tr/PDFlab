import Foundation

/// 逐页查看的翻页/锚点纯数学(单一事实源,session 与 UI 共用)。
enum ViewerPageNavigation {
    static func clampedIndex(_ index: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(max(index, 0), pageCount - 1)
    }

    static func steppedIndex(from index: Int, by delta: Int, pageCount: Int) -> Int {
        clampedIndex(index + delta, pageCount: pageCount)
    }

    /// 目标侧页码 = 源侧页码 + 锚点偏移,越界 clamp(纯函数,不累加,来回翻不漂移)。
    static func linkedIndex(sourceIndex: Int, offset: Int, targetPageCount: Int) -> Int {
        clampedIndex(sourceIndex + offset, pageCount: targetPageCount)
    }

    /// 1 计显示页码文本 → 0 计索引;越界/非数字返回 nil(调用方负责错误提示)。
    static func pageIndex(fromDisplayText text: String, pageCount: Int) -> Int? {
        guard pageCount > 0,
              let number = Int(text.trimmingCharacters(in: .whitespaces)),
              (1...pageCount).contains(number) else { return nil }
        return number - 1
    }

    /// 方向键 → 翻页增量:←/↑ 上一页,→/↓ 下一页;其他键 nil。
    static func pageDelta(forKeyCode keyCode: UInt16) -> Int? {
        switch keyCode {
        case 123, 126: return -1
        case 124, 125: return 1
        default: return nil
        }
    }
}
