//  ShowSettingsSheet.swift
import SwiftUI

struct ShowSettingsSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(PlaybackManager.self) private var playback
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
                                .font(.system(size: 15, weight: .bold)).foregroundStyle(theme.color(.text))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Voice Boost").font(.system(size: 16)).foregroundStyle(theme.color(.text))
                            SegmentedRow(options: [("Off", 0), ("Med", 1), ("High", 2)],
                                         selection: s.voiceBoost) { s.voiceBoost = $0; playback.applyAudioSettings() }
                        }
                        Toggle("Skip Silence", isOn: Binding(
                            get: { s.skipSilence }, set: { s.skipSilence = $0; playback.applyAudioSettings() }))
                            .tint(theme.color(.accent)).foregroundStyle(theme.color(.text))
                    }
                    section("Ads & Downloads") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ad Skip").font(.system(size: 16)).foregroundStyle(theme.color(.text))
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
                    section("Notifications") {
                        SegmentedRow(options: [("All", "all"), ("Important", "important"), ("None", "none")],
                                     selection: s.notifMode) { s.notifMode = $0 }
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

    @ViewBuilder private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
            content()
        }
    }
    @ViewBuilder private func row(_ title: String, @ViewBuilder _ trailing: () -> some View) -> some View {
        HStack { Text(title).font(.system(size: 16)).foregroundStyle(theme.color(.text)); Spacer(); trailing() }
    }
    private func stepperRow(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title).font(.system(size: 16)).foregroundStyle(theme.color(.text)); Spacer()
            Button("−") { value.wrappedValue = max(0, value.wrappedValue - 5) }
            Text("\(value.wrappedValue)s").monospacedDigit().frame(minWidth: 44)
                .foregroundStyle(theme.color(.text))
            Button("+") { value.wrappedValue = min(60, value.wrappedValue + 5) }
        }
        .foregroundStyle(theme.color(.accent)).font(.system(size: 18, weight: .semibold))
    }
}
