/*
 * VLCStreamPlayerView.swift - SwiftUI wrapper for VLCKit playback
 */

import SwiftUI

#if canImport(VLCKit)
import VLCKit
#endif

struct VLCStreamPlayerView: View {
    let streamURL: URL?
    let playbackToken: UUID
    let isStreaming: Bool

    @State private var manualReloadToken = UUID()

    private var effectiveToken: String {
        "\(playbackToken.uuidString)-\(manualReloadToken.uuidString)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Color.black

                if let streamURL {
                    #if canImport(VLCKit)
                    VLCPlayerSurface(
                        streamURL: streamURL,
                        playbackToken: effectiveToken
                    )
                    #else
                    MissingVLCKitView()
                    #endif
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "tv")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("No Stream")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 12) {
                Label(isStreaming ? "Playing" : "Ready", systemImage: isStreaming ? "play.fill" : "pause.fill")
                    .foregroundStyle(isStreaming ? .green : .secondary)

                if let streamURL {
                    Text(streamURL.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer()

                Button {
                    manualReloadToken = UUID()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(streamURL == nil)
            }
            .font(.caption)
        }
    }
}

#if canImport(VLCKit)
private struct VLCPlayerSurface: NSViewRepresentable {
    let streamURL: URL
    let playbackToken: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> VLCVideoView {
        let view = VLCVideoView(frame: .zero)
        view.autoresizingMask = [.width, .height]
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: VLCVideoView, context: Context) {
        context.coordinator.play(url: streamURL, playbackToken: playbackToken)
    }

    static func dismantleNSView(_ nsView: VLCVideoView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private let mediaPlayer = VLCMediaPlayer()
        private var currentURL: URL?
        private var currentPlaybackToken: String?

        func attach(to view: VLCVideoView) {
            mediaPlayer.drawable = view
        }

        func play(url: URL, playbackToken: String) {
            guard currentURL != url || currentPlaybackToken != playbackToken else {
                if !mediaPlayer.isPlaying {
                    mediaPlayer.play()
                }
                return
            }

            mediaPlayer.stop()
            currentURL = url
            currentPlaybackToken = playbackToken
            mediaPlayer.media = VLCMedia(url: url)
            mediaPlayer.play()
        }

        func stop() {
            mediaPlayer.stop()
            currentURL = nil
            currentPlaybackToken = nil
        }
    }
}
#else
private struct MissingVLCKitView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 38))
                .foregroundStyle(.yellow)
            Text("VLCKit is not linked")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Run pod install and open the workspace.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
#endif
