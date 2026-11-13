import SwiftUI

/// Peek for an audio device connecting (with L / R / Case rings) or disconnecting.
struct AirPodsPeekView: View {
    let info: AirPodsPeekInfo
    let metrics: NotchMetrics

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: info.device.kind.symbolName)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.device.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(info.connected ? "Connected" : "Disconnected")
                    .font(.system(size: 11))
                    .foregroundStyle(info.connected ? Color.green : Color.white.opacity(0.55))
            }
            Spacer(minLength: 8)
            if info.connected {
                rings
            }
        }
        .padding(.horizontal, IslandLayout.topRadius(for: .airpodsPeek) + 16)
        .padding(.top, metrics.notchSize.height + 8)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var rings: some View {
        let battery = info.device.battery
        HStack(spacing: 10) {
            if let battery, battery.left == nil, battery.right == nil, battery.main != nil {
                BatteryRing(label: "Battery", value: battery.main)
            } else {
                BatteryRing(label: "L", value: battery?.left)
                BatteryRing(label: "R", value: battery?.right)
                BatteryRing(label: "Case", value: battery?.caseLevel)
            }
        }
    }
}
