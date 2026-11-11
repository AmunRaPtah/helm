import SwiftUI

// Follow-the-bottom scrolling that never moves text the user is reading.
//
// New output only pulls the view down while the user is already at the
// bottom. Once they scroll up, the view stays put until they come back down
// (or tap jump-to-bottom). `following` changes only when the user scrolls,
// never when content grows, so a big streamed chunk can't knock the view out
// of follow mode and a lazily unloaded row can't trick it back in.

/// Name of the coordinate space put on the ScrollView itself (the viewport).
let bottomFollowViewport = "bottomFollow.viewport"
/// Name of the coordinate space put on the scroll content.
let bottomFollowContent = "bottomFollow.content"

struct BottomFollowMetrics: Equatable {
    /// Sentinel's maxY in content coordinates, which is the content height.
    var contentHeight: CGFloat
    /// Sentinel's maxY in viewport coordinates.
    var bottomInViewport: CGFloat
}

struct BottomFollowKey: PreferenceKey {
    static var defaultValue: BottomFollowMetrics? = nil
    static func reduce(value: inout BottomFollowMetrics?, nextValue: () -> BottomFollowMetrics?) {
        value = nextValue() ?? value
    }
}

/// 1pt marker for the end of the content. Place it in a plain (non-lazy)
/// VStack after the content, so it is always laid out, and give it
/// `.id("bottom")` to use as the scrollTo target.
struct BottomFollowSentinel: View {
    var body: some View {
        GeometryReader { g in
            Color.clear.preference(
                key: BottomFollowKey.self,
                value: BottomFollowMetrics(
                    contentHeight: g.frame(in: .named(bottomFollowContent)).maxY,
                    bottomInViewport: g.frame(in: .named(bottomFollowViewport)).maxY))
        }
        .frame(height: 1)
    }
}

struct BottomFollower {
    /// True while new content should scroll the view down.
    var following = true
    private var last: BottomFollowMetrics?
    private var lastViewport: CGFloat = 0

    /// How close to the bottom (in points) still counts as "at the bottom".
    static let slack: CGFloat = 24

    mutating func update(_ m: BottomFollowMetrics?, viewport: CGFloat) {
        guard let m else { return }
        defer { last = m; lastViewport = viewport }
        // Content or viewport size changed: that's layout, not the user, so
        // keep whatever mode we were in.
        guard let last,
              abs(last.contentHeight - m.contentHeight) < 0.5,
              abs(lastViewport - viewport) < 0.5 else { return }
        let distance = m.bottomInViewport - viewport
        if distance <= Self.slack {
            following = true
        } else if m.bottomInViewport > last.bottomInViewport + 0.5 {
            // Moved away from the bottom: the user scrolled up. Moving toward
            // it (e.g. a jump-to-bottom animation) never turns following off.
            following = false
        }
    }
}

extension View {
    /// Open scrolled to the bottom without pinning to the bottom when content
    /// grows. The one-argument `defaultScrollAnchor(.bottom)` also governs
    /// size changes, which drags the reader along with new output. iOS 17 has
    /// no per-role variant, so there the caller's onAppear scroll does the
    /// initial positioning.
    @ViewBuilder
    func startsAtBottom() -> some View {
        if #available(iOS 18.0, *) {
            self.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            self
        }
    }
}
