//  NowPlayingView.swift
import SwiftUI

struct NowPlayingView: View {
    @Environment(PlaybackManager.self) private var playback
    @Environment(AppTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false

    private var ep: Episode? { playback.currentEpisode }
    private var settings: ShowSettings? { ep?.podcast?.settings }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                if let ep {
                    ArtworkView(url: ep.podcast?.artworkURL, seed: ep.podcast?.title ?? ep.title)
                        .frame(maxWidth: 280).aspectRatio(1, contentMode: .fit)
                        .hardShadow(offset: 8)
                    Text(ep.title).brutalHeader(size: 19).multilineTextAlignment(.center)
                        .foregroundStyle(theme.color(.text))
                    Text(ep.podcast?.title ?? "").font(.system(size: 15, weight: .bold))
                        .textCase(.uppercase).foregroundStyle(theme.color(.accent))
                    scrubber
                    transport
                    chips
                    chapterList(ep)
                    about(ep)
                }
            }
            .padding(.horizontal, 32).padding(.top, 60).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .background(theme.color(.bg).ignoresSafeArea())
        .sheet(isPresented: $showQueue) { QueueView() }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.system(size: 16, weight: .bold)) }
            Spacer()
            SleepTimerMenu()
            Button { showQueue = true } label: { Image(systemName: "list.bullet").font(.system(size: 16, weight: .bold)) }
        }
        .foregroundStyle(theme.color(.textSecondary))
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(
                get: { playback.progressFraction },
                set: { playback.seek(toFraction: $0) }), in: 0...1)
            .tint(theme.color(.accent))
            HStack {
                Text(timeStr(playback.positionSeconds))
                Spacer()
                Text("-" + timeStr(max(0, playback.durationSeconds - playback.positionSeconds)))
            }
            .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(theme.color(.textTertiary))
        }
        .frame(maxWidth: 280)
    }

    private var transport: some View {
        HStack(spacing: 26) {
            Button { playback.skip(by: -15) } label: { skipLabel("gobackward.15") }
            Button { playback.togglePlayPause() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44)).foregroundStyle(.white)
                    .frame(width: 120, height: 120).background(theme.color(.accent))
                    .brutalBorder(width: 3).hardShadow(offset: 6)
            }
            Button { playback.skip(by: 30) } label: { skipLabel("goforward.30") }
        }.buttonStyle(.plain)
    }

    private func skipLabel(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(theme.color(.text))
            .frame(width: 76, height: 76).background(theme.color(.bgElevated)).brutalBorder(width: 2.5)
    }

    // Speed cycles; Boost/Skip-Silence toggle ShowSettings (audio effect wired in Plan 4).
    private var chips: some View {
        HStack(spacing: 10) {
            Button { cycleSpeed() } label: { chip(speedLabel, active: false) }
            Button { toggleBoost() } label: {
                chip("Boost: \(boostLabel)", active: (settings?.voiceBoost ?? 0) > 0)
            }
            Button { toggleSilence() } label: {
                chip(settings?.skipSilence == true ? "No Silence" : "Silence On",
                     active: settings?.skipSilence == true)
            }
        }
    }

    private func chip(_ text: String, active: Bool) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold))
            .foregroundStyle(active ? theme.color(.accent) : theme.color(.text))
            .padding(.horizontal, 20).padding(.vertical, 13)
            .background(active ? theme.color(.accentWash) : theme.color(.bgElevated))
            .brutalBorder(width: 2)
    }

    private var speedLabel: String {
        let s = settings?.speed ?? 1.0
        return s == s.rounded() ? "\(Int(s))×" : "\(s)×"
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
                                Text(ch.title).font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(theme.color(.text))
                                Spacer()
                                Text(timeStr(ch.startTime)).font(.system(size: 12.5)).monospacedDigit()
                                    .foregroundStyle(theme.color(.textTertiary))
                            }.padding(.vertical, 10)
                        }.buttonStyle(.plain)
                        Divider().overlay(theme.color(.separator))
                    }
                }.frame(maxWidth: 280)
            }
        }
    }

    private func about(_ ep: Episode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About This Episode").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
            Text(ep.notes).font(.system(size: 14.5)).foregroundStyle(theme.color(.textSecondary))
        }.frame(maxWidth: 280, alignment: .leading)
    }

    private func cycleSpeed() {
        let steps: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
        guard let s = settings else { return }
        let i = steps.firstIndex(of: s.speed) ?? 1
        s.speed = steps[(i + 1) % steps.count]
    }
    private func toggleBoost() { settings.map { $0.voiceBoost = ($0.voiceBoost + 1) % 3 } }
    private func toggleSilence() { settings.map { $0.skipSilence.toggle() } }

    private func timeStr(_ s: TimeInterval) -> String {
        let t = Int(max(0, s)); return String(format: "%d:%02d", t / 60, t % 60)
    }
}
