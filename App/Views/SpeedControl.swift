// Speed, settable three ways: drag for coarse, step for exact, tap a preset for common.
// The readout is rounded-design monospaced digits so it reads like an instrument and
// doesn't reflow as the value changes.

import SwiftUI

struct SpeedControl: View {
    @EnvironmentObject private var controller: SpoofController

    /// speedDisplay is computed (it converts), so it needs a hand-made Binding —
    /// $controller.speedDisplay only exists for stored @Published properties.
    private var speed: Binding<Double> {
        Binding(get: { controller.speedDisplay },
                set: { controller.speedDisplay = $0 })
    }

    private var presets: [Int] { controller.useMPH ? [25, 45, 65] : [40, 80, 110] }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(speed.wrappedValue, format: .number.precision(.fractionLength(0)))
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .numeric()

                // Tap the unit to switch it; the value converts rather than jumping.
                Button {
                    Haptic.tap()
                    controller.useMPH.toggle()
                } label: {
                    HStack(spacing: 2) {
                        Text(controller.speedUnit)
                        Image(systemName: "arrow.left.arrow.right").font(.caption2)
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Stepper("") {
                    adjust(by: 1)
                } onDecrement: {
                    adjust(by: -1)
                }
                .labelsHidden()
            }

            Slider(value: speed, in: controller.speedRange, step: 1)
                .tint(.green)

            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { value in
                    Button {
                        Haptic.tap()
                        speed.wrappedValue = Double(value)
                    } label: {
                        Text("\(value)")
                            .font(.caption.weight(.semibold))
                            .numeric()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(isCurrent(value) ? Color.green.opacity(0.25) : Color.gray.opacity(0.15))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(isCurrent(value) ? .green : .clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func isCurrent(_ value: Int) -> Bool {
        abs(speed.wrappedValue - Double(value)) < 0.5
    }

    private func adjust(by delta: Double) {
        Haptic.tap()
        let range = controller.speedRange
        speed.wrappedValue = min(range.upperBound,
                                 max(range.lowerBound, (speed.wrappedValue + delta).rounded()))
    }
}
