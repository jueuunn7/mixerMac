import MixerAudio
import SwiftUI

struct MasterWaveformView: View {
    @ObservedObject var metrics: MasterWaveformMetrics
    var body: some View {
        Canvas { context, size in
            let area = CGRect(x: 5, y: 5, width: max(1, size.width - 10), height: max(1, size.height - 10))
            var baseline = Path()
            baseline.move(to: CGPoint(x: area.minX, y: area.midY))
            baseline.addLine(to: CGPoint(x: area.maxX, y: area.midY))
            context.stroke(baseline, with: .color(.white.opacity(0.16)), lineWidth: 0.6)
            let bins = metrics.bins
            func point(_ index: Int, _ value: Float) -> CGPoint {
                CGPoint(x: area.minX + area.width * Double(index) / Double(max(1, bins.count - 1)),
                    y: area.midY - area.height * CGFloat(min(1, max(-1, value))) / 2)
            }
            var waveform = Path()
            for index in bins.indices {
                let next = point(index, bins[index].maximum)
                if index == 0 { waveform.move(to: next) } else { waveform.addLine(to: next) }
            }
            for index in bins.indices.reversed() { waveform.addLine(to: point(index, bins[index].minimum)) }
            waveform.closeSubpath()
            context.fill(waveform, with: .color(.cyan.opacity(0.35)))
            context.stroke(waveform, with: .color(.cyan.opacity(0.9)), lineWidth: 0.65)
        }
        .background(Color(white: 0.085), in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.45), lineWidth: 0.75))
        .help("Smoothed master output waveform · after channel faders and master EQ · fixed ±1 PCM scale")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Master output waveform")
    }
}
