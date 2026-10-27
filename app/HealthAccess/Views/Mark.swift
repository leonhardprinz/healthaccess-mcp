import SwiftUI

/// The mark: a heartbeat that leaves as an arrow. On a 64 × 64 grid, `M6 34 H20 L26 20 L34 48 L40 34 H52` plus the
/// arrowhead `M46 26 L56 34 L46 42`, stroked with round caps and joins, width 4.2 on 64. Same path as the app icon.
struct MarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 64
        let ox = rect.midX - 32 * s, oy = rect.midY - 32 * s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        var path = Path()
        path.move(to: p(6, 34))
        path.addLine(to: p(20, 34))
        path.addLine(to: p(26, 20))
        path.addLine(to: p(34, 48))
        path.addLine(to: p(40, 34))
        path.addLine(to: p(52, 34))
        path.move(to: p(46, 26))
        path.addLine(to: p(56, 34))
        path.addLine(to: p(46, 42))
        return path
    }
}

/// The mark as a view. While `animating` is true the stroke draws itself from the heartbeat to the arrow, 1.2 s per
/// pass, and stops with Reduce Motion on.
struct MarkView: View {
    var animating = false
    var color: Color = .primary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            MarkShape()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: side * 4.2 / 64, lineCap: .round, lineJoin: .round))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: animating, initial: true) { _, on in
            guard on, !reduceMotion else {
                // A repeating animation keeps running until the value changes under a new transaction, so step off 1
                // without animation first, then ease back to the full mark.
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { progress = 0.999 }
                withAnimation(.easeOut(duration: 0.2)) { progress = 1 }
                return
            }
            progress = 0
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) { progress = 1 }
        }
        .accessibilityHidden(true)
    }
}

/// The mark on its blue tile, as on the icon.
struct MarkTile: View {
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Color.markBlue)
            MarkView(color: .white).padding(size * 0.15)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension Color {
    /// #0D366B, the ground of the icon.
    static let markBlue = Color(red: 13 / 255, green: 54 / 255, blue: 107 / 255)
    /// The one warm colour, used only for the leading bar of cards that need the user.
    static let signal = Color("Signal")
}
