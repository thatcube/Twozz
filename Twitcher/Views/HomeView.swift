import SwiftUI

/// Temporary landing screen. Phase 2 will replace this with the followed-streams grid.
/// For now it doubles as the entry point for the Phase 0 playback test on a real device.
struct HomeView: View {
    @State private var channel: String = "jynxzi"
    @State private var showPlayer = false

    var body: some View {
        VStack(spacing: 40) {
            Text("Twitcher")
                .font(.system(size: 80, weight: .bold))
            Text("Native Twitch for Apple TV")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(spacing: 20) {
                Text("Phase 0 — Playback Test")
                    .font(.headline)
                TextField("Channel", text: $channel)
                    .frame(width: 500)
                Button("Watch \(channel)") {
                    showPlayer = true
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 40)
        }
        .padding()
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerView(channel: channel.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

#Preview {
    HomeView()
}
