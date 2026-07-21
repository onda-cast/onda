//  BottomChrome.swift
import CoreGraphics

//  Single source of truth for how much bottom clearance scrollable content and floating
//  toasts need to clear RootView's overlay chrome (mini-player + tab bar), which is NOT part
//  of the safe area — SwiftUI has no automatic inset for it. Screens hardcoding their own
//  guess (120, 96, 40...) have repeatedly landed short of the true worst case: mini-player
//  (76pt + 10pt bottom padding) + tab bar (62pt) = 148pt when both are visible.
enum BottomChrome {
    static let clearance: CGFloat = 150
}
