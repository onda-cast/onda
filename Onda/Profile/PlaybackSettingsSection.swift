//  PlaybackSettingsSection.swift
//  Global playback defaults + nitpicky details shown in ProfileView. Per-show overrides live
//  in ShowSettingsSheet; these are the values a show inherits when it has no override.
import SwiftUI

struct PlaybackSettingsSection: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppSettings.self) private var appSettings
    @Environment(PlaybackManager.self) private var playback

    private static let speedSteps: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    private static let seekChoices = [10, 15, 30, 45, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playback").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
            BrutalCard {
                VStack(alignment: .leading, spacing: 0) {
                    labeledRow("Speed") {
                        Button(NowPlayingView.speedText(appSettings.defaultSpeed)) { cycleSpeed() }
                            .scaledFont(15, weight: .bold).foregroundStyle(theme.color(.text))
                    }
                    divider
                    segmented("Voice Boost", options: [("Off", 0), ("Med", 1), ("High", 2)],
                              selection: appSettings.defaultVoiceBoost) {
                        appSettings.defaultVoiceBoost = $0; playback.applyAudioSettings()
                    }
                    divider
                    toggleRow("Skip Silence", isOn: Binding(
                        get: { appSettings.defaultSkipSilence },
                        set: { appSettings.defaultSkipSilence = $0; playback.applyAudioSettings() }
                    ))
                    divider
                    segmented("Ad Skip", options: [("Off", "off"), ("Manual", "manual"), ("Auto", "auto")],
                              selection: appSettings.defaultAdSkipMode) { appSettings.defaultAdSkipMode = $0 }
                    divider
                    segmented("Skip Forward", options: Self.seekChoices.map { ("\($0)s", $0) },
                              selection: appSettings.seekForwardSec) {
                        appSettings.seekForwardSec = $0; playback.refreshSkipIntervals()
                    }
                    divider
                    segmented("Skip Back", options: Self.seekChoices.map { ("\($0)s", $0) },
                              selection: appSettings.seekBackSec) {
                        appSettings.seekBackSec = $0; playback.refreshSkipIntervals()
                    }
                    divider
                    toggleRow("Smart Resume", subtitle: "Rewind a little after a break",
                              isOn: Binding(get: { appSettings.smartResumeEnabled },
                                            set: { appSettings.smartResumeEnabled = $0 }))
                    divider
                    toggleRow("Autoplay Next", subtitle: "Continue to the queue when an episode ends",
                              isOn: Binding(get: { appSettings.autoplayNext },
                                            set: { appSettings.autoplayNext = $0 }))
                    divider
                    toggleRow("Seek Acceleration", subtitle: "Repeated skips jump farther",
                              isOn: Binding(get: { appSettings.seekAccelerationEnabled },
                                            set: { appSettings.seekAccelerationEnabled = $0 }))
                }
                .padding(16)
            }
        }
    }

    private func cycleSpeed() {
        let steps = Self.speedSteps
        let i = steps.firstIndex(of: appSettings.defaultSpeed) ?? 1
        appSettings.defaultSpeed = steps[(i + 1) % steps.count]
        playback.applyAudioSettings()
    }

    private var divider: some View {
        Rectangle().fill(theme.color(.separator)).frame(height: 1).padding(.vertical, 12)
    }

    private func labeledRow(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(title).scaledFont(15, weight: .semibold).foregroundStyle(theme.color(.text))
            Spacer()
            trailing()
        }
    }

    private func segmented<V: Hashable>(_ title: String, options: [(String, V)],
                                        selection: V, onChange: @escaping (V) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).scaledFont(15, weight: .semibold).foregroundStyle(theme.color(.text))
            SegmentedRow(options: options, selection: selection, onChange: onChange)
        }
    }

    private func toggleRow(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(15, weight: .semibold)
                    .foregroundStyle(theme.color(.text))
                if let subtitle {
                    Text(subtitle).scaledFont(12).foregroundStyle(theme.color(.textTertiary))
                }
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().tint(theme.color(.accent))
        }
    }
}
