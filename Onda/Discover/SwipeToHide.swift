//  SwipeToHide.swift
//  Horizontal swipe on a Discover row → hide the show. Rows live in a ScrollView (no List
//  swipeActions), so this is the mini-player's follow-the-finger drag pattern: the row slides
//  and fades, then the action fires. Vertical scrolling wins vertical drags; a plain (non-
//  high-priority) gesture only claims clearly horizontal movement, and taps still pass through.
import SwiftUI

struct SwipeToHide: ViewModifier {
    let action: () -> Void
    @State private var dragX: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: dragX)
            .opacity(1 - min(0.6, Double(abs(dragX)) / 260))
            .gesture(
                DragGesture(minimumDistance: 25)
                    .onChanged { value in
                        // Claim only clearly-horizontal drags; anything else stays a scroll.
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        dragX = value.translation.width
                    }
                    .onEnded { value in
                        guard abs(value.translation.width) > 90,
                              abs(value.translation.width) > abs(value.translation.height) else {
                            withAnimation(.easeOut(duration: 0.15)) { dragX = 0 }
                            return
                        }
                        withAnimation(.easeOut(duration: 0.18)) {
                            dragX = value.translation.width > 0 ? 500 : -500
                        }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(180))
                            action()
                            dragX = 0
                        }
                    }
            )
    }
}

extension View {
    /// Swipe the row horizontally to hide the show from Discover.
    func swipeToHide(_ action: @escaping () -> Void) -> some View {
        modifier(SwipeToHide(action: action))
    }
}
