import Foundation

/// Key widths in standard keyboard units, with the origin at the upper left.
enum Action75 {
    static let canvas = CGSize(width: 1920, height: 720)
    struct Key {
        let code: UInt16
        let width: CGFloat
        init(_ code: UInt16, _ width: CGFloat = 1) {
            self.code = code
            self.width = width
        }
    }

    // macOS reports Print Screen and Scroll Lock as F13 and F14.
    static let rows: [[Key]] = [
        [53,122,120,99,118,96,97,98,100,101,109,103,111,105,107,117].map { Key($0) },
        [50,18,19,20,21,23,22,26,28,25,29,27,24].map { Key($0) } + [Key(51,2), Key(115)],
        [Key(48,1.5)] + [12,13,14,15,17,16,32,34,31,35,33,30].map { Key($0) } + [Key(42,1.5),Key(116)],
        [Key(57,1.75)] + [0,1,2,3,5,4,38,40,37,41,39].map { Key($0) } + [Key(36,2.25),Key(121)],
        [Key(56,2.25)] + [6,7,8,9,11,45,46,43,47,44].map { Key($0) } + [Key(60,1.75),Key(126),Key(119)],
        [Key(59,1.25),Key(55,1.25),Key(58,1.25),Key(49,6.25),Key(61),Key(54),Key(62),Key(123),Key(125),Key(124)]
    ]

    static let legends: [UInt16: String] = {
        let labels = [
            ["esc"] + (1...12).map { "F" + String($0) } + ["PrtSc", "ScrLk", "Del"],
            ["`","1","2","3","4","5","6","7","8","9","0","-","=","delete","home"],
            ["tab","Q","W","E","R","T","Y","U","I","O","P","[","]","\\","pg up"],
            ["caps","A","S","D","F","G","H","J","K","L",";","'","return","pg dn"],
            ["shift","Z","X","C","V","B","N","M",",",".","/","shift","↑","end"],
            ["ctrl","⌘","⌥","","⌥","⌘","ctrl","←","↓","→"]
        ]
        var result: [UInt16: String] = [:]
        for (keys, names) in zip(rows, labels) {
            for (key, name) in zip(keys, names) {
                result[key.code] = name
            }
        }
        return result
    }()

    static let rects: [UInt16: CGRect] = {
        var result: [UInt16: CGRect] = [:]
        let pitch = canvas.height / CGFloat(rows.count)
        for (rowIndex, row) in rows.enumerated() {
            var x: CGFloat = 0
            for key in row {
                let width = key.width * pitch
                result[key.code] = CGRect(x: x, y: CGFloat(rowIndex) * pitch, width: width, height: pitch)
                x += width
            }
        }
        return result
    }()
}
