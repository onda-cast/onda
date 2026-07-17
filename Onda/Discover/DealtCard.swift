//  DealtCard.swift
//  Staggered "dealt onto the table" entrance for shake-to-discover results: each card starts
//  low, tilted, and invisible, then springs to place with a delay proportional to its index —
//  snappy and overshooting to match the neo-brutalist hard-edge style.
import SwiftUI

struct DealtCard<Content: View>: View {
    let index: Int
    @ViewBuilder var content: Content
    @State private var landed = false

    var body: some View {
        content
            .opacity(landed ? 1 : 0)
            .offset(y: landed ? 0 : 28)
            .rotationEffect(.degrees(landed ? 0 : (index.isMultiple(of: 2) ? -3 : 3)),
                            anchor: .bottomLeading)
            .onAppear {
                // Cap the stagger so long lists don't tail off forever.
                let delay = Double(min(index, 12)) * 0.05
                withAnimation(.spring(duration: 0.38, bounce: 0.45).delay(delay)) {
                    landed = true
                }
            }
    }
}
