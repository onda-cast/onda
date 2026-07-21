//  SearchIndexBox.swift
import Foundation

@MainActor
@Observable
final class SearchIndexBox {
    let index: SearchIndex?
    init(index: SearchIndex?) {
        self.index = index
    }
}
