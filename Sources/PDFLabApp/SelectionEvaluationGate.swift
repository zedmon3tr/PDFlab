/// 鼠标划选评估门:PDFView 通常在拖拽中持续发选区通知,NSTextView 可能到 mouseUp
/// 后才落定选区。只要发生过宿主内拖拽,mouseUp 后就允许评估一次当前选区。
struct SelectionEvaluationGate {
    enum Action {
        case none
        case evaluate
        case close
    }

    private var pendingEvaluation = false

    mutating func selectionChanged(isDragging: Bool) {
        if isDragging {
            pendingEvaluation = true
        }
    }

    mutating func textSelectionChanged(isDragging: Bool, hasSelection: Bool) -> Action {
        if isDragging {
            pendingEvaluation = true
            return .none
        }
        return hasSelection ? .evaluate : .close
    }

    mutating func mouseDraggedInHost() {
        pendingEvaluation = true
    }

    mutating func consumeMouseUp(inHostWindow: Bool) -> Bool {
        guard pendingEvaluation else { return false }
        pendingEvaluation = false
        return inHostWindow
    }
}
