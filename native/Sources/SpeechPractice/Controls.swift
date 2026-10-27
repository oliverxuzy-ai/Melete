import SwiftUI

// Form controls drawn in Melete's own materials, used by trays and settings, so a form reads
// as part of the same room as the stage rather than a system preference pane.

/// A switch: an Egyptian blue track when on, an inset well when off.
struct MeleteToggle: View {
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Palette.kyanos : Palette.well)
                    .overlay(Capsule().strokeBorder(isOn ? Color.clear : Palette.vein, lineWidth: 1))
                Circle().fill(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .padding(3)
            }
            .frame(width: 42, height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .animation(Motion.glass, value: isOn)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "开" : "关")
    }
}

/// A row of choices; the chosen one is filled.
struct ChoiceChips<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(options, id: \.self) { o in
                let on = o == selection
                Button { selection = o } label: {
                    Text(label(o)).font(Typeface.ui(13, on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.white : Palette.ink)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(on ? Palette.kyanos : Palette.raised, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Color.clear : Palette.vein, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(Motion.ticker, value: selection)
    }
}

/// Minus, the value, plus.
struct NumberStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String
    var step = 1

    var body: some View {
        HStack(spacing: 0) {
            button("minus") { value = max(range.lowerBound, value - step) }.disabled(value <= range.lowerBound)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(value)").font(Typeface.display(18)).monospacedDigit().foregroundStyle(Palette.ink)
                    .contentTransition(.numericText(value: Double(value)))
                Text(unit).font(Typeface.ui(12)).foregroundStyle(Palette.ink2)
            }
            .frame(minWidth: 64)
            button("plus") { value = min(range.upperBound, value + step) }.disabled(value >= range.upperBound)
        }
        .padding(3)
        .background(Palette.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.vein, lineWidth: 1))
        .animation(Motion.ticker, value: value)
    }

    private func button(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.kyanos)
                .frame(width: 28, height: 28).contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// A text field set on paper with a vein outline.
    func fieldBox(radius: CGFloat = 12) -> some View {
        self.textFieldStyle(.plain)
            .font(Typeface.ui(14))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.vein, lineWidth: 1))
    }
}

/// A multi-line editor on paper.
struct PaperEditor: View {
    @Binding var text: String
    var placeholder = ""
    var minHeight: CGFloat = 180

    var body: some View {
        TextEditor(text: $text)
            .font(Typeface.ui(14))
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(minHeight: minHeight)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Palette.vein, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder).font(Typeface.ui(14)).foregroundStyle(Palette.ink3)
                        .padding(.horizontal, 15).padding(.vertical, 10).allowsHitTesting(false)
                }
            }
    }
}

/// A small label above a field, with an optional line of explanation.
struct FieldLabel: View {
    let title: String
    var detail: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Typeface.ui(12, .medium)).foregroundStyle(Palette.ink2)
            if !detail.isEmpty {
                Text(detail).font(Typeface.ui(11)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A destructive action that asks in place: the first press turns the button into a short
/// question with 取消 and 删除 beside it. No system dialog, so nothing is left half dismissed
/// when the thing it asked about goes away.
struct ConfirmButton: View {
    let title: String
    var question: String = ""
    var confirm: String = "删除"
    let action: () -> Void
    @State private var asking = false

    var body: some View {
        HStack(spacing: 10) {
            if asking {
                if !question.isEmpty {
                    Text(question).font(Typeface.ui(12)).foregroundStyle(Palette.ink2).lineLimit(2)
                }
                Button("取消") { asking = false }.buttonStyle(InkButtonStyle(color: Palette.ink2))
                Button {
                    asking = false
                    action()
                } label: {
                    Text(confirm).font(Typeface.ui(13, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Palette.cinnabar, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button(title) { asking = true }.buttonStyle(InkButtonStyle(color: Palette.cinnabar))
            }
        }
        .animation(Motion.paper, value: asking)
    }
}
