import Foundation

enum TouchPhase { case began, moved, ended }

/// Snapshot of the raw-panel → upright-image transform for the displayed frame.
struct FrameCoordinates {
    let width: Int
    let height: Int
    let rotation: Int
    var offsetX: Int = 0
    var offsetY: Int = 0

    func panelPoint(x: Int, y: Int) -> (Int, Int) {
        let point: (Int, Int)
        switch rotation {
        case 1: point = (width - 1 - y, x)
        case 2: point = (width - 1 - x, height - 1 - y)
        case 3: point = (y, height - 1 - x)
        default: point = (x, y)
        }
        return (offsetX + max(0, min(width - 1, point.0)), offsetY + max(0, min(height - 1, point.1)))
    }
}
