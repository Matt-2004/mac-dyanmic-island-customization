import SwiftUI

/// Banner that drops out of the notch for an incoming notification.
struct NotificationPeekView: View {
    let notification: IslandNotification
    let metrics: NotchMetrics
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(notification.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(notification.appName)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                if let detail = detailText {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                }
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notification")
        }
        .padding(.horizontal, IslandLayout.topRadius(for: .peek) + 14)
        .padding(.top, metrics.notchSize.height + 6)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var detailText: String? {
        let parts = [notification.subtitle, notification.body]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    private var icon: some View {
        AppIconView(notification: notification, size: 34)
    }
}
