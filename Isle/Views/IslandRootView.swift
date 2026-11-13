import SwiftUI

/// Root of the notch panel. Draws the black island at the size for the current
/// state and swaps the content inside it.
struct IslandRootView: View {
    @ObservedObject var store: IslandStateStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Springy morph normally; a short, bounce-free fade/resize with Reduce Motion.
    private var animation: Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.8)
    }

    private func transition(_ normal: AnyTransition) -> AnyTransition {
        reduceMotion ? .opacity : normal
    }

    var body: some View {
        let state = store.state
        let metrics = store.metrics
        let size = IslandLayout.size(for: state, metrics: metrics)
        let shape = NotchShape(
            topRadius: IslandLayout.topRadius(for: state),
            bottomRadius: IslandLayout.bottomRadius(for: state, metrics: metrics)
        )

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape.fill(Color.black)
                content(for: state, metrics: metrics)
                    .frame(width: size.width, height: size.height, alignment: .top)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .contentShape(shape)
            .opacity(size.height > 0 ? 1 : 0)
            .shadow(color: .black.opacity(state == .expanded || state.isPeek ? 0.45 : 0), radius: 12, y: 4)
            .onTapGesture { store.handleClick() }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(animation, value: state)
        .animation(animation, value: metrics)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func content(for state: IslandState, metrics: NotchMetrics) -> some View {
        switch state {
        case .idle:
            Color.clear
        case .compact:
            CompactMusicView(
                nowPlaying: store.nowPlaying,
                power: store.power,
                showsCharging: store.showsChargingIndicator,
                metrics: metrics
            )
            .transition(transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .top))))
        case .expanded:
            ExpandedMusicView(
                nowPlaying: store.nowPlaying,
                power: store.power,
                devices: store.audioDevices,
                metrics: metrics,
                controller: store.playbackController
            )
            .transition(transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top))))
        case .peek, .powerPeek, .airpodsPeek:
            if let peek = store.activePeek {
                peekContent(peek, metrics: metrics)
                    .id(peek.id)
                    .transition(transition(.opacity.combined(with: .move(edge: .top))))
            }
        }
    }

    @ViewBuilder
    private func peekContent(_ peek: PeekItem, metrics: NotchMetrics) -> some View {
        switch peek.content {
        case .notification(let notification):
            NotificationPeekView(notification: notification, metrics: metrics) {
                store.dismissPeek()
            }
        case .power(let event, let snapshot, _):
            PowerPeekView(event: event, snapshot: snapshot, metrics: metrics)
        case .airpods(let info):
            AirPodsPeekView(info: info, metrics: metrics)
        }
    }
}
