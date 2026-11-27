import Foundation

// MARK: - Physical layout (Flow 2 · 84 keys)

/// One physical key: where it sits on the board (in key units) and in the firmware matrix.
struct KeySpec: Identifiable {
    let id: Int
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    let row: Int
    let col: Int
    /// Legend printed on the keycap.
    let label: String
    /// Spoken name of the physical key.
    let name: String

    /// Index in a layer array (`keys[row * cols + col]`).
    var position: Int { row * FlowLayout.cols84 + col }
}

enum FlowLayout {
    static let rows84 = 6
    static let cols84 = 15

    /// The 84 keys in reading order. Matrix positions follow the firmware (Print Screen sits at r3c12).
    static let keys84: [KeySpec] = {
        typealias K = (label: String, name: String, w: Double, row: Int, col: Int)
        func letters(_ s: String, row: Int, firstCol: Int) -> [K] {
            s.enumerated().map { (String($0.element), tr("Touche %@", String($0.element)), 1, row, firstCol + $0.offset) }
        }
        let fRow: [K] = (1...12).map { ("F\($0)", "F\($0)", 1, 0, $0) }
        let digits: [K] = "1234567890".enumerated().map { (String($0.element), tr("Touche %@", String($0.element)), 1, 1, 1 + $0.offset) }
        let rows: [[K]] = [
            [("Esc", tr("Échap"), 1, 0, 0)] + fRow + [("Prt", tr("Impr. écran"), 1, 3, 12), ("Ins", tr("Inser"), 1, 0, 13), ("Del", tr("Suppr"), 1, 0, 14)],
            [("`", tr("Accent grave"), 1, 1, 0)] + digits + [("-", tr("Tiret"), 1, 1, 11), ("=", tr("Égal"), 1, 1, 12),
                                                          ("⌫", tr("Retour arrière"), 2, 1, 13), ("Home", tr("Début"), 1, 1, 14)],
            [("⇥", tr("Tabulation"), 1.5, 2, 0)] + letters("QWERTYUIOP", row: 2, firstCol: 1)
                + [("[", tr("Crochet ouvrant"), 1, 2, 11), ("]", tr("Crochet fermant"), 1, 2, 12), ("\\", tr("Barre oblique inverse"), 1.5, 2, 13), ("End", tr("Fin"), 1, 2, 14)],
            [("⇪", tr("Verr. Maj"), 1.75, 3, 0)] + letters("ASDFGHJKL", row: 3, firstCol: 1)
                + [(";", tr("Point-virgule"), 1, 3, 10), ("'", tr("Apostrophe"), 1, 3, 11), ("↩", tr("Entrée"), 2.25, 3, 13), ("PgUp", tr("Page précédente"), 1, 3, 14)],
            [("⇧", tr("Maj gauche"), 2.25, 4, 0)] + letters("ZXCVBNM", row: 4, firstCol: 2)
                + [(",", tr("Virgule"), 1, 4, 9), (".", tr("Point"), 1, 4, 10), ("/", tr("Barre oblique"), 1, 4, 11),
                   ("⇧", tr("Maj droite"), 1.75, 4, 12), ("↑", tr("Flèche haut"), 1, 4, 13), ("PgDn", tr("Page suivante"), 1, 4, 14)],
            [("⌃", tr("Contrôle"), 1.25, 5, 0), ("⌥", tr("Option gauche"), 1.25, 5, 1), ("⌘", tr("Commande gauche"), 1.25, 5, 2), ("", tr("Barre d’espace"), 6.25, 5, 6),
             ("⌘", tr("Commande droite"), 1, 5, 9), ("Fn", tr("Fn"), 1, 5, 10), ("⌥", tr("Option droite"), 1, 5, 11),
             ("←", tr("Flèche gauche"), 1, 5, 12), ("↓", tr("Flèche bas"), 1, 5, 13), ("→", tr("Flèche droite"), 1, 5, 14)],
        ]
        var out: [KeySpec] = []
        for (y, row) in rows.enumerated() {
            var x = 0.0
            for k in row {
                out.append(KeySpec(id: out.count, x: x, y: Double(y), w: k.w, h: 1, row: k.row, col: k.col, label: k.label, name: k.name))
                x += k.w
            }
        }
        return out
    }()

    /// Factory Mac layer of the 84, used when no keyboard can be asked (demo, offline).
    static let factoryMac84: [Int] = {
        var keys = [Int](repeating: 0, count: rows84 * cols84)
        let r0 = [41, 0xBE, 0xBD, 0x7E0B, 0xB4, 0x7803, 0x7804, 0xAC, 0xAE, 0xAB, 0xA8, 0xAA, 0xA9, 73, 76]
        let r1 = [53, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 45, 46, 42, 74]
        let r2 = [43, 20, 26, 8, 21, 23, 28, 24, 12, 18, 19, 47, 48, 49, 77]
        let r3 = [57, 4, 22, 7, 9, 10, 11, 13, 14, 15, 51, 52, 70, 40, 75]
        let r4 = [225, 0, 29, 27, 6, 25, 5, 17, 16, 54, 55, 56, 229, 82, 78]
        let r5 = [224, 226, 227, 0, 0, 0, 44, 0, 0, 231, 0x5221, 230, 80, 81, 79]
        for (r, row) in [r0, r1, r2, r3, r4, r5].enumerated() {
            for (c, code) in row.enumerated() { keys[r * cols84 + c] = code }
        }
        return keys
    }()
}

// MARK: - Layers

enum FlowLayer: Int, CaseIterable, Identifiable {
    case mac = 0, fnMac, windows, fnWindows, extra1, extra2
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .mac: return tr("Mac")
        case .fnMac: return tr("Fn · Mac")
        case .windows: return tr("Windows")
        case .fnWindows: return tr("Fn · Windows")
        case .extra1: return tr("Supplémentaire 1")
        case .extra2: return tr("Supplémentaire 2")
        }
    }

    var isFn: Bool { self == .fnMac || self == .fnWindows }

    var hint: String {
        switch self {
        case .mac: return tr("Disposition utilisée en mode macOS (Fn + M).")
        case .fnMac: return tr("Actions obtenues en maintenant Fn, en mode macOS.")
        case .windows: return tr("Disposition utilisée en mode Windows (Fn + N).")
        case .fnWindows: return tr("Actions obtenues en maintenant Fn, en mode Windows.")
        case .extra1: return tr("Calque atteint avec Fn + Maj gauche. Il contient des touches de service d’usine.")
        case .extra2: return tr("Calque atteint avec Fn + Retour arrière. Il contient des touches de service d’usine.")
        }
    }
}

// MARK: - Assignable actions

struct FlowAction: Identifiable, Hashable {
    let code: Int
    let title: String
    var id: Int { code }
}

struct FlowActionGroup: Identifiable {
    let title: String
    let symbol: String
    let actions: [FlowAction]
    /// Shown directly in the menu instead of inside a submenu.
    var inline = false
    var id: String { title }
}

/// Key codes the firmware understands, with French names.
enum KeyCatalog {
    static let disabled = 0
    static let inherit = 1
    static let macroBase = 0x7700
    static let holdLayerBase = 0x5220
    static let switchLayerBase = 0x5200

    private static let usageNames: [Int: String] = {
        var n: [Int: String] = [:]
        for (i, ch) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { n[4 + i] = String(ch) }
        for (i, ch) in "1234567890".enumerated() { n[30 + i] = String(ch) }
        n[40] = tr("Entrée"); n[41] = tr("Échap"); n[42] = tr("Retour arrière"); n[43] = tr("Tabulation"); n[44] = tr("Espace")
        n[45] = "-"; n[46] = "="; n[47] = "["; n[48] = "]"; n[49] = "\\"; n[50] = "#"; n[51] = ";"; n[52] = "'"
        n[53] = "`"; n[54] = ","; n[55] = "."; n[56] = "/"; n[57] = tr("Verr. Maj")
        for i in 0..<12 { n[58 + i] = "F\(i + 1)" }
        n[70] = tr("Impr. écran"); n[71] = tr("Arrêt défil."); n[72] = tr("Pause"); n[73] = tr("Inser"); n[74] = tr("Début")
        n[75] = tr("Page précédente"); n[76] = tr("Suppr"); n[77] = tr("Fin"); n[78] = tr("Page suivante")
        n[79] = tr("Flèche droite"); n[80] = tr("Flèche gauche"); n[81] = tr("Flèche bas"); n[82] = tr("Flèche haut")
        n[83] = tr("Verr. Num"); n[84] = tr("Pavé ÷"); n[85] = tr("Pavé ×"); n[86] = tr("Pavé −"); n[87] = tr("Pavé +"); n[88] = tr("Pavé Entrée")
        for (i, ch) in "1234567890".enumerated() { n[89 + i] = tr("Pavé %@", String(ch)) }
        n[99] = tr("Pavé ."); n[101] = tr("Menu contextuel")
        for i in 0..<12 { n[104 + i] = "F\(i + 13)" }
        n[224] = tr("Contrôle gauche"); n[225] = tr("Maj gauche"); n[226] = tr("Option gauche"); n[227] = tr("Commande gauche")
        n[228] = tr("Contrôle droite"); n[229] = tr("Maj droite"); n[230] = tr("Option droite"); n[231] = tr("Commande droite")
        return n
    }()

    private static let special: [Int: String] = [
        0: tr("Désactivée"), 1: tr("Comme le calque principal"),
        0xA9: tr("Volume +"), 0xAA: tr("Volume −"), 0xA8: tr("Couper le son"),
        0xAE: tr("Lecture / Pause"), 0xAB: tr("Piste suivante"), 0xAC: tr("Piste précédente"),
        0xBD: tr("Luminosité de l’écran +"), 0xBE: tr("Luminosité de l’écran −"), 0xB4: tr("Recherche"),
        0x7804: tr("Rétroéclairage +"), 0x7803: tr("Rétroéclairage −"),
        0x7E0E: tr("Effet lumineux suivant"), 0x7E12: tr("Effet lumineux précédent"),
        0x7E11: tr("Activer / désactiver la Touch Bar"),
        0x7E0B: tr("Mission Control"), 0x7E0C: tr("Verrouiller l’écran"),
        0x7E30: tr("Touch Bar : profil 1 zone"), 0x7E31: tr("Touch Bar : profil 2 zones"),
        0x7E32: tr("Touch Bar : profil 3 zones"), 0x7E33: tr("Touch Bar : profil suivant"),
        0x7E01: tr("Bluetooth 1"), 0x7E02: tr("Bluetooth 2"), 0x7E03: tr("Bluetooth 3"), 0x7E04: tr("Récepteur 2,4 GHz"),
        0x7E10: tr("Bascule F1–F12 / multimédia"), 0x7E14: tr("Bascule F1–F12 / multimédia"),
        0x5200: tr("Passer en mode Mac"), 0x5202: tr("Passer en mode Windows"),
        0x7013: tr("Bascule NKRO"), 0x7C00: tr("Mode récupération (bootloader)"), 0x7C03: tr("Réinitialisation du clavier"),
    ]

    static func title(for code: Int) -> String {
        if let s = special[code] { return s }
        if let s = usageNames[code] { return s }
        if (macroBase..<(macroBase + 16)).contains(code) { return tr("Macro %d", code - macroBase + 1) }
        if (holdLayerBase...(holdLayerBase + 5)).contains(code), let layer = FlowLayer(rawValue: code - holdLayerBase) {
            return layer.isFn ? tr("Fn (maintenir %@)", layer.title) : tr("Maintenir le calque %@", layer.title)
        }
        if (switchLayerBase...(switchLayerBase + 5)).contains(code), let layer = FlowLayer(rawValue: code - switchLayerBase) {
            return tr("Passer au calque %@", layer.title)
        }
        if (0x7E00...0x7E3F).contains(code) { return tr("Fonction Lofree %d", code - 0x7E00) }
        return String(format: "Code 0x%04X", code)
    }

    /// Codes that give access to a layer or to recovery: reassigning them needs a second look.
    static func isStructural(_ code: Int) -> Bool {
        (holdLayerBase...(holdLayerBase + 5)).contains(code) || code == 0x7C00 || code == 0x7C03
    }

    private static func actions(_ codes: [Int]) -> [FlowAction] {
        codes.map { FlowAction(code: $0, title: title(for: $0)) }
    }

    /// Plain keys only (what a macro can press).
    static let hidGroups: [FlowActionGroup] = [
        FlowActionGroup(title: tr("Modificateurs"), symbol: "command", actions: actions(Array(224...231))),
        FlowActionGroup(title: tr("Lettres"), symbol: "textformat", actions: actions(Array(4...29))),
        FlowActionGroup(title: tr("Chiffres et symboles"), symbol: "number", actions: actions(Array(30...39) + Array(45...56))),
        FlowActionGroup(title: tr("Édition et navigation"), symbol: "arrow.up.and.down.and.arrow.left.and.right",
                        actions: actions([40, 41, 42, 43, 44, 57, 73, 76, 74, 77, 75, 78, 82, 81, 80, 79, 70, 71, 72, 101])),
        FlowActionGroup(title: tr("Touches de fonction"), symbol: "fn", actions: actions(Array(58...69) + Array(104...115))),
        FlowActionGroup(title: tr("Pavé numérique"), symbol: "circle.grid.3x3", actions: actions(Array(83...99))),
    ]

    static func groups(touchProfiles: Bool, macroCount: Int) -> [FlowActionGroup] {
        var g: [FlowActionGroup] = [
            FlowActionGroup(title: tr("Multimédia"), symbol: "speaker.wave.2", actions: actions([0xA9, 0xAA, 0xA8, 0xAE, 0xAB, 0xAC])),
            FlowActionGroup(title: tr("Écran et système"), symbol: "display", actions: actions([0xBD, 0xBE, 0x7E0B, 0x7E0C, 0xB4])),
            FlowActionGroup(title: tr("Clavier"), symbol: "keyboard", actions: actions([0x7804, 0x7803, 0x7E0E, 0x7E12, 0x7E11])),
            FlowActionGroup(title: tr("Lettres"), symbol: "textformat", actions: actions(Array(4...29))),
            FlowActionGroup(title: tr("Chiffres et symboles"), symbol: "number", actions: actions(Array(30...39) + Array(45...56))),
            FlowActionGroup(title: tr("Édition et navigation"), symbol: "arrow.up.and.down.and.arrow.left.and.right",
                            actions: actions([40, 41, 42, 43, 44, 57, 73, 76, 74, 77, 75, 78, 82, 81, 80, 79, 70, 71, 72, 101])),
            FlowActionGroup(title: tr("Touches de fonction"), symbol: "fn", actions: actions(Array(58...69) + Array(104...115))),
            FlowActionGroup(title: tr("Pavé numérique"), symbol: "circle.grid.3x3", actions: actions(Array(83...99))),
            FlowActionGroup(title: tr("Modificateurs"), symbol: "command", actions: actions(Array(224...231))),
            FlowActionGroup(title: tr("Calques"), symbol: "square.3.layers.3d",
                            actions: actions((0...5).map { holdLayerBase + $0 } + [0x5200, 0x5202])),
        ]
        if touchProfiles {
            g.append(FlowActionGroup(title: tr("Profils Touch Bar"), symbol: "hand.draw", actions: actions([0x7E30, 0x7E31, 0x7E32, 0x7E33])))
        }
        if macroCount > 0 {
            g.append(FlowActionGroup(title: tr("Macros"), symbol: "record.circle", actions: actions((0..<min(macroCount, 16)).map { macroBase + $0 })))
        }
        g.append(FlowActionGroup(title: tr("Autres"), symbol: "ellipsis", actions: actions([inherit, disabled]), inline: true))
        return g
    }
}

// MARK: - Touch Bar

enum TouchGesture: Int, CaseIterable, Identifiable {
    case swipeUp = 0, tap, swipeDown
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .swipeUp: return tr("Glisser vers le haut")
        case .tap: return tr("Toucher")
        case .swipeDown: return tr("Glisser vers le bas")
        }
    }

    var symbol: String {
        switch self {
        case .swipeUp: return "arrow.up"
        case .tap: return "hand.tap"
        case .swipeDown: return "arrow.down"
        }
    }
}

/// Touch Bar action codes. They are not key codes: keys are stored as HID usage + 64.
enum TouchCatalog {
    static let none = 0
    static let scroll = 7
    static let keyOffset = 64
    static let macroBase = 320

    private static let basic: [Int: String] = [
        0: tr("Aucune action"), 1: tr("Volume +"), 2: tr("Volume −"), 3: tr("Couper le son"),
        4: tr("Lecture / Pause"), 5: tr("Piste suivante"), 6: tr("Piste précédente"),
        7: tr("Défilement"), 9: tr("Luminosité de l’écran +"), 10: tr("Luminosité de l’écran −"),
        336: tr("Profil 1 zone"), 337: tr("Profil 2 zones"), 338: tr("Profil 3 zones"), 339: tr("Profil suivant"),
    ]

    static func title(for code: Int) -> String {
        if let s = basic[code] { return s }
        if (macroBase..<(macroBase + 16)).contains(code) { return tr("Macro %d", code - macroBase + 1) }
        if (68...179).contains(code) || (288...295).contains(code) { return KeyCatalog.title(for: code - keyOffset) }
        return tr("Action %d", code)
    }

    static func isValid(_ code: Int) -> Bool {
        (code <= 10 && code >= 0 && code != 8) || (68...179).contains(code) || (288...295).contains(code) || (320...339).contains(code)
    }

    private static func actions(_ codes: [Int]) -> [FlowAction] {
        codes.map { FlowAction(code: $0, title: title(for: $0)) }
    }

    private static func keys(_ usages: [Int]) -> [FlowAction] { actions(usages.map { $0 + keyOffset }) }

    /// Actions offered for a gesture. Scrolling only exists on swipes.
    static func groups(for gesture: TouchGesture, touchProfiles: Bool, macroCount: Int) -> [FlowActionGroup] {
        var g: [FlowActionGroup] = [
            FlowActionGroup(title: tr("Volume"), symbol: "speaker.wave.2", actions: actions([1, 2, 3]), inline: true),
            FlowActionGroup(title: tr("Lecture"), symbol: "playpause", actions: actions([4, 5, 6]), inline: true),
            FlowActionGroup(title: tr("Écran"), symbol: "sun.max", actions: actions(gesture == .tap ? [9, 10] : [9, 10, scroll]), inline: true),
            FlowActionGroup(title: tr("Flèches et navigation"), symbol: "arrow.up.and.down.and.arrow.left.and.right",
                            actions: keys([82, 81, 80, 79, 75, 78, 74, 77])),
            FlowActionGroup(title: tr("Édition"), symbol: "pencil", actions: keys([40, 41, 42, 43, 44, 76, 73, 70])),
            FlowActionGroup(title: tr("Touches de fonction"), symbol: "fn", actions: keys(Array(58...69) + Array(104...115))),
            FlowActionGroup(title: tr("Lettres"), symbol: "textformat", actions: keys(Array(4...29))),
            FlowActionGroup(title: tr("Chiffres et symboles"), symbol: "number", actions: keys(Array(30...39) + Array(45...56))),
            FlowActionGroup(title: tr("Modificateurs"), symbol: "command", actions: keys(Array(224...231))),
        ]
        if macroCount > 0 {
            g.append(FlowActionGroup(title: tr("Macros"), symbol: "record.circle", actions: actions((0..<min(macroCount, 16)).map { macroBase + $0 })))
        }
        if touchProfiles {
            g.append(FlowActionGroup(title: tr("Profils Touch Bar"), symbol: "hand.draw", actions: actions([336, 337, 338, 339])))
        }
        g.append(FlowActionGroup(title: tr("Aucune"), symbol: "nosign", actions: actions([none]), inline: true))
        return g
    }

    /// Ready-made gesture sets for one zone: swipe up, tap, swipe down.
    struct Preset: Identifiable {
        let title: String
        let symbol: String
        let slots: [Int]
        var id: String { title }
    }

    static let presets: [Preset] = [
        Preset(title: tr("Volume"), symbol: "speaker.wave.2", slots: [1, 0, 2]),
        Preset(title: tr("Volume, toucher pour couper le son"), symbol: "speaker.slash", slots: [1, 3, 2]),
        Preset(title: tr("Luminosité de l’écran"), symbol: "sun.max", slots: [9, 0, 10]),
        Preset(title: tr("Défilement"), symbol: "scroll", slots: [7, 0, 7]),
        Preset(title: tr("Lecture"), symbol: "playpause", slots: [5, 4, 6]),
        Preset(title: tr("Flèches haut / bas"), symbol: "arrow.up.arrow.down", slots: [82 + 64, 0, 81 + 64]),
        Preset(title: tr("Flèches gauche / droite"), symbol: "arrow.left.arrow.right", slots: [80 + 64, 0, 79 + 64]),
        Preset(title: tr("Pages précédente / suivante"), symbol: "doc.text", slots: [75 + 64, 0, 78 + 64]),
        Preset(title: tr("Aucune action"), symbol: "nosign", slots: [0, 0, 0]),
    ]

    static func preset(matching slots: [Int]) -> Preset? { presets.first { $0.slots == slots } }

    /// Boundary limits enforced by the firmware (percent of the strip).
    static let b1Range = 15...85
    static let b2Range = 30...85
    static let minimumGap = 15

    static func defaults(for count: Int) -> (b1: Int, b2: Int) {
        switch count {
        case 2: return (50, 75)
        case 3: return (25, 75)
        default: return (33, 67)
        }
    }
}

// MARK: - Lighting and power options

enum LightingCatalog {
    static let effects: [(id: Int, title: String)] = [
        (0, tr("Fixe")), (1, tr("Respiration")), (2, tr("Vague descendante")), (3, tr("Vague montante")),
        (4, tr("Vague aller-retour")), (5, tr("Dégradé fluide")), (6, tr("Cascade")),
    ]
    static let speeds: [(id: Int, title: String)] = [(0, tr("Lente")), (1, tr("Normale")), (2, tr("Rapide")), (3, tr("Très rapide"))]
    static let timeouts: [(seconds: Int, title: String)] = [
        (30, tr("30 secondes")), (60, tr("1 minute")), (120, tr("2 minutes")), (300, tr("5 minutes")),
        (600, tr("10 minutes")), (1800, tr("30 minutes")), (3600, tr("1 heure")), (0, tr("Jamais")),
    ]
    static let lowBattery: [Int] = [0, 5, 10, 15, 20, 25, 30, 40, 50]
}

enum FirmwareCatalog {
    static func phaseTitle(_ phase: String) -> String {
        switch phase {
        case "entering": return tr("Passage en mode mise à jour…")
        case "reading": return tr("Lecture du firmware actuel…")
        case "checking-backup": return tr("Vérification de la sauvegarde…")
        case "backup-saved": return tr("Sauvegarde enregistrée.")
        case "writing": return tr("Écriture du firmware…")
        case "verifying": return tr("Vérification de l’écriture…")
        case "rollback": return tr("Retour à la version précédente…")
        case "rollback-verifying": return tr("Vérification du retour arrière…")
        default: return tr("Opération en cours…")
        }
    }
}
