import SwiftUI
import AVFoundation

/// Full-screen audio player that reads from `AudioPlayerManager.shared`.
/// Dismissing this view does NOT stop playback — audio continues in background.
struct NASAudioView: View {
    var trackName: String = ""
    var trackPath: String = ""

    @Environment(\.dismiss) private var dismiss
    @State private var audioManager = AudioPlayerManager.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Album art placeholder
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 120))
                    .foregroundStyle(.white.opacity(0.3))

                // Filename
                Text(audioManager.trackName.isEmpty ? trackName : audioManager.trackName)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // Progress
                VStack(spacing: 4) {
                    Slider(value: Binding(
                        get: { audioManager.currentTime },
                        set: { audioManager.seek(to: $0) }
                    ), in: 0...max(audioManager.duration, 1))
                    .tint(.white)

                    HStack {
                        Text(formatTime(audioManager.currentTime))
                        Spacer()
                        Text(formatTime(audioManager.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 32)

                // Controls
                HStack(spacing: 32) {
                    Button { audioManager.playPrevious() } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.title2)
                    }
                    .disabled(!audioManager.hasPrevious)
                    .opacity(audioManager.hasPrevious ? 1 : 0.3)

                    Button { audioManager.skip(-15) } label: {
                        Image(systemName: "gobackward.15")
                            .font(.title2)
                    }

                    Button { audioManager.togglePlay() } label: {
                        Image(systemName: audioManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                    }

                    Button { audioManager.skip(15) } label: {
                        Image(systemName: "goforward.15")
                            .font(.title2)
                    }

                    Button { audioManager.playNext() } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.title2)
                    }
                    .disabled(!audioManager.hasNext)
                    .opacity(audioManager.hasNext ? 1 : 0.3)
                }
                .foregroundStyle(.white)

                // Track counter
                if audioManager.siblings.count > 1 {
                    Text("\(audioManager.currentIndex + 1) / \(audioManager.siblings.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer()
            }
        }
        .navigationBarHidden(true)
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .padding(.top, 56)
            .padding(.leading, 16)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                audioManager.stop()
                dismiss()
            } label: {
                Image(systemName: "stop.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .padding(.top, 56)
            .padding(.trailing, 16)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
}
