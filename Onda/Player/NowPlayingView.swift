//  NowPlayingView.swift
import SwiftUI

struct NowPlayingView: View {
    @Environment(PlaybackManager.self) private var playback
    @Environment(AppTheme.self) private var theme
    @Environment(DownloadManager.self) private var downloads
    @Environment(ChapterGenerationService.self) private var chapterGen
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var showSettings = false
    @State private var showTranscript = false
    @State private var showJumpToTime = false
    @State private var jumpText = ""

    private var ep: Episode? { playback.currentEpisode }
    private var settings: ShowSettings? { ep?.podcast?.settings }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let ep {
                    ArtworkView(url: ep.podcast?.artworkURL, seed: ep.podcast?.title ?? ep.title)
                        .frame(maxWidth: 240).aspectRatio(1, contentMode: .fit)
                        .hardShadow(offset: 8)
                    Text(ep.title).brutalHeader(size: 18).multilineTextAlignment(.center)
                        .foregroundStyle(theme.color(.text))
                    Text(ep.podcast?.title ?? "").scaledFont(15, weight: .bold)
                        .textCase(.uppercase).foregroundStyle(theme.color(.accent))
                    if playback.adActive {
                        adBanner(ep)
                    }
                    chips
                    chapterList(ep)
                    about(ep)
                }
            }
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
        // Header pinned so the transcript/queue/settings actions never scroll away.
        .safeAreaInset(edge: .top) {
            header
                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
                .background(theme.color(.bg))
        }
        // Scrubber + transport pinned: always on screen regardless of device height.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 14) {
                scrubber
                transport
            }
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(theme.color(.bg))
        }
        .background(theme.color(.bg).ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let toast = playback.captureToast {
                Text(toast)
                    .scaledFont(13.5, weight: .semibold).foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(theme.color(.accent)).brutalBorder(width: 2)
                    .padding(.bottom, 30)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if playback.returnToTranscriptEpisode != nil {
                BackToTranscriptButton {
                    playback.clearTranscriptReturn()
                    showTranscript = true
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: playback.captureToast)
        .animation(.easeOut(duration: 0.2), value: playback.returnToTranscriptEpisode?.guid)
        .sheet(isPresented: $showQueue) { QueueView() }
        .sheet(isPresented: $showSettings) {
            if let pod = ep?.podcast { ShowSettingsSheet(podcast: pod) }
        }
        .sheet(isPresented: $showTranscript) {
            if let ep { TranscriptView(episode: ep) }
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Button { dismiss() } label: { headerIcon("chevron.down") }
            Spacer()
            SleepTimerMenu()
            Button { showTranscript = true } label: { headerIcon("text.quote") }
                .accessibilityIdentifier("transcript-button")
            Button { showQueue = true } label: { headerIcon("list.bullet") }
            Button { showSettings = true } label: { headerIcon("ellipsis") }
        }
        .foregroundStyle(theme.color(.textSecondary))
    }

    // Download progress of the current episode, while it's actively downloading.
    private var downloadFraction: Double? {
        guard let ep, case .downloading(let p) = downloads.state(for: ep) else { return nil }
        return p
    }

    // Sized for the smallest supported screens (375pt wide): 60 + 96 + 60 + spacing + padding.
    private var transport: some View {
        HStack(spacing: 20) {
            Button { playback.skip(by: -15) } label: { skipLabel("gobackward.15") }
                .accessibilityLabel("Skip back 15 seconds")
            Button { playback.togglePlayPause() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .scaledFont(36).foregroundStyle(.white)
                    .frame(width: 96, height: 96).background(theme.color(.accent))
                    .brutalBorder(width: 3).hardShadow(offset: 5)
            }
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            Button { playback.skip(by: 30) } label: { skipLabel("goforward.30") }
                .accessibilityLabel("Skip forward 30 seconds")
        }.buttonStyle(.plain)
    }

    private func skipLabel(_ symbol: String) -> some View {
        Image(systemName: symbol).scaledFont(24).foregroundStyle(theme.color(.text))
            .frame(width: 60, height: 60).background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
    }

    // Speed cycles; Boost/Skip-Silence toggle ShowSettings (audio effect wired in Plan 4).
    // Horizontal scroller: label widths change ("1×" → "1.25×") and must never squish neighbors.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // Tap cycles through speeds; long-press opens a menu to pick one directly.
                Button { cycleSpeed() } label: { chip(speedLabel, active: (settings?.speed ?? 1) != 1) }
                    .contextMenu {
                        ForEach(Self.speedSteps, id: \.self) { sp in
                            Button { setSpeed(sp) } label: {
                                if settings?.speed == sp {
                                    Label(Self.speedText(sp), systemImage: "checkmark")
                                } else {
                                    Text(Self.speedText(sp))
                                }
                            }
                        }
                    }
                Button { toggleBoost() } label: {
                    chip("Boost: \(boostLabel)", active: (settings?.voiceBoost ?? 0) > 0)
                }
                Button { toggleSilence() } label: {
                    chip(settings?.skipSilence == true ? "No Silence" : "Silence On",
                         active: settings?.skipSilence == true)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity)
    }

    // Compact enough that all three chips fit a 375pt screen at the longest labels
    // ("1.25×", "Boost: High", "Silence On"); the scroller is a safety net, not the norm.
    private func chip(_ text: String, active: Bool) -> some View {
        Text(text).scaledFont(13.5, weight: .semibold)
            .lineLimit(1).fixedSize()
            .foregroundStyle(active ? theme.color(.accent) : theme.color(.text))
            .padding(.horizontal, 13).padding(.vertical, 11)
            .background(active ? theme.color(.accentWash) : theme.color(.bgElevated))
            .brutalBorder(width: 2)
    }

    private var speedLabel: String { Self.speedText(settings?.speed ?? 1.0) }
    static func speedText(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))×" : "\(s)×"
    }
    private var boostLabel: String { ["Off", "Med", "High"][settings?.voiceBoost ?? 0] }

    private func chapterList(_ ep: Episode) -> some View {
        Group {
            if !ep.chapters.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Chapters").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
                    ForEach(ep.chapters.sorted { $0.startTime < $1.startTime }, id: \.startTime) { ch in
                        Button { playback.seek(toFraction: ch.startTime / max(1, ep.duration)) } label: {
                            HStack {
                                Text(ch.title).scaledFont(14.5, weight: .semibold)
                                    .foregroundStyle(theme.color(.text))
                                Spacer()
                                Text(timeStr(ch.startTime)).scaledFont(12.5).monospacedDigit()
                                    .foregroundStyle(theme.color(.textTertiary))
                            }.padding(.vertical, 10)
                        }.buttonStyle(.plain)
                        Divider().overlay(theme.color(.separator))
                    }
                }.frame(maxWidth: 280)
            } else if chapterGen.canGenerate(ep) {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task { _ = await chapterGen.generate(for: ep) }
                    } label: {
                        Text(chapterGen.isGenerating[ep.guid] == true ? "Generating…" : "Generate chapters")
                            .scaledFont(13, weight: .bold).foregroundStyle(theme.color(.accent))
                    }
                    .disabled(chapterGen.isGenerating[ep.guid] == true)
                    if let failure = chapterGen.lastFailure[ep.guid] {
                        Text(failure).scaledFont(12).foregroundStyle(.red)
                    }
                }.frame(maxWidth: 280)
            }
        }
    }

    private func adBanner(_ ep: Episode) -> some View {
        HStack {
            Text(settings?.adSkipMode == "auto" ? "Skipping ad…" : "Ad break in progress")
                .scaledFont(13, weight: .semibold)
                .foregroundStyle(theme.color(.text))
            Spacer()
            if settings?.adSkipMode == "manual" {
                Button("Skip Ad") {
                    let w = AdWindow(chapters: ep.chapters.map { ($0.startTime, $0.isAd) },
                                     duration: ep.duration)
                    if let end = w.adEnd(at: playback.positionSeconds) {
                        playback.seek(toFraction: end / max(1, ep.duration))
                    }
                }
                .scaledFont(13, weight: .bold)
                .foregroundStyle(theme.color(.accent))
            }
        }
        .padding(12).background(theme.color(.accentWash)).brutalBorder(width: 2)
        .frame(maxWidth: 280)
    }

    private func about(_ ep: Episode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About This Episode").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
            Text(ep.notes).scaledFont(14.5).foregroundStyle(theme.color(.textSecondary))
        }.frame(maxWidth: 280, alignment: .leading)
    }

}

// MARK: - Scrubber
extension NowPlayingView {
    var scrubber: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(
                get: { playback.progressFraction },
                set: { playback.seek(toFraction: $0) }), in: 0...1)
            .tint(theme.color(.accent))
            // A still hold opens type-a-timecode; an actual drag moves >10pt, which cancels the
            // long press, so normal scrubbing is unaffected.
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                jumpText = ""
                showJumpToTime = true
            })
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(timeStr(playback.positionSeconds)) of \(timeStr(playback.durationSeconds))")
            .accessibilityHint("Long press to type a time")
            .alert("Jump to Time", isPresented: $showJumpToTime) {
                TextField("1:23:45", text: $jumpText)
                    .keyboardType(.numbersAndPunctuation)
                Button("Jump") {
                    if let t = Self.parseTimecode(jumpText) {
                        playback.seek(toFraction: t / max(1, playback.durationSeconds))
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a time like 12:34, 1:02:30, or seconds.")
            }
            if let frac = downloadFraction {
                downloadTrack(frac)
            }
            HStack {
                Text(timeStr(playback.positionSeconds))
                Spacer()
                if let frac = downloadFraction {
                    Text("Saving \(Int(frac * 100))%").foregroundStyle(theme.color(.accent))
                    Spacer()
                }
                Text("-" + timeStr(max(0, playback.durationSeconds - playback.positionSeconds)))
            }
            .scaledFont(12.5).monospacedDigit().foregroundStyle(theme.color(.textTertiary))
        }
        .frame(maxWidth: 280)
        .animation(.easeInOut(duration: 0.2), value: downloadFraction == nil)
    }

    // Buffered-style track under the scrubber: fills as the offline copy downloads, then vanishes.
    private func downloadTrack(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.color(.separator))
                Capsule().fill(theme.color(.accent).opacity(0.55))
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
            }
        }
        .frame(height: 3)
        .padding(.top, 2)
    }
}

// MARK: - Audio-effect chips
extension NowPlayingView {
    /// Parses a typed timecode: "SS" (plain seconds, any size), "MM:SS", or "HH:MM:SS".
    /// Sub-parts after the first must be 0–59. Returns nil for anything malformed.
    static func parseTimecode(_ input: String) -> TimeInterval? {
        let parts = input.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var values: [Int] = []
        for (i, raw) in parts.enumerated() {
            guard !raw.isEmpty, let v = Int(raw), v >= 0 else { return nil }
            if i > 0, v > 59 { return nil }   // minutes/seconds fields must be 0–59
            values.append(v)
        }
        return TimeInterval(values.reduce(0) { $0 * 60 + $1 })
    }

    // Bigger glyph + a full 44pt tap target — the header controls were cramped and hard to hit.
    func headerIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).scaledFont(18, weight: .bold)
            .frame(width: 44, height: 44).contentShape(Rectangle())
    }

    static let speedSteps: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    /// Tap: advance to the next speed step (wrapping).
    func cycleSpeed() {
        guard let s = settings else { return }
        let steps = Self.speedSteps
        let i = steps.firstIndex(of: s.speed) ?? 1
        setSpeed(steps[(i + 1) % steps.count])
    }

    /// Long-press menu: jump straight to a chosen speed.
    func setSpeed(_ speed: Double) {
        settings?.speed = speed
        playback.applyAudioSettings()
    }
    func toggleBoost() {
        settings.map { $0.voiceBoost = ($0.voiceBoost + 1) % 3 }
        playback.applyAudioSettings()
    }
    func toggleSilence() {
        settings.map { $0.skipSilence.toggle() }
        playback.applyAudioSettings()
    }

    func timeStr(_ s: TimeInterval) -> String {
        let t = Int(max(0, s)); return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Floating affordance shown briefly in the player after a transcript jump, to hop back.
private struct BackToTranscriptButton: View {
    @Environment(AppTheme.self) private var theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward").scaledFont(13, weight: .bold)
                Text("Back to transcript").scaledFont(13.5, weight: .bold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(theme.color(.accent)).brutalBorder(width: 2).hardShadow(offset: 3)
        }
        .buttonStyle(.plain)
        .padding(.top, 112)   // clear the pinned header row
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
