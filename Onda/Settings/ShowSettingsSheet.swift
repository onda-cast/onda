//  ShowSettingsSheet.swift
import SwiftUI

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
    private let speedSteps: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("Playback") {
                        row("Speed") {
                            Button(speedLabel) { cycleSpeed() }
                                .scaledFont(15, weight: .bold).foregroundStyle(theme.color(.text))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Voice Boost").scaledFont(16).foregroundStyle(theme.color(.text))
                            SegmentedRow(options: [("Off", 0), ("Med", 1), ("High", 2)],
                                         selection: s.voiceBoost) { s.voiceBoost = $0; playback.applyAudioSettings() }
                        }
                        Toggle("Skip Silence", isOn: Binding(
                            get: { s.skipSilence }, set: { s.skipSilence = $0; playback.applyAudioSettings() }))
                            .tint(theme.color(.accent)).foregroundStyle(theme.color(.text))
                    }
                    section("Ads & Downloads") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ad Skip").scaledFont(16).foregroundStyle(theme.color(.text))
                            SegmentedRow(options: [("Off", "off"), ("Manual", "manual"), ("Auto", "auto")],
                                         selection: s.adSkipMode) { s.adSkipMode = $0 }
                        }
                        Toggle("Auto-Download New Episodes", isOn: Binding(
                            get: { s.autoDownload }, set: { s.autoDownload = $0 }))
                            .tint(theme.color(.accent)).foregroundStyle(theme.color(.text))
                    }
                    section("Trim Episode") {
                        stepperRow("Skip Intro", value: Binding(get: { s.introTrimSec }, set: { s.introTrimSec = $0 }))
                        stepperRow("Skip Outro", value: Binding(get: { s.outroTrimSec }, set: { s.outroTrimSec = $0 }))
                    }
                    section("Downloads & Retention") {
                        overridePicker("Keep Downloads",
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
                                         range: 1...50, label: { "\($0)" })
                        }
                        overridePicker("Auto-Delete Listened",
                                       state: overrideState(s.autoDeleteListenedAfterDaysOverride, offValue: -1),
                                       offLabel: "Off",
                                       defaultHint: autoDeleteDefaultHint) { mode in
                            s.autoDeleteListenedAfterDaysOverride = [nil, -1, 7][mode]
                        }
                        if let days = s.autoDeleteListenedAfterDaysOverride, days >= 0 {
                            countStepper("After",
                                         value: Binding(get: { days },
                                                        set: { s.autoDeleteListenedAfterDaysOverride = $0 }),
                                         range: 0...30,
                                         label: { $0 == 0 ? "Immediately" : "\($0) day\($0 == 1 ? "" : "s")" })
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
        }
    }

    private var speedLabel: String {
        let sp = s.speed
        return sp == sp.rounded() ? "\(Int(sp))×" : "\(sp)×"
    }

    private func cycleSpeed() {
        let i = speedSteps.firstIndex(of: s.speed) ?? 1
        s.speed = speedSteps[(i + 1) % speedSteps.count]
        playback.applyAudioSettings()
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
    @ViewBuilder private func overridePicker(_ title: String, state: Int, offLabel: String,
                                             defaultHint: String,
                                             onChange: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).scaledFont(16).foregroundStyle(theme.color(.text))
            SegmentedRow(options: [("Default", 0), (offLabel, 1), ("Custom", 2)],
                         selection: state, onChange: onChange)
            defaultCaption(defaultHint, shown: state == 0)
        }
    }

    @ViewBuilder private func boolOverridePicker(_ title: String, defaultHint: String,
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

    @ViewBuilder private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
            content()
        }
    }
    @ViewBuilder private func row(_ title: String, @ViewBuilder _ trailing: () -> some View) -> some View {
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
}
