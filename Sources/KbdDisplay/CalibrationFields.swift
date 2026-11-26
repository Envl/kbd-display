#if DEBUG
import AppKit

@MainActor
final class CalibrationFields: NSObject, NSTextFieldDelegate {
    private let left: NSTextField
    private let right: NSTextField
    private let top: NSTextField
    private let bottom: NSTextField
    let view: NSGridView
    var onChange: ((BoardClip?) -> Void)?

    init(_ clip: BoardClip) {
        left = NSTextField(string: String(clip.left))
        right = NSTextField(string: String(clip.right))
        top = NSTextField(string: String(clip.top))
        bottom = NSTextField(string: String(clip.bottom))
        let rows = [("Left", left), ("Right", right), ("Top", top), ("Bottom", bottom)]
        view = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        super.init()
        for (name, field) in rows {
            field.delegate = self
            field.setAccessibilityLabel(name)
        }
        left.widthAnchor.constraint(equalToConstant: 72).isActive = true
        view.frame.size = view.fittingSize
    }

    var clip: BoardClip? {
        func pixels(_ field: NSTextField) -> Int? {
            Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let left = pixels(left), let right = pixels(right),
              let top = pixels(top), let bottom = pixels(bottom) else { return nil }
        return BoardClip(left: left, right: right, top: top, bottom: bottom)
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(clip)
    }
}
#endif
