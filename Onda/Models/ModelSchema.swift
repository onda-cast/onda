//  ModelSchema.swift
import SwiftData

let ondaSchema: [any PersistentModel.Type] = [
    Podcast.self, Episode.self, Chapter.self,
    ShowSettings.self, QueueItem.self, DownloadedFile.self,
    Transcript.self, TranscriptCue.self
]
