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
                                  set: { appSettings.wifiOnlyDownloads = $0 }
                              ))
                    divider
                    // The value every show's "Default" auto-download hint resolves to — it was
                    // previously unwritable anywhere in the UI.
                    toggleRow("Auto-download new episodes", subtitle: "Newest episode of each show, on refresh",
                              isOn: Binding(
                                  get: { appSettings.defaultAutoDownload },
                                  set: { appSettings.defaultAutoDownload = $0 }
                              ))
                    divider
                    // Segmented (not a bare Toggle) to match the per-show override screen's
                    // control family for the same setting — both are "Off/Custom-with-a-
                    // stepper" shaped, just without a "Default" segment here since there's
                    // nothing above the global level to inherit from.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Limit downloads kept").scaledFont(15, weight: .semibold)
                            .foregroundStyle(theme.color(.text))
                        // "Freed" (not "removed" / "deleted") because only the audio file goes —
                        // the episode itself stays in the library and can re-download. That's a
                        // different, much less destructive action than the rule below, which
                        // archives the episode out of the library entirely.
                        Text("Oldest played downloads are freed first \u{2014} episodes stay and can re-download")
                            .scaledFont(12).foregroundStyle(theme.color(.textTertiary))
                        SegmentedRow(options: [("Off", 0), ("Custom", 1)],
                                     selection: appSettings.defaultMaxDownloadsKept > 0 ? 1 : 0) {
                            appSettings.defaultMaxDownloadsKept = $0 == 0 ? 0 : 10
                        }
                        if appSettings.defaultMaxDownloadsKept > 0 {
                            stepperRow("Keep per show",
                                       value: Binding(get: { appSettings.defaultMaxDownloadsKept },
                                                      set: { appSettings.defaultMaxDownloadsKept = $0 }),
                                       range: 1 ... 50, label: { "\($0)" })
                        }
                    }
                    divider
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Delete played episodes").scaledFont(15, weight: .semibold)
                            .foregroundStyle(theme.color(.text))
                        // Unlike "Limit downloads kept" above, this removes the EPISODE from your
                        // library (not just its audio) — and, per "Keep transcripts" below, may
                        // drop its transcript too. Spelled out because the two rows sit right next
                        // to each other and look like variations on the same (reversible) action.
                        Text("Removes the episode from your library \u{2014} not just its download")
                            .scaledFont(12).foregroundStyle(theme.color(.textTertiary))
                        SegmentedRow(options: [("Never", -1), ("When finished", 0), ("1 day", 1), ("Custom", 7)],
                                     selection: deletePlayedPreset) {
                            appSettings.defaultAutoDeleteListenedAfterDays = $0
                        }
                        if appSettings.defaultAutoDeleteListenedAfterDays > 1 {
                            stepperRow("After",
                                       value: Binding(get: { appSettings.defaultAutoDeleteListenedAfterDays },
                                                      set: { appSettings.defaultAutoDeleteListenedAfterDays = $0 }),
                                       range: 2 ... 30, label: { "\($0) days" })
                        }
                    }
                    divider
                    toggleRow("Auto-transcribe downloads",
                              subtitle: "On-device, when no transcript is published",
                              isOn: Binding(
                                  get: { appSettings.defaultAutoTranscribeOnDownload },
                                  set: { appSettings.defaultAutoTranscribeOnDownload = $0 }
                              ))
                    divider
                    toggleRow("Keep transcripts of deleted episodes",
                              subtitle: "Deleted episodes stay searchable",
                              isOn: Binding(
                                  get: { appSettings.keepTranscriptsOnDelete },
                                  set: { appSettings.keepTranscriptsOnDelete = $0 }
                              ))
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
