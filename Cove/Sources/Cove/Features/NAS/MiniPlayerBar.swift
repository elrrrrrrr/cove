import SwiftUI

/// Compact audio player bar shown at the bottom of NASBrowserView when audio is playing.
struct MiniPlayerBar: View {
    var onTap: () -> Void

    @State private var audioManager = AudioPlayerManager.shared

    var body: some View {
        if audioManager.player != nil {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.accentColor)

                Text(audioManager.trackName)
                    .font(.subheadline)
                    .lineLimit(1)

                Spacer()

                if audioManager.hasPrevious {
                    Button { audioManager.playPrevious() } label: {
                        Image(systemName: "backward.fill")
                            .font(.caption)
                    }
                }

                Button { audioManager.togglePlay() } label: {
                    Image(systemName: audioManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }

                if audioManager.hasNext {
                    Button { audioManager.playNext() } label: {
                        Image(systemName: "forward.fill")
                            .font(.caption)
                    }
                }

                Button { audioManager.stop() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.1), radius: 4)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
        }
    }
}
