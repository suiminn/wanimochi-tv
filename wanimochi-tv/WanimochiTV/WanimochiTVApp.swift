/*
 * WanimochiTVApp.swift - WanimochiTV companion app
 */

import SwiftUI
import AppKit

@main
struct WanimochiTVApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var deviceController = DeviceController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(deviceController)
                .onAppear {
                    appDelegate.deviceController = deviceController
                }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var deviceController: DeviceController?
    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating, let deviceController else {
            return .terminateNow
        }

        isTerminating = true
        Task { @MainActor in
            await deviceController.shutdownForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct ContentView: View {
    @EnvironmentObject var controller: DeviceController

    var body: some View {
        HStack(spacing: 0) {
            controlPanel
                .frame(width: 300)
                .padding(24)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                VLCStreamPlayerView(
                    streamURL: controller.playerStreamURL,
                    playbackToken: controller.playbackToken,
                    isStreaming: controller.isStreaming
                )

                if let error = controller.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 980, minHeight: 620)
    }

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("WanimochiTV")
                .font(.title)
                .bold()

            statusRow

            if controller.isConnected {
                Button {
                    Task { await controller.initialize() }
                } label: {
                    Label("Initialize", systemImage: "checkmark.seal")
                }
                .buttonStyle(.borderedProminent)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Channel")
                        .font(.headline)

                    HStack {
                        TextField("13-62", value: $controller.selectedChannel, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 74)

                        Stepper("", value: $controller.selectedChannel, in: 13...62)
                            .labelsHidden()
                    }

                    Button {
                        Task { await controller.playSelectedChannel() }
                    } label: {
                        Label(controller.isStreaming ? "Change Channel" : "Tune & Play", systemImage: "play.tv")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.selectedChannel < 13 || controller.selectedChannel > 62)
                }

                if controller.signalLocked {
                    Label("Signal \(controller.signalStrength)/100", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                }

                if controller.isStreaming {
                    Button {
                        Task { await controller.stopStreaming() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Button {
                    Task { await controller.connect() }
                } label: {
                    Label("Connect", systemImage: "cable.connector")
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.isConnected ? Color.green : Color.red)
                .frame(width: 9, height: 9)

            Text(controller.deviceStateText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
