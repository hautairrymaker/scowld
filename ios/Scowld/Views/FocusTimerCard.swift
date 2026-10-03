import SwiftUI

/// The focus timer as it appears over the 3D scene in landscape.
///
/// Deliberately quiet: a frosted card in the corner with a progress ring and the
/// remaining time, so the character stays the subject. Nothing here is
/// interactive — every control lives in Settings, which is what keeps the home
/// screen free of buttons.
struct FocusTimerCard: View {
    var timer: FocusTimer
    var opacity: Double

    private var accent: Color {
        timer.phase == .focus ? .amicaBlue : Color(red: 0.36, green: 0.78, blue: 0.60)
    }

    var body: some View {
        HStack(spacing: 12) {
            ring

            VStack(alignment: .leading, spacing: 2) {
                Text(timer.displayText)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())

                Text(timer.subtitle)
                    .font(.caption2.weight(.medium))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        .opacity(opacity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(timer.subtitle) timer, \(timer.displayText)")
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.18), lineWidth: 3)

            if timer.mode == .countdown {
                Circle()
                    .trim(from: 0, to: max(0.001, timer.progress))
                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: timer.progress)
            } else {
                // Counting upwards has no end, so the ring breathes instead of filling.
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .rotationEffect(.degrees(timer.elapsed.truncatingRemainder(dividingBy: 4) * 90))
                    .animation(.linear(duration: 0.5), value: timer.elapsed)
            }

            Image(systemName: timer.phase == .focus ? "circle.dotted" : "cup.and.saucer.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
        }
        .frame(width: 34, height: 34)
    }
}
