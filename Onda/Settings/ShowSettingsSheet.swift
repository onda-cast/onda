//  ShowSettingsSheet.swift
import SwiftUI
import AVFoundation

struct ShowSettingsSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(PlaybackManager.self) private var playback
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.dismiss) private var dismiss
    @Bindable var podcast: Podcast

    private var s: ShowSettings {
        if podcast.settings == nil {
            let ns = ShowSettings.makeDefault(); ns.podcast = podcast; podcast.settings = ns
        }
        return podcast.settings!
    }

    static let speedSteps: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    /// Where a fresh "Custom" speed starts: the next step ABOVE the global default (wrapping),
    /// so choosing Custom is immediately visible instead of silently mirroring Default.
    static func customSpeedSeed(from global: Double) -> Double {
        speedSteps.first { $0 > global } ?? speedSteps[0]
    }

    /// "1", "1.25" — no × suffix; the speed-selector segments are too narrow for it.
    static func bareSpeedLabel(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))" : "\(s)"
    }

    @State private var showAllVoiceLanguages = false
    // AVSpeechSynthesisVoice.speechVoices() enumerates every installed system TTS voice — a well
    // documented slow AVFoundation call. It used to be re-run from scratch inside a plain computed
    // property, so it fired on EVERY body re-evaluation of this sheet, i.e. on every single
    // setting changed anywhere on the page (not just the voice picker) — the concrete lag. Voices
    // installed on the device don't change while this sheet is open, so fetch once and cache.
    @State private var allVoices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if podcast.isLocal {
                        section("Article Voice") { voiceSection }
                    }
                    section("Playback") {
                        speedOverrideRow
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Voice Boost").scaledFont(16).foregroundStyle(theme.color(.text))
                            SegmentedRow(options: [("Default", -1), ("Off", 0), ("Med", 1), ("High", 2)],
                                         selection: s.voiceBoost ?? -1) {
                                s.voiceBoost = $0 == -1 ? nil : $0; playback.applyAudioSettings()
                            }
                            defaultCaption(["Off", "Med", "High"][appSettings.defaultVoiceBoost],
                                           shown: s.voiceBoost == nil)
                        }
                        boolOverridePicker("Skip Silence",
                                           defaultHint: appSettings.defaultSkipSilence ? "On" : "Off",
                                           value: Binding(get: { s.skipSilence },
                                                          set: { s.skipSilence = $0; playback.applyAudioSettings() }))
                    }
                    section("Ads & Downloads") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ad Skip").scaledFont(16).foregroundStyle(theme.color(.text))
                            SegmentedRow(options: [("Default", "default"), ("Off", "off"),
                                                   ("Manual", "manual"), ("Auto", "auto")],
                                         selection: s.adSkipMode ?? "default") {
                                s.adSkipMode = $0 == "default" ? nil : $0
                            }
                            defaultCaption(appSettings.defaultAdSkipMode.capitalized,
                                           shown: s.adSkipMode == nil)
                        }
                        boolOverridePicker("Auto-Download New Episodes",
                                           defaultHint: appSettings.defaultAutoDownload ? "On" : "Off",
                                           value: Binding(get: { s.autoDownload },
                                                          set: { s.autoDownload = $0 }))
                    }
                    section("Trim Episode") {
                        stepperRow("Skip Intro", value: Binding(get: { s.introTrimSec }, set: { s.introTrimSec = $0 }))
                        stepperRow("Skip Outro", value: Binding(get: { s.outroTrimSec }, set: { s.outroTrimSec = $0 }))
                    }
                    section("Downloads & Retention") {
                        overridePicker("Limit Downloads Kept",
                                       state: overrideState(s.maxDownloadsKeptOverride, offValue: 0),
                                       offLabel: "No limit",
                                       defaultHint: appSettings.defaultMaxDownloadsKept == 0
                                           ? "No limit" : "\(appSettings.defaultMaxDownloadsKept) per show") { mode in
                            s.maxDownloadsKeptOverride = [nil, 0, 10][mode]
                        }
                        if let cap = s.maxDownloadsKeptOverride, cap > 0 {
                            countStepper("Keep per show",
                                         value: Binding(get: { cap },
                                                        set: { s.maxDownloadsKeptOverride = $0 }),
                                         range: 1 ... 50, label: { "\($0)" })
                        }
                        overridePicker("Delete Played Episodes",
                                       state: overrideState(s.autoDeleteListenedAfterDaysOverride, offValue: -1),
                                       offLabel: "Never",
                                       defaultHint: autoDeleteDefaultHint) { mode in
                            s.autoDeleteListenedAfterDaysOverride = [nil, -1, 7][mode]
                        }
                        if let days = s.autoDeleteListenedAfterDaysOverride, days >= 0 {
                            countStepper("After",
                                         value: Binding(get: { days },
                                                        set: { s.autoDeleteListenedAfterDaysOverride = $0 }),
                                         range: 0 ... 30,
                                         label: { $0 == 0 ? "When finished" : "After \($0) day\($0 == 1 ? "" : "s")" })
                        }
                        boolOverridePicker("Auto-Transcribe Downloads",
                                           defaultHint: appSettings.defaultAutoTranscribeOnDownload ? "On" : "Off",
                                           value: Binding(get: { s.autoTranscribeOnDownloadOverride },
                                                          set: { s.autoTranscribeOnDownloadOverride = $0 }))
                        boolOverridePicker("Keep Transcripts After Delete",
                                           defaultHint: appSettings.keepTranscriptsOnDelete ? "On" : "Off",
                                           value: Binding(get: { s.keepTranscriptsOverride },
                                                          set: { s.keepTranscriptsOverride = $0 }))
                    }
                }
                .padding(20)
            }
            .background(theme.color(.bg))
            .navigationTitle(podcast.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                // Local/article shows only — this is where voiceSection (and availableVoices)
                // actually renders. Fetch once; re-running would defeat the point of the cache.
                guard podcast.isLocal, allVoices.isEmpty else { return }
                allVoices = AVSpeechSynthesisVoice.speechVoices()
            }
        }
    }

    // Speed override: Default inherits the global; Custom reveals a DIRECT selector of every
    // step — one tap to any speed (the old cycle button needed up to five taps to come around).
    private var speedOverrideRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speed").scaledFont(16).foregroundStyle(theme.color(.text))
            SegmentedRow(options: [("Default", 0), ("Custom", 1)],
                         selection: s.speed == nil ? 0 : 1) {
                s.speed = $0 == 0 ? nil : Self.customSpeedSeed(from: appSettings.defaultSpeed)
                playback.applyAudioSettings()
            }
            if s.speed != nil {
                // Bare numbers (no ×) so the selected segment fits its checkmark without
                // truncating ("✓ 1.2…") in six narrow segments.
                SegmentedRow(options: Self.speedSteps.map { (Self.bareSpeedLabel($0), $0) },
                             selection: s.speed ?? appSettings.defaultSpeed) {
                    s.speed = $0
                    playback.applyAudioSettings()
                }
            }
            defaultCaption(NowPlayingView.speedText(appSettings.defaultSpeed), shown: s.speed == nil)
        }
    }

    private var autoDeleteDefaultHint: String {
        let d = appSettings.defaultAutoDeleteListenedAfterDays
        if d < 0 { return "Off" }
        if d == 0 { return "Immediately" }
        return "\(d) day\(d == 1 ? "" : "s")"
    }

    /// nil → 0 (inherit default), the sentinel offValue → 1 (explicit off), anything else → 2 (custom).
    private func overrideState(_ value: Int?, offValue: Int) -> Int {
        guard let value else { return 0 }
        return value == offValue ? 1 : 2
    }

    /// Three-way override control: 0 = inherit default, 1 = explicit off/unlimited, 2 = custom.
    private func overridePicker(_ title: String, state: Int, offLabel: String,
                                defaultHint: String,
                                onChange: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).scaledFont(16).foregroundStyle(theme.color(.text))
            SegmentedRow(options: [("Default", 0), (offLabel, 1), ("Custom", 2)],
                         selection: state, onChange: onChange)
            defaultCaption(defaultHint, shown: state == 0)
        }
    }

    private func boolOverridePicker(_ title: String, defaultHint: String,
                                    value: Binding<Bool?>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).scaledFont(16).foregroundStyle(theme.color(.text))
            SegmentedRow(options: [("Default", 0), ("Off", 1), ("On", 2)],
                         selection: value.wrappedValue == nil ? 0 : (value.wrappedValue == false ? 1 : 2)) {
                value.wrappedValue = [nil, false, true][$0]
            }
            defaultCaption(defaultHint, shown: value.wrappedValue == nil)
        }
    }

    // Spells out what "Default" resolves to (from the global settings) while that segment is active,
    // so "Default" isn't an opaque choice.
    @ViewBuilder private func defaultCaption(_ hint: String, shown: Bool) -> some View {
        if shown {
            Text("Default: \(hint)").scaledFont(12).foregroundStyle(theme.color(.textTertiary))
        }
    }

    private func countStepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>,
                              label: (Int) -> String) -> some View {
        HStack {
            Text(title).scaledFont(14).foregroundStyle(theme.color(.textSecondary))
            Spacer()
            stepButton("−", "Decrease \(title)") {
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1)
            }
            Text(label(value.wrappedValue)).monospacedDigit().frame(minWidth: 88)
                .scaledFont(14, weight: .semibold).foregroundStyle(theme.color(.text))
            stepButton("+", "Increase \(title)") {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + 1)
            }
        }
    }

    private func stepButton(_ glyph: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).scaledFont(20, weight: .semibold)
                .foregroundStyle(theme.color(.accent))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
            content()
        }
    }

    private func row(_ title: String, @ViewBuilder _ trailing: () -> some View) -> some View {
        HStack { Text(title).scaledFont(16).foregroundStyle(theme.color(.text)); Spacer(); trailing() }
    }

    private func stepperRow(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title).scaledFont(16).foregroundStyle(theme.color(.text)); Spacer()
            stepButton("−", "Decrease \(title)") { value.wrappedValue = max(0, value.wrappedValue - 5) }
            Text("\(value.wrappedValue)s").monospacedDigit().frame(minWidth: 44)
                .scaledFont(16, weight: .semibold).foregroundStyle(theme.color(.text))
            stepButton("+", "Increase \(title)") { value.wrappedValue = min(60, value.wrappedValue + 5) }
        }
    }

    private var availableVoices: [AVSpeechSynthesisVoice] {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let filtered = showAllVoiceLanguages ? allVoices : allVoices.filter { $0.language.hasPrefix(lang) }
        return filtered.sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }

    @ViewBuilder private var voiceSection: some View {
        row("Voice") {
            Menu {
                Picker("Voice", selection: Binding(
                    get: { s.ttsVoiceIdentifier ?? "" },
                    set: { s.ttsVoiceIdentifier = $0.isEmpty ? nil : $0 }
                )) {
                    Text("System Default").tag("")
                    ForEach(availableVoices, id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                    }
                }
            } label: {
                Text(selectedVoiceName)
                    .scaledFont(15, weight: .bold).foregroundStyle(theme.color(.text))
            }
        }
        Toggle("All Languages", isOn: $showAllVoiceLanguages)
            .tint(theme.color(.accent)).foregroundStyle(theme.color(.text))
        Text("New articles are narrated with this voice. Already-converted episodes keep theirs.")
            .scaledFont(12).foregroundStyle(theme.color(.textTertiary))
    }

    private var selectedVoiceName: String {
        guard let id = s.ttsVoiceIdentifier,
              let voice = AVSpeechSynthesisVoice(identifier: id) else { return "System Default" }
        return voice.name
    }
}
