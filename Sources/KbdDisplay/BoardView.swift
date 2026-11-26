import AppKit

/// One drawing path for the native output and scaled preview.
final class BoardView: NSView {
    override var isFlipped: Bool { true }
    enum CanvasSizing { case fitPreview, fillDisplay }
    private let canvasSizing: CanvasSizing

    init(frame: NSRect = .zero, canvasSizing: CanvasSizing = .fitPreview) {
        self.canvasSizing = canvasSizing
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        canvasSizing = .fitPreview
        super.init(coder: coder)
    }
    var effectsPaused = false {
        didSet {
            guard effectsPaused != oldValue else { return }
            if effectsPaused {
                animation?.invalidate()
                animation = nil
                clearHeldKeys()
                resetBeamHistory(matching: nil)
            } else {
                ensureAnimationRunning()
                needsDisplay = true
            }
        }
    }

    var effects = EffectConfiguration() {
        didSet {
            if !effects[.border] || !effects.borderReleaseDelay { releasedOutlines.removeAll() }
            if !morphsKeyOutlines {
                lastOutline = nil
                tappedOutline = nil
            }
            if !effects.waveTank { waveTank.reset() }
            if !effects.constellation { constellation.reset() }
            if !effects.matrixRain { matrixRain.reset() }
            if !effects.fireworks { fireworks.reset() }
            if effects.musicAmbient || shouldAnimateOrientationMarkers { ensureAnimationRunning() }
            needsDisplay = true
        }
    }
    var title: String? { didSet { if title != oldValue { needsDisplay = true } } }
    var hints: [KeyHint] = [] {
        didSet {
            guard hints != oldValue else { return }
            functionalHintLayouts.removeAll(keepingCapacity: true)
            needsDisplay = true
        }
    }
    var icons: [String: KeyArtwork] = [:] {
        didSet {
            if icons.count != oldValue.count || icons.contains(where: { oldValue[$0.key] !== $0.value }) {
                needsDisplay = true
            }
        }
    }
    var interactive = false
    enum KeycapPreview { case none, tiles, labeled }
    var keycapPreview = KeycapPreview.none { didSet { if keycapPreview != oldValue { needsDisplay = true } } }
    var calibration = false { didSet { needsDisplay = true } }
    var boardRect = CGRect(origin: .zero, size: Action75.canvas) { didSet { needsDisplay = true } }
    enum Input: Hashable { case local, mouse, monitor, plugin }

    struct Hit {
        let code: UInt16
        let startTime: TimeInterval
        var beam: KeyBeam
        var sources: Set<Input>
        var tracksRelease: Bool
    }

    private struct KeyOutline {
        static let morphDuration: TimeInterval = 0.14
        static let tapDuration: TimeInterval = 0.32

        let code: UInt16
        let startTime: TimeInterval
        let from: CGRect?
        let target: CGRect

        func frame(at now: TimeInterval) -> CGRect {
            guard let from, now - startTime < Self.morphDuration else { return target }
            let progress = CGFloat(max(0, now - startTime) / Self.morphDuration)
            let eased = progress * progress * (3 - 2 * progress)
            return CGRect(
                x: from.minX + (target.minX - from.minX) * eased,
                y: from.minY + (target.minY - from.minY) * eased,
                width: from.width + (target.width - from.width) * eased,
                height: from.height + (target.height - from.height) * eased
            )
        }
    }

    private struct HeldKey {
        let outline: KeyOutline
        var sources: Set<Input>
    }

    private struct ReleasedOutline {
        let outline: KeyOutline
        let expiresAt: TimeInterval
    }

    private(set) var hits: [Hit] = []
    private var heldKeys: [UInt16: HeldKey] = [:]
    private var releasedOutlines: [UInt16: ReleasedOutline] = [:]
    private var lastOutline: KeyOutline?
    private var tappedOutline: KeyOutline?
    private var history = KeyPressHistory()
    private var functionalHintLayouts: [KeyHint: FunctionalHintLayout] = [:]
    private var animation: Timer?
    private let duration = BlastEffect.duration
    private let waveTank = WaveTankEffect()
    private let constellation = ConstellationEffect()
    private let matrixRain = MatrixRainEffect()
    private let fireworks = FireworksEffect()

    override var acceptsFirstResponder: Bool { interactive }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowOcclusionDidChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        if shouldAnimateOrientationMarkers { ensureAnimationRunning() }
    }

    @objc private func windowOcclusionDidChange(_ notification: Notification) {
        if shouldAnimateOrientationMarkers { ensureAnimationRunning() }
    }

    private var shouldAnimateOrientationMarkers: Bool {
        effects.showOrientationMarkers && window?.occlusionState.contains(.visible) == true
    }

    private var morphsKeyOutlines: Bool {
        effects[.border] && effects.borderMorphsBetweenKeys
    }

    override func keyDown(with event: NSEvent) {
        guard interactive else { super.keyDown(with: event); return }
        if !event.isARepeat { pulse(event.keyCode, tracksRelease: event.keyCode != 57) }
    }

    override func keyUp(with event: NSEvent) {
        guard interactive else { super.keyUp(with: event); return }
        if event.keyCode != 57 { releaseKey(event.keyCode) }
    }

    override func flagsChanged(with event: NSEvent) {
        guard interactive else { super.flagsChanged(with: event); return }
        if event.keyCode == 57 {
            pulse(event.keyCode)
        } else if PressMonitor.isModifierPressed(event) {
            pulse(event.keyCode, tracksRelease: true)
        } else {
            releaseKey(event.keyCode)
        }
    }

    func wakeForDictationBlob() {
        ensureAnimationRunning()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let code = key(at: point) { pulse(code, source: .mouse) }
    }

    private var canvasFrame: CGRect {
        if canvasSizing == .fillDisplay { return bounds }
        let scale = min(bounds.width / Action75.canvas.width, bounds.height / Action75.canvas.height)
        let width = Action75.canvas.width * scale
        let height = Action75.canvas.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    private var canvasTransform: CGAffineTransform {
        let frame = canvasFrame
        return CGAffineTransform(translationX: frame.minX, y: frame.minY)
            .scaledBy(x: frame.width / Action75.canvas.width, y: frame.height / Action75.canvas.height)
            .translatedBy(x: boardRect.minX, y: boardRect.minY)
            .scaledBy(x: boardRect.width / Action75.canvas.width, y: boardRect.height / Action75.canvas.height)
    }

    func key(at point: CGPoint) -> UInt16? {
        let native = point.applying(canvasTransform.inverted())
        return Action75.rects.first { $0.value.contains(native) }?.key
    }

    func resetBeamHistory(matching board: BoardView?) {
        hits.removeAll()
        lastOutline = morphsKeyOutlines ? board?.lastOutline : nil
        tappedOutline = nil
        waveTank.reset()
        constellation.reset()
        matrixRain.reset()
        fireworks.reset()
        history = board?.history ?? KeyPressHistory()
        needsDisplay = true
    }

    func releaseKey(_ code: UInt16, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let held = heldKeys.removeValue(forKey: code) else { return }
        if effects[.border] && effects.borderReleaseDelay {
            releasedOutlines[code] = ReleasedOutline(outline: held.outline,
                                                      expiresAt: now + effects[.borderReleaseDuration])
            ensureAnimationRunning()
        }
        needsDisplay = true
    }

    func clearHeldKeys(from source: Input? = nil) {
        if let source {
            for code in Array(heldKeys.keys) {
                heldKeys[code]?.sources.remove(source)
                if heldKeys[code]?.sources.isEmpty == true {
                    heldKeys.removeValue(forKey: code)
                    needsDisplay = true
                }
            }
        } else {
            if !heldKeys.isEmpty || !releasedOutlines.isEmpty || tappedOutline != nil { needsDisplay = true }
            heldKeys.removeAll()
            releasedOutlines.removeAll()
            lastOutline = nil
            tappedOutline = nil
        }
    }

    private func startKeyOutline(_ code: UInt16, frame: CGRect, source: Input, tracksRelease: Bool,
                                 at now: TimeInterval, matchingTapAt: TimeInterval? = nil) {
        guard tracksRelease || (morphsKeyOutlines && heldKeys[code] == nil) else { return }
        let outline: KeyOutline
        if tracksRelease, let tap = tappedOutline, tap.code == code, tap.startTime == matchingTapAt {
            outline = tap
        } else {
            let from = lastOutline?.frame(at: now)
            outline = KeyOutline(code: code, startTime: now, from: from, target: frame)
            if morphsKeyOutlines {
                // Move the last outline. Keys that are still held keep their own outlines.
                if let lastOutline { releasedOutlines.removeValue(forKey: lastOutline.code) }
                lastOutline = outline
            }
        }
        releasedOutlines.removeValue(forKey: code)
        if tracksRelease { heldKeys[code] = HeldKey(outline: outline, sources: [source]) }
        tappedOutline = tracksRelease ? nil : outline
        needsDisplay = true
    }

    @discardableResult
    func pulse(_ code: UInt16, source: Input = .local, matching relayedBeam: KeyBeam? = nil,
               tracksRelease: Bool = false,
               at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> KeyBeam? {
        guard !effectsPaused, let key = Action75.rects[code] else { return nil }
        if tracksRelease, heldKeys[code] != nil {
            heldKeys[code]?.sources.insert(source)
            return nil
        }
        // One physical press can reach the view through AppKit, the event tap and IPC.
        if source != .mouse, let match = hits.lastIndex(where: {
            $0.code == code && now - $0.startTime < 0.085 && !$0.sources.contains(.mouse) && !$0.sources.contains(source)
                && (!tracksRelease || !$0.tracksRelease)
        }) {
            hits[match].sources.insert(source)
            if tracksRelease {
                startKeyOutline(code, frame: key, source: source, tracksRelease: true, at: now,
                                matchingTapAt: hits[match].startTime)
                hits[match].tracksRelease = true
                hits[match].beam.suppressesKeyFlash = true
            }
            return hits[match].beam
        }
        startKeyOutline(code, frame: key, source: source, tracksRelease: tracksRelease, at: now)
        let sparks = relayedBeam?.sparks ?? BeamSpark.burst(density: effects[.particleDensity])
        var beam = history.record(key: key, sparks: sparks, at: now, tapsToFullHeat: effects[.heatTaps])
        beam.suppressesKeyFlash = tracksRelease || morphsKeyOutlines
        if effects.randomSingleKeyEffects && effects.allowsSingleKeyEffects(for: beam) {
            let active = hits.last {
                $0.code == code && now - $0.startTime < duration && $0.beam.randomSingleKeyEffect != nil
            }
            beam.randomSingleKeyEffect = active?.beam.randomSingleKeyEffect
                ?? relayedBeam?.randomSingleKeyEffect
                ?? SingleKeyEffect.allCases.randomElement()
        }
        hits.append(Hit(code: code, startTime: now, beam: beam, sources: [source], tracksRelease: tracksRelease))
        if effects.soundEnabled {
            KeyboardSoundEngine.shared.play(keyCode: code, settings: effects)
        }
        let center = CGPoint(x: key.midX, y: key.midY)
        let strength = effects[.boardEffectStrength]
        if effects.waveTank {
            waveTank.impulse(at: center, strength: (1.0 + 0.55 * beam.flameHeat) * strength)
        }
        if effects.constellation {
            constellation.addNode(at: center, keyCode: code, at: now)
        }
        if effects.matrixRain {
            matrixRain.spawn(at: center, keyCode: code, at: now, strength: strength)
        }
        if effects.fireworks {
            fireworks.launch(from: center, keyCode: code, at: now, strength: strength)
        }
        if effects.musicAmbient {
            MusicAmbientController.shared.injectKeyImpulse(at: center, strength: 1.0 + 0.4 * beam.flameHeat)
        }
        needsDisplay = true
        ensureAnimationRunning()
        return beam
    }

    private func ensureAnimationRunning() {
        guard !effectsPaused, animation == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let now = ProcessInfo.processInfo.systemUptime
            self.hits.removeAll { now - $0.startTime >= self.duration }
            if !self.releasedOutlines.isEmpty {
                self.releasedOutlines = self.releasedOutlines.filter { now < $0.value.expiresAt }
            }
            if let tap = self.tappedOutline, now - tap.startTime >= KeyOutline.tapDuration {
                self.tappedOutline = nil
            }
            if self.effects.waveTank && self.waveTank.isActive {
                self.waveTank.step()
            }
            if self.effects.constellation && self.constellation.isActive {
                self.constellation.prune(now: now)
            }
            if self.effects.matrixRain && self.matrixRain.isActive {
                self.matrixRain.prune(now: now)
            }
            if self.effects.fireworks && self.fireworks.isActive {
                self.fireworks.prune(now: now)
            }
            self.needsDisplay = true
            let stillActive = self.shouldAnimateOrientationMarkers
                || !self.hits.isEmpty
                || !self.releasedOutlines.isEmpty
                || self.tappedOutline != nil
                || self.effects.musicAmbient
                || (self.effects.dictationVoiceBlob && DictationBlobController.shared.isActive)
                || (self.effects.waveTank && self.waveTank.isActive)
                || (self.effects.constellation && self.constellation.isActive)
                || (self.effects.matrixRain && self.matrixRain.isActive)
                || (self.effects.fireworks && self.fireworks.isActive)
            if !stillActive {
                timer.invalidate()
                self.animation = nil
            }
        }
        animation = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.clip(to: canvasFrame)
        cg.concatenate(canvasTransform)
        let now = ProcessInfo.processInfo.systemUptime
        let colors = effects.colorParams
        if !effectsPaused && effects.musicAmbient {
            MusicAmbientController.shared.draw(in: cg, now: now, settings: effects)
        }
        if effects.showKeyLegends { drawKeyLegends(now: now) }
        if !effectsPaused && effects.reactiveKeys {
            drawReactiveKeys(in: cg, now: now, colors: colors)
        } else {
            if keycapPreview != .none && !effects.showKeyLegends {
                let functionalKeys = Set(hints.lazy.filter(\.isFunctional).map(\.keyCode))
                for (code, frame) in Action75.rects where !functionalKeys.contains(code) {
                    let tile = frame.insetBy(dx: 5, dy: 5)
                    NSColor(white: 0.105, alpha: 1).setFill()
                    NSBezierPath(roundedRect: tile, xRadius: 12, yRadius: 12).fill()
                    if keycapPreview == .labeled, let legend = Action75.legends[code] {
                        text(legend, in: CGRect(x: tile.minX, y: tile.midY - 14, width: tile.width, height: 32), size: 22)
                    }
                }
            }
            if calibration {
                for (code, frame) in Action75.rects {
                    NSColor.darkGray.setStroke()
                    NSBezierPath(rect: frame.insetBy(dx: 2, dy: 2)).stroke()
                    text(String(code), in: frame.insetBy(dx: 5, dy: 5), size: 18)
                }
            }
            if let title, let space = Action75.rects[49], !hints.contains(where: { $0.keyCode == 49 }) {
                text(title, in: CGRect(x: space.minX, y: space.midY - 13, width: space.width, height: 32), size: 22)
            }
            for hint in hints {
                drawHint(hint, in: cg, alpha: 1)
            }
        }
        guard !effectsPaused else { return }
        let boardStrength = effects[.boardEffectStrength]
        if effects.waveTank && waveTank.isActive {
            waveTank.draw(in: cg, colors: colors, strength: boardStrength)
        }
        if effects.constellation && constellation.isActive {
            constellation.draw(in: cg, now: now, colors: colors, strength: boardStrength)
        }
        if effects.matrixRain && matrixRain.isActive {
            matrixRain.draw(in: cg, now: now, colors: colors, strength: boardStrength)
        }
        if effects.fireworks && fireworks.isActive {
            fireworks.draw(in: cg, now: now, colors: colors, strength: boardStrength)
        }
        drawOrientationMarkers(in: cg, now: now)
        if effects.dictationVoiceBlob && DictationBlobController.shared.isActive {
            DictationBlobController.shared.draw(in: cg, now: now, settings: effects)
        }
        BlastEffect.shared.draw(hits.map { ($0.beam, now - $0.startTime) }, settings: effects)
        drawKeyOutlines(in: cg, now: now, colors: colors)
    }

    func drawKeyOutlines(in cg: CGContext, now: TimeInterval, colors: EffectColorParams) {
        guard effects[.border] else { return }
        let brightness = effects[.borderBrightness]
        let morph = morphsKeyOutlines
        func drawOutline(_ outline: KeyOutline) {
            let frame = morph ? outline.frame(at: now) : outline.target
            BlastEffect.drawHeldKeyOutline(in: cg, key: frame, age: now - outline.startTime,
                                           brightness: brightness, colors: colors)
        }
        for held in heldKeys.values {
            drawOutline(held.outline)
        }
        for released in releasedOutlines.values where now < released.expiresAt {
            drawOutline(released.outline)
        }
        if let tap = tappedOutline, now - tap.startTime < KeyOutline.tapDuration {
            drawOutline(tap)
        }
    }

    func drawOrientationMarkers(in cg: CGContext, now: TimeInterval) {
        guard effects.showOrientationMarkers else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setBlendMode(.plusLighter)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let cornerRadius: CGFloat = 12

        // 1. Digit markers (3, 6, 9): wide electric cyan-white glow brim + blazing flowing comet sweep.
        let digitFlowPhase = CGFloat((now / 2.4).truncatingRemainder(dividingBy: 1.0))
        let digitTargets: [(UInt16, CGFloat)] = [(20, 0.0), (22, 1.0 / 3.0), (25, 2.0 / 3.0)]
        for (code, phaseOffset) in digitTargets {
            guard let frame = Action75.rects[code] else { continue }
            cg.saveGState()
            let clipPath = CGPath(roundedRect: frame.insetBy(dx: 1, dy: 1), cornerWidth: 14, cornerHeight: 14, transform: nil)
            cg.addPath(clipPath)
            cg.clip()

            let tile = frame.insetBy(dx: 11, dy: 11)
            let outline = CGPath(roundedRect: tile, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            let brimLayers: [(width: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)] = [
                (32.0, 0.16, 0.78, 1.0, 0.24),
                (18.0, 0.45, 0.90, 1.0, 0.28),
                (7.5,  1.0,  1.0,  1.0, 0.22)
            ]
            for layer in brimLayers {
                cg.setStrokeColor(red: layer.r, green: layer.g, blue: layer.b, alpha: layer.a)
                cg.setLineWidth(layer.width)
                cg.addPath(outline)
                cg.strokePath()
            }
            if !reduceMotion {
                Self.strokeFlowingArc(
                    in: cg,
                    rect: tile,
                    radius: cornerRadius,
                    headFraction: digitFlowPhase + phaseOffset,
                    direction: 1.0,
                    arcSpan: 0.44,
                    steps: 28,
                    intensity: 1.0,
                    haloColor: (0.28, 0.88, 1.0),
                    haloScale: 1.0,
                    coreScale: 1.0
                )
            }
            cg.restoreGState()
        }

        // 2. Homing keys (F, J): organic breathing perimeter aura with mirrored flowing breath streams.
        let breath: CGFloat = reduceMotion
            ? 0.78
            : CGFloat(0.24 + 0.76 * (0.5 - 0.5 * cos(2.0 * .pi * now / 3.2)))
        let fjFlowPhase = CGFloat((now / 2.6).truncatingRemainder(dividingBy: 1.0))
        let homingTargets: [(UInt16, CGFloat)] = [(3, 1.0), (38, -1.0)]
        for (code, direction) in homingTargets {
            guard let frame = Action75.rects[code] else { continue }
            cg.saveGState()
            let clipPath = CGPath(roundedRect: frame.insetBy(dx: 1, dy: 1), cornerWidth: 14, cornerHeight: 14, transform: nil)
            cg.addPath(clipPath)
            cg.clip()

            let tile = frame.insetBy(dx: 5, dy: 5)
            let outline = CGPath(roundedRect: tile, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            let auraLayers: [(CGFloat, CGFloat)] = [
                (8.5 + 3.5 * breath, 0.06 + 0.10 * breath),
                (5.0 + 2.0 * breath, 0.10 + 0.14 * breath),
                (2.4, 0.14 + 0.20 * breath)
            ]
            for (width, alpha) in auraLayers {
                cg.setStrokeColor(red: 1, green: 1, blue: 1, alpha: alpha)
                cg.setLineWidth(width)
                cg.addPath(outline)
                cg.strokePath()
            }
            if !reduceMotion {
                let flowIntensity = 0.42 + 0.58 * breath
                Self.strokeFlowingArc(
                    in: cg,
                    rect: tile,
                    radius: cornerRadius,
                    headFraction: fjFlowPhase * direction,
                    direction: direction,
                    arcSpan: 0.36,
                    steps: 26,
                    intensity: flowIntensity,
                    haloColor: (1.0, 1.0, 1.0),
                    haloScale: 0.52,
                    coreScale: 0.48
                )
                Self.strokeFlowingArc(
                    in: cg,
                    rect: tile,
                    radius: cornerRadius,
                    headFraction: (fjFlowPhase + 0.5) * direction,
                    direction: direction,
                    arcSpan: 0.22,
                    steps: 18,
                    intensity: flowIntensity * 0.38,
                    haloColor: (1.0, 1.0, 1.0),
                    haloScale: 0.42,
                    coreScale: 0.40
                )
            }
            cg.restoreGState()
        }
    }

    private static func strokeFlowingArc(
        in cg: CGContext,
        rect: CGRect,
        radius: CGFloat,
        headFraction: CGFloat,
        direction: CGFloat,
        arcSpan: CGFloat,
        steps: Int,
        intensity: CGFloat,
        haloColor: (CGFloat, CGFloat, CGFloat),
        haloScale: CGFloat,
        coreScale: CGFloat
    ) {
        guard steps > 0 else { return }
        var prev = roundedRectPoint(in: rect, radius: radius, at: headFraction - direction * arcSpan)
        for step in 1...steps {
            let u = CGFloat(step) / CGFloat(steps)
            let curr = roundedRectPoint(in: rect, radius: radius, at: headFraction - direction * arcSpan * (1.0 - u))
            let taper = pow(u, 1.55) * intensity

            cg.setStrokeColor(red: haloColor.0, green: haloColor.1, blue: haloColor.2, alpha: min(1.0, taper * 0.78))
            cg.setLineWidth((9.0 + 18.0 * u) * haloScale)
            cg.move(to: prev)
            cg.addLine(to: curr)
            cg.strokePath()

            cg.setStrokeColor(red: 1, green: 1, blue: 1, alpha: min(1.0, taper * 1.0))
            cg.setLineWidth((3.5 + 8.5 * u) * coreScale)
            cg.move(to: prev)
            cg.addLine(to: curr)
            cg.strokePath()

            prev = curr
        }

        let head = roundedRectPoint(in: rect, radius: radius, at: headFraction)
        let haloR = 16.0 * haloScale
        let coreR = 9.0 * coreScale
        cg.setFillColor(red: haloColor.0, green: haloColor.1, blue: haloColor.2, alpha: min(1.0, 0.65 * intensity))
        cg.fillEllipse(in: CGRect(x: head.x - haloR, y: head.y - haloR, width: haloR * 2, height: haloR * 2))
        cg.setFillColor(red: 1, green: 1, blue: 1, alpha: min(1.0, intensity))
        cg.fillEllipse(in: CGRect(x: head.x - coreR, y: head.y - coreR, width: coreR * 2, height: coreR * 2))
    }

    private static func roundedRectPoint(in rect: CGRect, radius rawRadius: CGFloat, at rawFraction: CGFloat) -> CGPoint {
        let r = min(rawRadius, min(rect.width, rect.height) * 0.5)
        let topLen = max(0, rect.width - 2 * r)
        let sideLen = max(0, rect.height - 2 * r)
        let cornerLen = 0.5 * .pi * r
        let perimeter = 2 * (topLen + sideLen) + 4 * cornerLen
        guard perimeter > 0 else { return CGPoint(x: rect.midX, y: rect.midY) }

        let wrapped = ((rawFraction.truncatingRemainder(dividingBy: 1.0)) + 1.0).truncatingRemainder(dividingBy: 1.0)
        var d = wrapped * perimeter

        if d <= topLen {
            return CGPoint(x: rect.minX + r + d, y: rect.minY)
        }
        d -= topLen

        if d <= cornerLen {
            let angle = -.pi * 0.5 + (d / max(1e-5, r))
            let center = CGPoint(x: rect.maxX - r, y: rect.minY + r)
            return CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
        }
        d -= cornerLen

        if d <= sideLen {
            return CGPoint(x: rect.maxX, y: rect.minY + r + d)
        }
        d -= sideLen

        if d <= cornerLen {
            let angle = 0.0 + (d / max(1e-5, r))
            let center = CGPoint(x: rect.maxX - r, y: rect.maxY - r)
            return CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
        }
        d -= cornerLen

        if d <= topLen {
            return CGPoint(x: rect.maxX - r - d, y: rect.maxY)
        }
        d -= topLen

        if d <= cornerLen {
            let angle = .pi * 0.5 + (d / max(1e-5, r))
            let center = CGPoint(x: rect.minX + r, y: rect.maxY - r)
            return CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
        }
        d -= cornerLen

        if d <= sideLen {
            return CGPoint(x: rect.minX, y: rect.maxY - r - d)
        }
        d -= sideLen

        let angle = .pi + (d / max(1e-5, r))
        let center = CGPoint(x: rect.minX + r, y: rect.minY + r)
        return CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
    }

    private func drawKeyLegends(now: TimeInterval) {
        let color = effects.keyLegendColor
        guard color.alphaComponent > 0 else { return }
        let hintedKeys = Set(hints.lazy.map(\.keyCode))
        if !effectsPaused && effects.reactiveKeys {
            var drawn: Set<UInt16> = []
            for hit in hits.reversed() where !hintedKeys.contains(hit.code) {
                let age = now - hit.startTime
                guard age >= 0, age < duration, drawn.insert(hit.code).inserted else { continue }
                let strength = pow(1 - age / duration, 1.5)
                drawKeyLegend(hit.code, color: color.withAlphaComponent(color.alphaComponent * strength))
            }
        } else {
            for code in Action75.legends.keys where !hintedKeys.contains(code) && (code != 49 || title == nil) {
                drawKeyLegend(code, color: color)
            }
        }
    }

    private func drawKeyLegend(_ code: UInt16, color: NSColor) {
        guard let frame = Action75.rects[code], let legend = Action75.legends[code] else { return }
        let rect = CGRect(x: frame.minX + 5, y: frame.midY - 21, width: frame.width - 10, height: 42)
        text(legend.isEmpty ? "␣" : legend, in: rect, size: 32, color: color)
    }

    private func drawHint(_ hint: KeyHint, in context: CGContext, alpha: CGFloat) {
        guard let frame = Action75.rects[hint.keyCode], alpha > 0.01 else { return }
        let tile = frame.insetBy(dx: 5, dy: 5)
        if hint.isFunctional {
            let layout = functionalHintLayouts[hint] ?? FunctionalHintLayout(hint, in: tile)
            functionalHintLayouts[hint] = layout
            layout.draw(in: context, alpha: alpha)
            return
        }
        let artwork = hint.iconID.flatMap { icons[$0] }
        let colors = artwork?.colors ?? .fallback
        colors.background.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: tile, xRadius: 12, yRadius: 12).fill()
        if let image = artwork?.image ?? NSImage(systemSymbolName: hint.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [colors.foreground])) {
            let factor = 62.0 / max(image.size.width, image.size.height)
            let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
            image.draw(in: CGRect(x: tile.midX - size.width/2, y: tile.midY - 47,
                                  width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        }
        if keycapPreview == .labeled, let legend = Action75.legends[hint.keyCode] {
            text(legend, in: CGRect(x: tile.minX + 2, y: tile.minY + 3, width: 24, height: 20),
                 size: 14, color: colors.foreground.withAlphaComponent(alpha))
        }
        text(hint.label, in: CGRect(x: tile.minX + 3, y: tile.midY + 14, width: tile.width - 6, height: 32),
             size: 19, color: colors.foreground.withAlphaComponent(alpha))
    }

    /// Lights-off mode: keys stay completely dark at idle and illuminate when tapped,
    /// with adjacent keys lighting up proportionally to their distance from active glows.
    private func drawReactiveKeys(in cg: CGContext, now: TimeInterval, colors: EffectColorParams) {
        guard !effects.showKeyLegends || !hints.isEmpty else { return }
        let activeHits: [(hit: Hit, age: TimeInterval, orb: CGPoint, progress: Float, alpha: Float)] = hits.compactMap { hit in
            let age = now - hit.startTime
            guard age >= 0, age < duration else { return nil }
            let timing = BlastEffect.timing(at: age / duration)
            let orb = hit.beam.length > 0
                ? BlastEffect.arcGeometry(for: hit.beam, progress: CGFloat(timing.x)).worldPoint
                : hit.beam.end
            return (hit, age, orb, timing.x, timing.y)
        }
        let activeNodes = effects.constellation ? constellation.nodes : []
        guard !activeHits.isEmpty || !activeNodes.isEmpty else { return }

        let hintsByCode = Dictionary(hints.map { ($0.keyCode, $0) }, uniquingKeysWith: { _, latest in latest })
        let glowReachBase = (275.0) * effects[.glowSize]

        for (code, frame) in Action75.rects where !effects.showKeyLegends || hintsByCode[code] != nil {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            var light = 0.0
            var tintR = 0.0, tintG = 0.0, tintB = 0.0, tintWeight = 0.0

            for entry in activeHits {
                let direct = entry.hit.code == code
                    ? pow(max(0.0, 1.0 - entry.age / 0.74), 1.5)
                    : 0.0
                let dEnd = hypot(center.x - entry.hit.beam.end.x, center.y - entry.hit.beam.end.y)
                let dOrb = hypot(center.x - entry.orb.x, center.y - entry.orb.y)
                let dist = min(dEnd, dOrb)
                let radius = glowReachBase + 90.0 * entry.hit.beam.flameHeat
                let prox = dist < radius
                    ? pow(max(0.0, 1.0 - Double(dist) / radius), 2.15) * Double(entry.alpha) * (0.78 + 0.22 * entry.hit.beam.flameHeat)
                    : 0.0
                let contrib = max(direct, prox)
                if contrib > 0.005 {
                    light = min(1.0, light + contrib * (1.0 - light * 0.45))
                    let phase = entry.progress + Float(dist / max(1.0, radius)) * 0.35
                    if let c = colors.samplePalette(at: phase).usingColorSpace(.sRGB) {
                        tintR += Double(c.redComponent) * contrib
                        tintG += Double(c.greenComponent) * contrib
                        tintB += Double(c.blueComponent) * contrib
                        tintWeight += contrib
                    }
                }
            }

            for node in activeNodes {
                let age = now - node.bornAt
                guard age >= 0, age < ConstellationEffect.nodeLifetime else { continue }
                let dist = hypot(center.x - node.origin.x, center.y - node.origin.y)
                let radius: CGFloat = 230
                guard dist < radius else { continue }
                let nodeFade = pow(max(0.0, 1.0 - age / ConstellationEffect.nodeLifetime), 1.4)
                let contrib = pow(Double(1.0 - dist / radius), 2.0) * nodeFade * 0.55
                if contrib > 0.005 {
                    light = min(1.0, light + contrib * (1.0 - light * 0.45))
                    if let c = colors.samplePalette(at: Float(fmod(node.phase * 0.31 + now * 0.08, 1.0))).usingColorSpace(.sRGB) {
                        tintR += Double(c.redComponent) * contrib
                        tintG += Double(c.greenComponent) * contrib
                        tintB += Double(c.blueComponent) * contrib
                        tintWeight += contrib
                    }
                }
            }

            guard light > 0.01 else { continue }
            let hint = hintsByCode[code]
            let hintAlpha = CGFloat(min(1.0, light * 1.25))
            if let hint, hint.isFunctional {
                drawHint(hint, in: cg, alpha: hintAlpha)
                continue
            }
            let tile = frame.insetBy(dx: 5, dy: 5)
            let r = tintWeight > 0 ? tintR / tintWeight : 0.75
            let g = tintWeight > 0 ? tintG / tintWeight : 0.85
            let b = tintWeight > 0 ? tintB / tintWeight : 1.0

            // Soft backlit keycap surface tinted by the illuminating glow
            let fill = NSColor(srgbRed: 0.07 + r * 0.32, green: 0.07 + g * 0.32, blue: 0.08 + b * 0.34,
                               alpha: min(0.88, light * 0.65))
            let border = NSColor(srgbRed: min(1, r * 0.85 + 0.25), green: min(1, g * 0.85 + 0.25),
                                 blue: min(1, b * 0.85 + 0.25), alpha: min(0.95, light * 0.85))
            let rounded = NSBezierPath(roundedRect: tile, xRadius: 12, yRadius: 12)
            fill.setFill()
            rounded.fill()
            border.setStroke()
            rounded.lineWidth = 1.2 + CGFloat(light) * 1.1
            rounded.stroke()

            if let hint {
                drawHint(hint, in: cg, alpha: hintAlpha)
            } else if let legend = Action75.legends[code] {
                let textAlpha = CGFloat(min(1.0, light * 1.35))
                text(legend, in: CGRect(x: tile.minX, y: tile.midY - 14, width: tile.width, height: 32),
                     size: 22, color: NSColor(white: 1.0, alpha: textAlpha))
            }
        }
    }

    private func text(_ value: String, in rect: CGRect, size: CGFloat, color: NSColor = .white) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        value.draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold),
                                              .foregroundColor: color, .paragraphStyle: style])
    }
}

private struct FunctionalHintLayout {
    private static let textOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
    private let symbol: NSImage?
    private let symbolRect: CGRect
    private let label: NSAttributedString?
    private let labelRect: CGRect

    init(_ hint: KeyHint, in tile: CGRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: tile.height, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        let symbol = NSImage(systemSymbolName: hint.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        self.symbol = symbol

        let labelText = hint.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let gap: CGFloat = symbol == nil || labelText.isEmpty ? 0 : 4
        let labelLimit = CGSize(width: tile.width, height: symbol == nil ? tile.height : floor(tile.height * 0.45))
        let label = labelText.isEmpty ? nil : Self.fittedLabel(labelText, limit: labelLimit)
        self.label = label
        let labelHeight = min(labelLimit.height, label.map { Self.labelHeight($0, width: tile.width) } ?? 0)

        var symbolSize = CGSize.zero
        if let size = symbol?.size, size.width > 0, size.height > 0 {
            let scale = min(tile.width / size.width, (tile.height - labelHeight - gap) / size.height)
            symbolSize = CGSize(width: size.width * scale, height: size.height * scale)
        }
        let top = tile.midY - (symbolSize.height + gap + labelHeight) / 2
        symbolRect = CGRect(x: tile.midX - symbolSize.width / 2, y: top,
                            width: symbolSize.width, height: symbolSize.height)
        labelRect = CGRect(x: tile.minX, y: symbolRect.maxY + gap, width: tile.width, height: labelHeight)
    }

    func draw(in context: CGContext, alpha: CGFloat) {
        symbol?.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: alpha,
                     respectFlipped: true, hints: nil)
        guard let label else { return }
        context.saveGState()
        context.clip(to: labelRect)
        context.setAlpha(alpha)
        label.draw(with: labelRect, options: Self.textOptions.union(.truncatesLastVisibleLine))
        context.restoreGState()
    }

    private static func fittedLabel(_ value: String, limit: CGSize) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        func styled(_ size: Int) -> NSAttributedString {
            NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: CGFloat(size), weight: .semibold),
                                                           .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
        }
        var smallest = 1
        var largest = max(smallest, Int(limit.height))
        while smallest < largest {
            let size = (smallest + largest + 1) / 2
            if labelHeight(styled(size), width: limit.width) <= limit.height {
                smallest = size
            } else {
                largest = size - 1
            }
        }
        return styled(smallest)
    }

    private static func labelHeight(_ label: NSAttributedString, width: CGFloat) -> CGFloat {
        let size = CGSize(width: width, height: .greatestFiniteMagnitude)
        return ceil(label.boundingRect(with: size, options: textOptions).height)
    }
}
