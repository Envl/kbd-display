import AppKit
import SwiftUI

final class EffectsWindow: NSWindow, NSWindowDelegate {
    private let recorder: ShortcutRecorder

    init(store: EffectSettingsStore, updates: AppUpdates, recorder: ShortcutRecorder, beside preview: NSWindow?,
         previewCreated: @escaping (BoardView) -> Void,
         selectOutput: @escaping (String?) -> Void, requestAccess: @escaping () -> Void) {
        self.recorder = recorder
        super.init(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        title = "Effects"
        isReleasedWhenClosed = false
        delegate = self
        contentView = NSHostingView(rootView: EffectsForm(store: store, updates: updates, recorder: recorder, previewCreated: previewCreated,
            selectOutput: selectOutput, requestAccess: requestAccess,
            page: store.connection.hasOutput && store.keyboardMonitoringActive ? .appearance : .setup))
        contentMinSize = NSSize(width: 640, height: 400)
        setContentSize(NSSize(width: 780, height: 600))
        if let preview, preview.isVisible, let screen = preview.screen {
            let visible = screen.visibleFrame
            let right = preview.frame.maxX + 10
            let left = preview.frame.minX - frame.width - 10
            let x = right + frame.width <= visible.maxX || left < visible.minX ? right : left
            setFrameOrigin(NSPoint(x: min(max(visible.minX, x), visible.maxX - frame.width),
                                   y: min(max(visible.minY, preview.frame.maxY - frame.height), visible.maxY - frame.height)))
        } else {
            center()
        }
        setFrameAutosaveName("KbdDisplayEffectsSettings")
    }

    func show() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            NSApp.dockTile.display()
        }
        NSApp.activate(ignoringOtherApps: true)
        if isMiniaturized { deminiaturize(nil) }
        makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        recorder.cancel()
        NSApp.setActivationPolicy(.accessory)
    }

    override func resignKey() {
        recorder.cancel()
        super.resignKey()
    }
}

private struct SettingsDisclosure<Content: View>: View {
    let title: String
    let content: () -> Content
    @State private var expanded = false

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Text(title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            DisclosureGroup(title, isExpanded: $expanded) { EmptyView() }
        }
        if expanded { content() }
    }
}

private enum EffectsPage: String, CaseIterable {
    case setup = "Setup", appearance = "Appearance", keys = "Key effects", sound = "Typing sound"
    case music = "Music", dictation = "Dictation"

    var symbol: String {
        switch self {
        case .setup: return "cable.connector"
        case .appearance: return "paintpalette"
        case .keys: return "keyboard"
        case .sound: return "speaker.wave.2"
        case .music: return "music.note"
        case .dictation: return "mic"
        }
    }
}

private struct EffectsForm: View {
    @ObservedObject var store: EffectSettingsStore
    @ObservedObject var updates: AppUpdates
    let recorder: ShortcutRecorder
    let previewCreated: (BoardView) -> Void
    let selectOutput: (String?) -> Void
    let requestAccess: () -> Void
    @State var page: EffectsPage?
    @State private var confirmReset = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                List(EffectsPage.allCases, id: \.self, selection: $page) { item in
                    Label(item.rawValue, systemImage: item.symbol).padding(.vertical, 5)
                }
                .listStyle(.sidebar)
                Divider()
                Menu {
                    Button("Restore default effects…") { confirmReset = true }
                        .disabled(store.value == EffectConfiguration())
                    Divider()
                    Button("Quit kbd-display") { NSApp.terminate(nil) }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .padding(14)
            }
            .frame(width: 164)
            .background(.regularMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text((page ?? .appearance).rawValue).font(.title.bold())
                    .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 6)
                if let version = updates.readyVersion {
                    HStack {
                        Label("Version \(version) is ready", systemImage: "arrow.down.circle")
                        Spacer()
                        Button("Restart to Update", action: updates.restartToUpdate)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 6)
                }
                if page != .setup && !store.keyboardMonitoringActive {
                    HStack {
                        Label("Keyboard access needed", systemImage: "keyboard")
                        Spacer()
                        Button("Allow access…", action: requestAccess)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 6)
                }
                if store.isPaused {
                    HStack {
                        Label("Effects paused", systemImage: "pause.circle")
                        Spacer()
                        Button("Resume") { store.isPaused = false }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 6)
                }
                Form {
                    if [.appearance, .keys, .dictation].contains(page ?? .appearance) {
                        Section {
                            BoardSettingsPreview(store: store, labelKeys: page == .dictation, previewCreated: previewCreated)
                                .aspectRatio(8 / 3, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .accessibilityLabel("Keyboard preview")
                        }
                    }
                    switch page ?? .appearance {
                    case .setup:
                        KeyboardSetup(connection: store.connection, monitoring: store.keyboardMonitoringActive,
                                      paused: store.isPaused, selectOutput: selectOutput, requestAccess: requestAccess,
                                      customize: { page = .appearance })
                    case .appearance: appearance
                    case .keys: keyEffects
                    case .sound: sound
                    case .music: MusicSettings(store: store)
                    case .dictation: DictationSettings(store: store, recorder: recorder)
                    }
                }
                .formStyle(.grouped)
                .id(page)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .toggleStyle(.switch)
        .onChange(of: page) { _ in recorder.cancel() }
        .alert("Restore default effects?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Restore defaults", role: .destructive) { store.value = EffectConfiguration() }
        }
    }

    @ViewBuilder private var appearance: some View {
        Section("Colors") {
            Picker("Animation style", selection: $store.value.style) {
                ForEach(EffectStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            LabeledContent("Palette") {
                PalettePreviewBar(params: store.value.colorParams).frame(maxWidth: 125).frame(height: 14)
                    .accessibilityHidden(true)
                Button("Shuffle") { store.value.rollPalette() }
                Button("Reset") { store.value.resetColors() }.disabled(store.value.hasDefaultColors)
                    .accessibilityLabel("Reset colors")
            }
            SettingsDisclosure("Adjust colors") { sliders(EffectControl.colorControls) }
        }
        Section("Keyboard lighting") {
            Toggle("Light up only when pressed", isOn: $store.value.reactiveKeys)
            Toggle("Show key labels", isOn: $store.value.showKeyLegends)
            if store.value.showKeyLegends { sliders(EffectControl.keyLegendControls) }
            Toggle("Show position markers", isOn: $store.value.showOrientationMarkers)
        }
    }

    @ViewBuilder private var keyEffects: some View {
        Section("Between keystrokes") {
            ForEach([EffectLayer.glow, .border, .particles], id: \.self) { layer in
                Toggle(layer.title, isOn: layerBinding(layer))
                if store.value[layer] {
                    SettingsDisclosure("Adjust " + layer.title.lowercased()) {
                        if layer == .glow {
                            Picker("Trail", selection: $store.value.travelBlade) {
                                Text("Glow").tag(BladeStyle?.none)
                                ForEach(BladeStyle.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                            }
                        }
                        sliders(layer.controls)
                        if layer == .border {
                            Toggle("Slide outline between keys", isOn: $store.value.borderMorphsBetweenKeys)
                            Toggle("Keep outline after release", isOn: $store.value.borderReleaseDelay)
                            if store.value.borderReleaseDelay { sliders([.borderReleaseDuration]) }
                        }
                    }
                }
            }
        }
        Section("On each key") {
            Toggle("Choose an effect at random", isOn: $store.value.randomSingleKeyEffects)
            if !store.value.randomSingleKeyEffects {
                Toggle("Fire", isOn: layerBinding(.flame))
                Toggle("Lightning", isOn: $store.value.lightning)
                Toggle("Ice", isOn: $store.value.ice)
                Toggle("Water wave", isOn: $store.value.waterWave)
                Toggle("Confetti", isOn: $store.value.confetti)
                Toggle("Black hole", isOn: $store.value.blackHole)
            }
            if store.value.hasAnySingleKeyEffect {
                Toggle("Only on repeated presses", isOn: $store.value.fireRepeatOnly)
                SettingsDisclosure("Adjust effect size") { sliders(EffectLayer.flame.controls) }
            }
        }
        Section("Across the keyboard") {
            Toggle("Water ripples", isOn: $store.value.waveTank)
            Toggle("Constellation", isOn: $store.value.constellation)
            Toggle("Matrix rain", isOn: $store.value.matrixRain)
            Toggle("Fireworks", isOn: $store.value.fireworks)
            if store.value.hasAnyBoardEffect { sliders([.boardEffectStrength]) }
        }
    }

    @ViewBuilder private var sound: some View {
        Section {
            Toggle("Play a sound when typing", isOn: $store.value.soundEnabled)
            Picker("Sound", selection: $store.value.soundProfile) {
                ForEach(KeyboardSoundProfile.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Button("Play sample") {
                var settings = store.value
                settings.soundEnabled = true
                KeyboardSoundEngine.shared.play(keyCode: 36, settings: settings, bypassDebounce: true)
            }.disabled(store.isPaused)
        }
        Section("Sound adjustments") { sliders(EffectControl.soundControls) }
    }

    private func layerBinding(_ layer: EffectLayer) -> Binding<Bool> {
        Binding(get: { store.value[layer] }, set: { store.value[layer] = $0 })
    }

    private func sliders(_ controls: [EffectControl]) -> some View {
        EffectSliders(store: store, controls: controls)
    }
}

extension BoardView {
    func applySettingsPreview(_ settings: EffectConfiguration, paused: Bool) {
        // Mirrored key presses already produce sound and music impulses on the output board.
        var visual = settings
        visual.soundEnabled = false
        visual.musicAmbient = false
        if visual != effects { effects = visual }
        effectsPaused = paused
    }
}

struct BoardSettingsPreview: NSViewRepresentable {
    @ObservedObject var store: EffectSettingsStore
    let labelKeys: Bool
    let previewCreated: (BoardView) -> Void

    func makeNSView(context: Context) -> BoardView {
        let board = BoardView()
        board.interactive = true
        configure(board)
        previewCreated(board)
        return board
    }

    func updateNSView(_ view: BoardView, context: Context) {
        configure(view)
    }

    private func configure(_ board: BoardView) {
        board.keycapPreview = labelKeys ? .labeled : .tiles
        board.applySettingsPreview(store.value, paused: store.isPaused)
    }

    static func dismantleNSView(_ view: BoardView, coordinator: ()) {
        view.effectsPaused = true
    }
}

private struct EffectSliders: View {
    @ObservedObject var store: EffectSettingsStore
    let controls: [EffectControl]

    var body: some View {
        ForEach(controls, id: \.self) { control in
            LabeledContent(control.title) {
                Slider(value: Binding(get: { store.value[control] }, set: { store.value[control] = $0 }),
                       in: control.range, step: control.step)
                    .frame(maxWidth: 170)
                    .accessibilityLabel(control.title)
                    .accessibilityValue(control.formattedValue(store.value[control]))
                Text(control.formattedValue(store.value[control]))
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
            }
        }
    }
}

private struct MusicSettings: View {
    @ObservedObject var store: EffectSettingsStore
    @ObservedObject private var audio = MusicAudioEngine.shared

    var body: some View {
        Section {
            Toggle("Animate to music", isOn: $store.value.musicAmbient)
            Picker("Audio source", selection: $store.value.musicAudioSource) {
                ForEach(MusicAudioSource.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if store.value.musicAmbient && !store.isPaused { status }
        }
        Section("Animation") {
            Picker("Visual style", selection: $store.value.musicVisual) {
                ForEach(MusicVisualStyle.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            Toggle("Cycle through styles", isOn: $store.value.musicAutoCycle)
            SettingsDisclosure("Adjust response") { EffectSliders(store: store, controls: EffectControl.musicControls) }
        }
    }

    @ViewBuilder private var status: some View {
        switch audio.status {
        case .stopped: EmptyView()
        case .listening:
            LabeledContent("Audio level") {
                MusicMeterView(bands: audio.meterBands, beat: audio.beatIndicator, active: true,
                               colors: store.value.colorParams).frame(width: 96, height: 20)
            }
        case .permissionNeeded(let message), .error(let message):
            Text(message).foregroundStyle(.secondary)
            HStack {
                Button("Retry") { audio.retry() }
                if case .permissionNeeded = audio.status {
                    Button("Open privacy settings…") {
                        let pane = store.value.musicAudioSource == .microphone ? "Microphone" : "AudioCapture"
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + pane) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }
}

private struct DictationSettings: View {
    @ObservedObject var store: EffectSettingsStore
    @ObservedObject var recorder: ShortcutRecorder
    @ObservedObject private var dictation = DictationBlobController.shared

    var body: some View {
        Section {
            Toggle("Show voice glow", isOn: $store.value.dictationVoiceBlob)
            LabeledContent("Hold shortcut") {
                if let keys = recorder.keys {
                    Text(keys.isEmpty ? "Press and release keys…" : keys.map(DictationShortcut.name).joined(separator: " + "))
                        .foregroundStyle(Color.accentColor)
                    Button("Cancel") { recorder.cancel() }
                } else {
                    Button {
                        dictation.stop()
                        recorder.begin { store.value.dictationShortcut = $0 }
                    } label: {
                        Label(store.value.dictationShortcut.title, systemImage: "pencil")
                    }
                    .help("Click to record a key or combination")
                    .accessibilityLabel("Record hold shortcut, " + store.value.dictationShortcut.title)
                    if store.value.dictationShortcut != .standard {
                        Button("Reset") { store.value.dictationShortcut = .standard }
                            .accessibilityLabel("Restore Right Option shortcut")
                    }
                }
            }
        }
        if store.value.dictationVoiceBlob {
            Section {
                LabeledContent("Voice glow", value: dictation.statusText)
                if dictation.isExternalMicOpen {
                    LabeledContent("Voice level") {
                        ProgressView(value: Double(dictation.liveAmplitude)).frame(width: 100)
                    }
                }
                Button("Preview glow") { dictation.triggerPreview() }.disabled(store.isPaused || recorder.keys != nil)
                if dictation.permissionDenied {
                    Button("Open microphone settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }
}
private struct PalettePreviewBar: View {
    let params: EffectColorParams

    var body: some View {
        let stops = (0...10).map { i in
            Color(nsColor: params.samplePalette(at: Float(i) / 10.0))
        }
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            )
    }
}

private struct MusicMeterView: View {
    let bands: [Float]
    let beat: Float
    let active: Bool
    let colors: EffectColorParams

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<16, id: \.self) { i in
                let value = active && i < bands.count ? CGFloat(min(1, max(0.08, bands[i]))) : 0.08
                let color = active
                    ? Color(nsColor: colors.samplePalette(at: Float(i) / 15.0))
                    : Color.secondary.opacity(0.25)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(color)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, value * 16))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(active && beat > 0.35 ? Color.accentColor.opacity(Double(beat) * 0.7) : Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
    }
}
