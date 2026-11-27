import Foundation

// MARK: - Model

/// One action of a macro, as the firmware replays it.
enum MacroStep: Equatable {
    /// Printable ASCII typed as on a US keyboard.
    case text(String)
    /// Press and release a key (HID usage).
    case tap(Int)
    /// Hold a key down until the matching `up`.
    case down(Int)
    case up(Int)
    /// Pause, in milliseconds (1…60 000).
    case wait(Int)
}

struct MacroItem: Identifiable, Equatable {
    let id = UUID()
    var step: MacroStep

    static func == (lhs: MacroItem, rhs: MacroItem) -> Bool { lhs.step == rhs.step }
}

/// The keyboard's macro memory: 16 zero-terminated slots in one fixed-size buffer.
struct MacroBank: Equatable {
    var slots: [[UInt8]]
    /// Bytes after the 16th slot, kept as they are.
    var tail: [UInt8]
    /// The buffer exactly as read, sent back as `expected` when saving.
    var raw: Data
    var capacity: Int { raw.count }
}

enum MacroError: Error, Equatable {
    case textNotASCII
    case waitOutOfRange
    case keyAlreadyHeld(Int)
    case keyNotHeld(Int)
    case keysLeftHeld
    case invalidKey
    case tooLarge(used: Int, available: Int)
    case unknownFormat

    var message: String {
        switch self {
        case .textNotASCII: return tr("Le texte ne peut contenir que des caractères simples : lettres sans accent, chiffres et ponctuation courante.")
        case .waitOutOfRange: return tr("Une pause dure entre 1 et 60 000 millisecondes.")
        case .keyAlreadyHeld(let k): return tr("« %@ » est déjà maintenue : ajoutez un relâchement avant de la maintenir à nouveau.", KeyCatalog.title(for: k))
        case .keyNotHeld(let k): return tr("« %@ » est relâchée sans avoir été maintenue.", KeyCatalog.title(for: k))
        case .keysLeftHeld: return tr("Une touche maintenue n’est jamais relâchée : ajoutez l’étape « Relâcher ».")
        case .invalidKey: return tr("Cette touche ne peut pas être utilisée dans une macro.")
        case .tooLarge(let used, let available): return tr("Les macros ne tiennent pas dans la mémoire du clavier : %d octets pour %d disponibles.", used, available)
        case .unknownFormat: return tr("La mémoire des macros de ce clavier a un format inconnu. L’écriture est désactivée.")
        }
    }
}

// MARK: - Codec

/// Reads and writes the firmware's macro encoding:
/// printable ASCII as is, `01 01 kc` tap, `01 02 kc` down, `01 03 kc` up, `01 04 <digits> 7C` wait.
enum MacroCodec {
    static let slotCount = 16
    static let capacities: Set<Int> = [3156, 2976, 2760]
    static let maxWait = 60_000

    static func parse(_ data: Data) -> MacroBank? {
        let bytes = [UInt8](data)
        guard capacities.contains(bytes.count), bytes.last == 0 else { return nil }
        var slots: [[UInt8]] = []
        var start = 0
        for (i, b) in bytes.enumerated() where b == 0 {
            slots.append(Array(bytes[start..<i]))
            start = i + 1
            if slots.count == slotCount { break }
        }
        guard slots.count == slotCount else { return nil }
        return MacroBank(slots: slots, tail: Array(bytes[start...]), raw: data)
    }

    /// Steps of one slot, or nil when the bytes are not something this editor understands.
    static func decode(_ bytes: [UInt8]) -> [MacroStep]? {
        var steps: [MacroStep] = []
        var text = ""
        func flush() {
            if !text.isEmpty { steps.append(.text(text)); text = "" }
        }
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            i += 1
            if b == 1 {
                flush()
                guard i < bytes.count else { return nil }
                let command = bytes[i]
                i += 1
                switch command {
                case 1, 2, 3:
                    guard i < bytes.count, bytes[i] != 0 else { return nil }
                    let key = Int(bytes[i])
                    i += 1
                    steps.append(command == 1 ? .tap(key) : command == 2 ? .down(key) : .up(key))
                case 4:
                    var digits = 0, value = 0
                    while i < bytes.count, (48...57).contains(bytes[i]) {
                        digits += 1
                        if digits > 5 { return nil }
                        value = value * 10 + Int(bytes[i]) - 48
                        i += 1
                    }
                    guard digits > 0, digits <= 5, value >= 1, value <= maxWait, i < bytes.count, bytes[i] == 0x7C else { return nil }
                    i += 1
                    steps.append(.wait(value))
                default:
                    return nil
                }
            } else if (32...126).contains(b) {
                text.append(Character(UnicodeScalar(b)))
            } else {
                return nil
            }
        }
        flush()
        return steps
    }

    static func encode(_ steps: [MacroStep]) throws -> [UInt8] {
        var out: [UInt8] = []
        var held = Set<Int>()
        for step in steps {
            switch step {
            case .text(let s):
                for scalar in s.unicodeScalars {
                    guard (32...126).contains(scalar.value) else { throw MacroError.textNotASCII }
                    out.append(UInt8(scalar.value))
                }
            case .tap(let k):
                guard (1...255).contains(k) else { throw MacroError.invalidKey }
                out += [1, 1, UInt8(k)]
            case .down(let k):
                guard (1...255).contains(k) else { throw MacroError.invalidKey }
                guard held.insert(k).inserted else { throw MacroError.keyAlreadyHeld(k) }
                out += [1, 2, UInt8(k)]
            case .up(let k):
                guard (1...255).contains(k) else { throw MacroError.invalidKey }
                guard held.remove(k) != nil else { throw MacroError.keyNotHeld(k) }
                out += [1, 3, UInt8(k)]
            case .wait(let ms):
                guard (1...maxWait).contains(ms) else { throw MacroError.waitOutOfRange }
                out += [1, 4] + Array(String(ms).utf8) + [0x7C]
            }
        }
        guard held.isEmpty else { throw MacroError.keysLeftHeld }
        return out
    }

    private static func trimmedTail(_ bank: MacroBank) -> [UInt8] {
        var tail = bank.tail
        while tail.last == 0 { tail.removeLast() }
        return tail
    }

    /// Bytes one slot may use, given what the other slots already take.
    static func budget(_ bank: MacroBank, slot: Int) -> Int {
        let others = bank.slots.enumerated().reduce(0) { $0 + ($1.offset == slot ? 0 : $1.element.count) }
        return bank.capacity - 1 - slotCount - trimmedTail(bank).count - others
    }

    /// The full buffer with one slot replaced, ready to be written.
    static func rebuild(_ bank: MacroBank, slot: Int, bytes: [UInt8]) throws -> Data {
        var slots = bank.slots
        slots[slot] = bytes
        let tail = trimmedTail(bank)
        let used = slots.reduce(0) { $0 + $1.count + 1 } + tail.count
        guard used <= bank.capacity - 1 else { throw MacroError.tooLarge(used: used, available: bank.capacity - 1) }
        var out = [UInt8](repeating: 0, count: bank.capacity)
        var offset = 0
        for s in slots {
            out.replaceSubrange(offset..<(offset + s.count), with: s)
            offset += s.count + 1
        }
        out.replaceSubrange(offset..<(offset + tail.count), with: tail)
        return Data(out)
    }

    // MARK: Descriptions

    static func keySymbol(_ usage: Int) -> String {
        switch usage {
        case 224, 228: return "⌃"
        case 225, 229: return "⇧"
        case 226, 230: return "⌥"
        case 227, 231: return "⌘"
        case 40: return "↩"
        case 41: return "esc"
        case 42: return "⌫"
        case 43: return "⇥"
        case 44: return tr("espace")
        case 79: return "→"
        case 80: return "←"
        case 81: return "↓"
        case 82: return "↑"
        default: return KeyCatalog.title(for: usage)
        }
    }

    /// Short reading of a macro, shortcuts folded: "⌘C · ⌘V · « Bonjour »".
    static func summary(_ steps: [MacroStep], limit: Int = 5) -> String {
        var parts: [String] = []
        var held: [Int] = []
        for step in steps {
            switch step {
            case .text(let s): parts.append("« \(s) »")
            case .down(let k): held.append(k)
            case .up(let k): held.removeAll { $0 == k }
            case .tap(let k): parts.append(held.map(keySymbol).joined() + keySymbol(k))
            case .wait(let ms): parts.append(ms >= 1000 ? String(format: "%.1f s", Double(ms) / 1000) : "\(ms) ms")
            }
        }
        if parts.isEmpty { return steps.isEmpty ? tr("Vide") : tr("Touches maintenues") }
        let shown = parts.prefix(limit).joined(separator: " · ")
        return parts.count > limit ? shown + " …" : shown
    }

    // MARK: Recording

    /// macOS virtual key code → HID usage (same table as the firmware tools).
    static func usage(forMacKeyCode code: UInt16) -> Int? {
        let table: [UInt16: Int] = [
            0: 4, 1: 22, 2: 7, 3: 9, 4: 11, 5: 10, 6: 29, 7: 27, 8: 6, 9: 25, 10: 100, 11: 5, 12: 20, 13: 26, 14: 8, 15: 21,
            16: 28, 17: 23, 18: 30, 19: 31, 20: 32, 21: 33, 22: 35, 23: 34, 24: 46, 25: 38, 26: 36, 27: 45, 28: 37, 29: 39, 30: 48, 31: 18,
            32: 24, 33: 47, 34: 12, 35: 19, 36: 40, 37: 15, 38: 13, 39: 52, 40: 14, 41: 51, 42: 49, 43: 54, 44: 56, 45: 17, 46: 16, 47: 55,
            48: 43, 49: 44, 50: 53, 51: 42, 53: 41, 54: 231, 55: 227, 56: 225, 57: 57, 58: 226, 59: 224, 60: 229, 61: 230, 62: 228,
            64: 108, 65: 99, 67: 85, 69: 87, 71: 83, 75: 84, 76: 88, 78: 86, 79: 109, 80: 110, 81: 103, 82: 98, 83: 89, 84: 90, 85: 91,
            86: 92, 87: 93, 88: 94, 89: 95, 90: 111, 91: 96, 92: 97,
            96: 62, 97: 63, 98: 64, 99: 60, 100: 65, 101: 66, 103: 68, 105: 104, 106: 107, 107: 105, 109: 67, 111: 69, 113: 106,
            114: 73, 115: 74, 116: 75, 117: 76, 118: 61, 119: 77, 120: 59, 121: 78, 122: 58, 123: 80, 124: 79, 125: 81, 126: 82,
        ]
        return table[code]
    }

    struct RecordedEvent {
        let usage: Int
        let down: Bool
        let time: TimeInterval
    }

    /// Turns raw key events into steps: quick press-release pairs become taps, held keys keep their
    /// down/up, and pauses are kept only when asked for. Keys still held at the end are released.
    static func steps(from events: [RecordedEvent], keepDelays: Bool) -> [MacroStep] {
        var steps: [MacroStep] = []
        var held: [Int] = []
        var lastTime: TimeInterval?
        var i = 0
        while i < events.count {
            let e = events[i]
            if keepDelays, let last = lastTime {
                var ms = Int(((e.time - last) * 1000).rounded())
                if ms >= 20 {
                    while ms > 0 {
                        let chunk = min(ms, maxWait)
                        steps.append(.wait(chunk))
                        ms -= chunk
                    }
                }
            }
            lastTime = e.time
            if e.down {
                if held.contains(e.usage) { i += 1; continue }
                if i + 1 < events.count, !events[i + 1].down, events[i + 1].usage == e.usage,
                   !keepDelays || events[i + 1].time - e.time < 0.25 {
                    steps.append(.tap(e.usage))
                    lastTime = events[i + 1].time
                    i += 2
                    continue
                }
                held.append(e.usage)
                steps.append(.down(e.usage))
            } else if held.contains(e.usage) {
                held.removeAll { $0 == e.usage }
                steps.append(.up(e.usage))
            }
            i += 1
        }
        for k in held.reversed() { steps.append(.up(k)) }
        return steps
    }
}
