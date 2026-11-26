import AppKit

struct DictationShortcut: Equatable {
    static let rightOption: UInt16 = 61
    static let standard = DictationShortcut(keys: [rightOption])!
    let keys: [UInt16]

    init?(keys: [UInt16]) {
        guard !keys.isEmpty, keys.allSatisfy({ $0 < 128 }), Set(keys).count == keys.count else { return nil }
        self.keys = keys
    }

    var anchor: UInt16 { keys.last { Action75.rects[$0] != nil } ?? Self.rightOption }
    var title: String { keys.map(Self.name).joined(separator: " + ") }

    static func name(_ code: UInt16) -> String {
        switch code {
        case 49: return "Space"
        case 54: return "Right Command"
        case 55: return "Left Command"
        case 56: return "Left Shift"
        case 57: return "Caps Lock"
        case 58: return "Left Option"
        case 59: return "Left Control"
        case 60: return "Right Shift"
        case 61: return "Right Option"
        case 62: return "Right Control"
        case 63: return "Fn"
        default: return Action75.legends[code]?.capitalized ?? "Key \(code)"
        }
    }
}

final class ShortcutRecorder: ObservableObject {
    @Published private(set) var keys: [UInt16]?
    private var completion: ((DictationShortcut) -> Void)?

    func begin(save: @escaping (DictationShortcut) -> Void) {
        keys = []
        completion = save
    }

    func cancel() {
        completion = nil
        keys = nil
    }

    // The first release commits the overlapping keys, including modifier-only chords.
    func receive(_ code: UInt16, down: Bool) {
        guard var keys, code < 128 else { return }
        if down {
            guard !keys.contains(code) else { return }
            keys.append(code)
            self.keys = keys
        } else if keys.contains(code), let shortcut = DictationShortcut(keys: keys) {
            let save = completion
            cancel()
            save?(shortcut)
        }
    }
}
