import SwiftUI
import AVKit

/// Full-screen video player for a live channel. Resolves the HLS URL via
/// PlaybackService, then plays it with AVPlayer. This closes Phase 0 on device.
struct PlayerView: View {
    let channel: String

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }

            if isLoading {
                ProgressView("Loading \(channel)…")
                    .font(.title3)
            }

            if let errorMessage {
                VStack(spacing: 24) {
                    Text("Couldn't play \(channel)")
                        .font(.title2).bold()
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                    Button("Back") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let url = try await PlaybackService.hlsURL(for: channel)
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}
