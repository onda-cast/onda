//  TasteProfile.swift
//  The user's content-taste model, built from local signals. Weights are deliberately tiered so a
//  clip (an explicit "I loved this moment") dominates a passively-subscribed show's genre.
import Foundation
import SwiftData

struct TasteProfile: Equatable {
    var terms = TermVector()
    var categories: [String: Double] = [:]
    var authors: [String: Double] = [:]
    /// Terms safe to show a user in a "why" reason — from genres, authors, and searches, NOT raw
    /// transcript tokens (which can read like "murder, elon"). Scoring still uses `terms`.
    var displayVocabulary: Set<String> = []

    var isEmpty: Bool { terms.isEmpty && categories.isEmpty && authors.isEmpty }

    var topCategories: [String] {
        categories.sorted { $0.value > $1.value }.map(\.key)
    }
    var topAuthors: [String] {
        authors.sorted { $0.value > $1.value }.map(\.key)
    }
}

// NOT @MainActor: called from a background ModelContext (see RecommendationService.refresh) —
// it faults every subscribed show's episodes and transcript cues, which used to run on the
// main actor and could visibly hitch Discover on a library with a lot of transcribed content.
enum TasteProfileBuilder {
    // Signal weights, strongest first.
    enum Weight {
        static let clip = 6.0
        static let search = 3.0
        static let transcript = 1.5
        static let playedEpisode = 1.0
        static let showTitle = 0.75
        static let tally = 1.0        // per-subscription category/author tally
    }
    // Transcripts can be enormous; cap how much cue text feeds the profile per episode.
    static let transcriptCueCap = 120

    static func build(subscriptions: [Podcast], clips: [Clip], searchTerms: [String]) -> TasteProfile {
        var profile = TasteProfile()

        for term in searchTerms {
            profile.terms.add(text: term, weight: Weight.search)
            profile.displayVocabulary.formUnion(RecTokenizer.terms(in: term))
        }

        // Private feeds are excluded entirely: profile terms become iTunes search queries,
        // and a paid show's titles/topics shouldn't leave the device.
        for pod in subscriptions where !pod.isPrivateFeed {
            if !pod.category.isEmpty {
                profile.categories[pod.category, default: 0] += Weight.tally
                profile.displayVocabulary.formUnion(RecTokenizer.terms(in: pod.category))
            }
            if !pod.author.isEmpty {
                profile.authors[pod.author, default: 0] += Weight.tally
                profile.displayVocabulary.formUnion(RecTokenizer.terms(in: pod.author))
            }
            profile.terms.add(text: pod.title, weight: Weight.showTitle)

            for ep in pod.episodes where ep.played {
                profile.terms.add(text: ep.title, weight: Weight.playedEpisode)
            }
            // Transcript topics — the differentiated signal — sampled to stay cheap.
            for ep in pod.episodes {
                guard let cues = ep.transcript?.cues, !cues.isEmpty else { continue }
                for cue in cues.prefix(transcriptCueCap) {
                    profile.terms.add(text: cue.text, weight: Weight.transcript)
                }
            }
        }

        for clip in clips {
            profile.terms.add(text: clip.text, weight: Weight.clip)
            if let note = clip.note { profile.terms.add(text: note, weight: Weight.clip) }
        }

        return profile
    }
}
