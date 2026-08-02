import Foundation
import SwiftUI

/// Computes the combined magnitude response of the 10 EQ bands so the UI can
/// draw the curve the device is actually applying.
///
/// Uses the standard RBJ audio-EQ-cookbook biquad coefficients, evaluated on
/// the unit circle: |H(e^jw)| = |b0 + b1·z⁻¹ + b2·z⁻²| / |a0 + a1·z⁻¹ + a2·z⁻²|
enum EQCurve {
    static let sampleRate: Double = 48000
    static let minFreq: Double = 20
    static let maxFreq: Double = 20000

    /// Magnitude in dB at `count` log-spaced frequencies from 20 Hz to 20 kHz.
    static func response(bands: [QxEqBandValue], preGain: Double, count: Int = 220) -> [Double] {
        let logMin = log10(minFreq), logMax = log10(maxFreq)
        return (0..<count).map { i in
            let t = Double(i) / Double(max(count - 1, 1))
            let f = pow(10, logMin + t * (logMax - logMin))
            var db = preGain
            for band in bands where band.filter != .bypass {
                db += bandGainDb(band, at: f)
            }
            return db
        }
    }

    /// Frequency at normalised position 0…1 across the log axis.
    static func frequency(atFraction t: Double) -> Double {
        pow(10, log10(minFreq) + t * (log10(maxFreq) - log10(minFreq)))
    }

    /// Normalised 0…1 x-position of a frequency on the log axis.
    static func fraction(of freq: Double) -> Double {
        (log10(max(freq, minFreq)) - log10(minFreq)) / (log10(maxFreq) - log10(minFreq))
    }

    private static func bandGainDb(_ band: QxEqBandValue, at freq: Double) -> Double {
        let f0 = max(1, min(Double(band.freq), sampleRate / 2 - 1))
        let q = max(0.05, band.q)
        let gain = band.gain
        let a = pow(10, gain / 40)              // amplitude for shelf/peak maths
        let w0 = 2 * .pi * f0 / sampleRate
        let cosW0 = cos(w0), sinW0 = sin(w0)
        let alpha = sinW0 / (2 * q)

        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0

        switch band.filter {
        case .peak:
            b0 = 1 + alpha * a;  b1 = -2 * cosW0;  b2 = 1 - alpha * a
            a0 = 1 + alpha / a;  a1 = -2 * cosW0;  a2 = 1 - alpha / a
        case .lowShelf:
            let sq = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) - (a - 1) * cosW0 + sq)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW0)
            b2 = a * ((a + 1) - (a - 1) * cosW0 - sq)
            a0 = (a + 1) + (a - 1) * cosW0 + sq
            a1 = -2 * ((a - 1) + (a + 1) * cosW0)
            a2 = (a + 1) + (a - 1) * cosW0 - sq
        case .highShelf:
            let sq = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) + (a - 1) * cosW0 + sq)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
            b2 = a * ((a + 1) + (a - 1) * cosW0 - sq)
            a0 = (a + 1) - (a - 1) * cosW0 + sq
            a1 = 2 * ((a - 1) - (a + 1) * cosW0)
            a2 = (a + 1) - (a - 1) * cosW0 - sq
        case .lpf:
            b0 = (1 - cosW0) / 2;  b1 = 1 - cosW0;  b2 = (1 - cosW0) / 2
            a0 = 1 + alpha;        a1 = -2 * cosW0; a2 = 1 - alpha
        case .hpf:
            b0 = (1 + cosW0) / 2;  b1 = -(1 + cosW0); b2 = (1 + cosW0) / 2
            a0 = 1 + alpha;        a1 = -2 * cosW0;   a2 = 1 - alpha
        case .bypass:
            return 0
        }

        let w = 2 * .pi * freq / sampleRate
        let cosW = cos(w), sinW = sin(w)
        let cos2W = cos(2 * w), sin2W = sin(2 * w)

        let numRe = b0 + b1 * cosW + b2 * cos2W
        let numIm = -(b1 * sinW + b2 * sin2W)
        let denRe = a0 + a1 * cosW + a2 * cos2W
        let denIm = -(a1 * sinW + a2 * sin2W)

        let num = sqrt(numRe * numRe + numIm * numIm)
        let den = sqrt(denRe * denRe + denIm * denIm)
        guard den > 1e-12, num > 1e-12 else { return 0 }
        let db = 20 * log10(num / den)
        return db.isFinite ? db : 0
    }
}

/// Draws the combined EQ response with a log frequency axis.
///
/// The curve shows the filter shape *excluding* pre-gain — pre-gain is a
/// uniform offset to avoid clipping, so folding it in would just slide the
/// whole curve off-centre and hide the tonal shape. It's captioned instead.
struct EQCurveView: View {
    let bands: [QxEqBandValue]
    let preGain: Double
    var highlighted: Int?          // band index to mark, while it's being edited

    /// Symmetric dB range, grown to fit the curve so small edits stay legible.
    private var range: Double {
        let peak = EQCurve.response(bands: bands, preGain: 0).map(abs).max() ?? 0
        return min(18, max(9, (peak / 3).rounded(.up) * 3 + 3))
    }

    var body: some View {
        Canvas { ctx, size in
            let range = self.range
            let values = EQCurve.response(bands: bands, preGain: 0)
            let midY = size.height / 2
            func y(_ db: Double) -> CGFloat {
                midY - CGFloat(max(-range, min(range, db)) / range) * (size.height / 2 - 6)
            }

            // Horizontal grid: 0 dB emphasised, the rest faint.
            let step = range > 12 ? 6.0 : (range > 9 ? 6.0 : 3.0)
            for db in stride(from: -range + step, through: range - step, by: step) {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(db)))
                line.addLine(to: CGPoint(x: size.width, y: y(db)))
                ctx.stroke(line, with: .color(.secondary.opacity(db == 0 ? 0.45 : 0.14)),
                           lineWidth: db == 0 ? 1 : 0.5)
            }
            // Vertical grid at decades.
            for f in [100.0, 1000, 10000] {
                let x = CGFloat(EQCurve.fraction(of: f)) * size.width
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(line, with: .color(.secondary.opacity(0.14)), lineWidth: 0.5)
                ctx.draw(Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary),
                         at: CGPoint(x: x + 11, y: size.height - 7))
            }

            guard values.count > 1 else { return }

            // The response curve, with a soft fill down to the 0 dB line.
            var curve = Path()
            for (i, db) in values.enumerated() {
                let x = CGFloat(i) / CGFloat(values.count - 1) * size.width
                let p = CGPoint(x: x, y: y(db))
                i == 0 ? curve.move(to: p) : curve.addLine(to: p)
            }

            var fill = curve
            fill.addLine(to: CGPoint(x: size.width, y: y(0)))
            fill.addLine(to: CGPoint(x: 0, y: y(0)))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [.accentColor.opacity(0.34), .accentColor.opacity(0.05)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            ctx.stroke(curve, with: .color(.accentColor), lineWidth: 1.8)

            // Band markers.
            for (i, band) in bands.enumerated() where band.filter != .bypass {
                let x = CGFloat(EQCurve.fraction(of: Double(band.freq))) * size.width
                let isOn = highlighted == i
                let r: CGFloat = isOn ? 4 : 2.5
                let dot = Path(ellipseIn: CGRect(x: x - r, y: y(band.gain) - r,
                                                 width: r * 2, height: r * 2))
                ctx.fill(dot, with: .color(isOn ? .accentColor : .accentColor.opacity(0.55)))
                if isOn {
                    ctx.stroke(dot, with: .color(.white.opacity(0.9)), lineWidth: 1.2)
                }
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            Text("±\(Int(range)) dB")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .padding(4)
        }
        .overlay(alignment: .topTrailing) {
            if abs(preGain) >= 0.05 {
                Text(String(format: "pre-gain %+.1f dB", preGain))
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
    }
}
