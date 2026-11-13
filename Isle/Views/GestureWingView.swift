import SwiftUI

/// Wings shown while left ⌥ is held: a green camera dot + hand on the left,
/// what Isle sees (sign and target app) on the right.
struct GestureWingView: View {
    let status: IslandStateStore.GestureStatus?
    let metrics: NotchMetrics

    var body: some View {
        let inset = IslandLayout.topRadius(for: .gesture)
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(cameraOn ? Color.green : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.leading, inset + 12)
            .frame(width: IslandLayout.gestureWingWidth, alignment: .leading)
            Spacer(minLength: metrics.notchSize.width)
            right
                .padding(.trailing, inset + 12)
                .frame(width: IslandLayout.gestureWingWidth, alignment: .trailing)
        }
        .frame(height: metrics.notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var cameraOn: Bool {
        if case .listening? = status { return true }
        return false
    }

    @ViewBuilder
    private var right: some View {
        switch status {
        case .listening(let gesture?):
            label(gesture.emoji, gesture.target.name, color: .white.opacity(0.75))
        case .opening(let gesture):
            label(gesture.emoji, gesture.target.name, color: .green)
        case .unavailable(let message):
            Text(message)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        case .listening(nil), nil:
            Text("☝️ ✌️ 🖐️")
                .font(.system(size: 11))
                .opacity(0.6)
        }
    }

    private func label(_ emoji: String, _ name: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(emoji).font(.system(size: 13))
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var accessibilityText: String {
        switch status {
        case .listening(let gesture?): return "Seeing \(gesture.target.name) sign"
        case .opening(let gesture): return "Opening \(gesture.target.name)"
        case .unavailable(let message): return message
        case .listening(nil), nil: return "Show a hand sign"
        }
    }
}
