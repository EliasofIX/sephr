import SwiftUI
import UIKit

/// Multi-pane origami fold of a page snapshot. The snapshot is sliced
/// into four horizontal strips; each strip rotates around its own top
/// edge with a staggered delay so the page collapses toward the top of
/// the screen like a paper fold-down, leaving a thin condensed strip.
///
/// `progress` is `0` (flat, page-sized) → `1` (fully folded). Drive it
/// with a SwiftUI `.animation` and the strips fold in concert.
struct OrigamiFoldView: View {

    let snapshot: UIImage
    /// 0 = page flat, 1 = fully folded into a strip at top.
    let progress: Double

    /// Final compressed height as a fraction of the snapshot's height —
    /// the "strip" left visible after the fold.
    var collapsedHeightFraction: Double = 0.12

    var body: some View {
        GeometryReader { proxy in
            let panels = sliceSnapshot(into: 4)
            // Tiny / invalid snapshots fall back to a single flat image so
            // we never divide by zero or feed CGImage.cropping(to:) garbage.
            if panels.isEmpty || proxy.size.height <= 1 {
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width,
                           height: proxy.size.height)
                    .clipped()
            } else {
                let foldedHeight = proxy.size.height * collapsedHeightFraction
                let liveHeight = max(
                    1,
                    proxy.size.height
                        - (proxy.size.height - foldedHeight) * progress)
                VStack(spacing: 0) {
                    ForEach(Array(panels.enumerated()),
                            id: \.offset) { index, panel in
                        let angle = foldAngle(panelIndex: index,
                                              count: panels.count)
                        Image(uiImage: panel)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width,
                                   height: liveHeight
                                        / CGFloat(panels.count))
                            .clipped()
                            .rotation3DEffect(
                                .degrees(angle),
                                axis: (1, 0, 0),
                                anchor: .top,
                                anchorZ: 0,
                                perspective: 0.6)
                            .opacity(panelOpacity(index: index))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Stagger: the bottom panel folds first and most; the top stays
    /// nearly flat. Reads as the page collapsing upward.
    private func foldAngle(panelIndex: Int, count: Int) -> Double {
        let normalized = Double(panelIndex) / Double(max(count - 1, 1))
        // Bottom panels fold to a steeper angle; top stays small.
        let max = -82.0  // degrees, negative folds away from viewer
        return max * (1 - normalized) * progress * progress
    }

    private func panelOpacity(index: Int) -> Double {
        // Fade out the lower panels a touch as they fold — they're
        // approaching edge-on so they'd be invisible anyway.
        let normalized = Double(index) / 3.0
        return 1.0 - (0.55 * (1 - normalized) * progress)
    }

    /// Slice a UIImage into N horizontal strips for the fold panels.
    /// `cgImage.cropping(to:)` works in PIXEL coordinates, not points,
    /// and crashes on rects with non-positive dimensions — we clamp on
    /// every edge.
    private func sliceSnapshot(into count: Int) -> [UIImage] {
        guard count > 0, let cg = snapshot.cgImage else { return [] }
        let pixelWidth = CGFloat(cg.width)
        let pixelHeight = CGFloat(cg.height)
        guard pixelWidth >= CGFloat(count), pixelHeight >= CGFloat(count)
        else { return [] }
        let stripPixelHeight = floor(pixelHeight / CGFloat(count))
        guard stripPixelHeight >= 1 else { return [] }
        var strips: [UIImage] = []
        for index in 0..<count {
            let yStart = CGFloat(index) * stripPixelHeight
            let remaining = pixelHeight - yStart
            let height = min(
                (index == count - 1) ? remaining : stripPixelHeight,
                remaining)
            guard height >= 1 else { break }
            let rect = CGRect(x: 0, y: yStart,
                              width: pixelWidth, height: height)
                .integral
            if let cropped = cg.cropping(to: rect) {
                strips.append(UIImage(cgImage: cropped,
                                      scale: snapshot.scale,
                                      orientation: snapshot.imageOrientation))
            } else {
                strips.append(snapshot)
            }
        }
        return strips
    }
}
