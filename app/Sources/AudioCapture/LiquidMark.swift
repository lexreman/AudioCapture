import SwiftUI

/// The record button's mark as red liquid inside the tile. Ready: a drop. Recording: the drop splashes
/// out and fills the tile, leaving an empty square (stop); stopping or pausing gathers it back into the drop.
/// About 35 droplets on springs, drawn gooey (blur, then a sharp alpha threshold) so they merge and
/// stretch like liquid. It moves only during a change (about a second); otherwise nothing redraws.
enum LiquidState { case drop, stop }

final class LiquidSim {
    struct Drop { var p: CGPoint; var v: CGVector; var r: CGFloat; var target: CGPoint; var targetR: CGFloat; var k: CGFloat; var delay: Double }
    private(set) var drops: [Drop] = []
    private(set) var settled = true
    private let n = 35
    let size = Metric.band

    init() { snap(.drop) }

    /// Straight to a state, no motion (first appearance, Reduce Motion).
    func snap(_ state: LiquidState) {
        drops = targets(state).map { Drop(p: $0.0, v: .zero, r: $0.1, target: $0.0, targetR: $0.1, k: 160, delay: 0) }
        settled = true
    }

    /// Towards a state with a splash: a kick away from (or towards) the centre, staggered by a few ms.
    func flow(to state: LiquidState) {
        let t = targets(state), c = size / 2
        for i in drops.indices {
            drops[i].target = t[i].0; drops[i].targetR = t[i].1
            drops[i].k = .random(in: 120...220)
            drops[i].delay = .random(in: 0...0.08)
            let dx = drops[i].p.x - c, dy = drops[i].p.y - c, len = max(1, hypot(dx, dy))
            let out: CGFloat = state == .drop ? -60 : 260
            drops[i].v.dx += dx / len * out + .random(in: -60...60)
            drops[i].v.dy += dy / len * out + .random(in: -60...60)
        }
        settled = false
    }

    func step(_ dt: Double) {
        let dt = CGFloat(min(dt, 1.0 / 30))
        var moving = false
        for i in drops.indices {
            if drops[i].delay > 0 { drops[i].delay -= Double(dt); moving = true; continue }
            var d = drops[i]
            let ax = d.k * (d.target.x - d.p.x) - 14 * d.v.dx, ay = d.k * (d.target.y - d.p.y) - 14 * d.v.dy
            d.v.dx += ax * dt; d.v.dy += ay * dt
            d.p.x += d.v.dx * dt; d.p.y += d.v.dy * dt
            d.r += (d.targetR - d.r) * min(1, 9 * dt)
            if hypot(d.v.dx, d.v.dy) > 0.5 || hypot(d.target.x - d.p.x, d.target.y - d.p.y) > 0.2 || abs(d.targetR - d.r) > 0.05 { moving = true }
            drops[i] = d
        }
        settled = !moving
    }

    private func targets(_ state: LiquidState) -> [(CGPoint, CGFloat)] {
        let c = size / 2
        /// Droplets spaced evenly along the walls, `inset` in: the fill that leaves the centre empty.
        func wall(_ count: Int, inset: CGFloat, r: CGFloat) -> [(CGPoint, CGFloat)] {
            let side = size - 2 * inset, per = 4 * side
            return (0..<count).map { i in
                var d = CGFloat(i) / CGFloat(count) * per
                let edge = Int(d / side); d -= CGFloat(edge) * side
                let pt: CGPoint = switch edge {
                case 0: CGPoint(x: inset + d, y: inset)
                case 1: CGPoint(x: size - inset, y: inset + d)
                case 2: CGPoint(x: size - inset - d, y: size - inset)
                default: CGPoint(x: inset, y: size - inset - d)
                }
                return (pt, r)
            }
        }
        switch state {
        case .drop:
            return (0..<n).map { i in let a = Double(i) / Double(n) * 2 * .pi; return (CGPoint(x: c + 3 * cos(a), y: c + 3 * sin(a)), 9) }
        case .stop:
            return wall(n, inset: 9, r: 9.5)
        }
    }
}

struct LiquidMark: View {
    let state: LiquidState
    let radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sim = LiquidSim()
    @State private var animating = false
    @State private var last = Date()

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: radius, style: .continuous)
        TimelineView(.animation(paused: !animating)) { context in
            Canvas { g, size in
                if animating {
                    let now = context.date
                    sim.step(now.timeIntervalSince(last))
                    let done = sim.settled
                    DispatchQueue.main.async { last = now; if done { animating = false } }
                }
                g.clip(to: tile.path(in: CGRect(origin: .zero, size: size)))
                g.addFilter(.alphaThreshold(min: 0.5, color: Color(nsColor: .systemRed)))
                g.addFilter(.blur(radius: 3.5))
                g.drawLayer { layer in
                    for d in sim.drops {
                        layer.fill(Path(ellipseIn: CGRect(x: d.p.x - d.r, y: d.p.y - d.r, width: 2 * d.r, height: 2 * d.r)), with: .color(.black))
                    }
                }
            }
        }
        .frame(width: Metric.band, height: Metric.band)
        .onChange(of: state, initial: true) { old, new in
            // Renders for the README take the settled shape, as the app shows it at rest (no mid-splash frame).
            if old == new || reduceMotion || SelfTest.isBackgroundRun { sim.snap(new); animating = false; return }
            sim.flow(to: new); last = Date(); animating = true
        }
    }
}
