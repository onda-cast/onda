//  RetentionSettingsSection.swift
//  Global download/retention defaults shown in ProfileView. Per-show overrides live in
//  ShowSettingsSheet; these are the values a show inherits when it has no override.
import SwiftUI

struct RetentionSettingsSection: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Downloads & Retention").brutalHeader(size: 13)
                .foregroundStyle(theme.color(.textTertiary))

            BrutalCard {
                VStack(spacing: 0) {
                    toggleRow("Wi-Fi only downloads", subtitle: "Never download over cellular",
                              isOn: Binding(
                                get: { appSettings.wifiOnlyDownloads },
                                set: { appSettings.wifiOnlyDownloads = $0 }))
                    divider
                    toggleRow("Limit downloads kept", subtitle: "Oldest played episodes are removed first",
                              isOn: Binding(
                                get: { appSettings.defaultMaxDownloadsKept > 0 },
                                set: { appSettings.defaultMaxDownloadsKept = $0 ? 10 : 0 }))
                    if appSettings.defaultMaxDownloadsKept > 0 {
                        stepperRow("Keep per show",
                                   value: Binding(get: { appSettings.defaultMaxDownloadsKept },
                                                  set: { appSettings.defaultMaxDownloadsKept = $0 }),
                                   range: 1...50, label: { "\($0)" })
                    }
                    divider
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Delete played episodes").scaledFont(15, weight: .semibold)
                            .foregroundStyle(theme.color(.text))
                        SegmentedRow(options: [("Never", -1), ("Done", 0), ("1 day", 1), ("Custom", 7)],
                                     selection: deletePlayedPreset) {
                            appSettings.defaultAutoDeleteListenedAfterDays = $0
                        }
                        if appSettings.defaultAutoDeleteListenedAfterDays > 1 {
                            stepperRow("After",
                                       value: Binding(get: { appSettings.defaultAutoDeleteListenedAfterDays },
                                                      set: { appSettings.defaultAutoDeleteListenedAfterDays = $0 }),
                                       range: 2...30, label: { "\($0) days" })
                        }
                    }
                    divider
                    toggleRow("Auto-transcribe downloads",
                              subtitle: "On-device, when no transcript is published",
                              isOn: Binding(
                                get: { appSettings.defaultAutoTranscribeOnDownload },
                                set: { appSettings.defaultAutoTranscribeOnDownload = $0 }))
                    divider
                    toggleRow("Keep transcripts of deleted episodes",
                              subtitle: "Deleted episodes stay searchable",
                              isOn: Binding(
                                get: { appSettings.keepTranscriptsOnDelete },
                                set: { appSettings.keepTranscriptsOnDelete = $0 }))
                }
                .padding(16)
            }
        }
    }

    /// Maps the stored day count onto the preset segments; any value ≥ 2 selects "Custom"
    /// (whose segment value 7 is the starting day count when tapped).
    private var deletePlayedPreset: Int {
        let d = appSettings.defaultAutoDeleteListenedAfterDays
        return d >= 2 ? 7 : d
    }

    private var divider: some View {
        Rectangle().fill(theme.color(.separator)).frame(height: 1).padding(.vertical, 12)
    }

    private func toggleRow(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(15, weight: .semibold)
                    .foregroundStyle(theme.color(.text))
                Text(subtitle).scaledFont(12).foregroundStyle(theme.color(.textTertiary))
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().tint(theme.color(.accent))
        }
    }

    private func stepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>,
                            label: (Int) -> String) -> some View {
        HStack {
            Text(title).scaledFont(14).foregroundStyle(theme.color(.textSecondary))
            Spacer()
            stepButton("−", "Decrease \(title)") {
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1)
            }
            Text(label(value.wrappedValue)).monospacedDigit().frame(minWidth: 80)
                .scaledFont(14, weight: .semibold)
                .foregroundStyle(theme.color(.text))
            stepButton("+", "Increase \(title)") {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + 1)
            }
        }
        .padding(.top, 10)
    }

    private func stepButton(_ glyph: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).scaledFont(20, weight: .semibold)
                .foregroundStyle(theme.color(.accent))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
}
