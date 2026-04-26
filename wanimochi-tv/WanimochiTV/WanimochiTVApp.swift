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
        VStack(spacing: 16) {
            Text("WanimochiTV")
                .font(.largeTitle)

            HStack {
                Text("State:")
                Text(controller.deviceStateText)
                    .foregroundColor(controller.isConnected ? .green : .red)
                    .bold()
            }

            if controller.isConnected {
                // Initialize button
                Button("Initialize (FW + Auth + B-CAS)") {
                    Task { await controller.initialize() }
                }

                Divider()

                // Channel + Tune
                HStack {
                    Text("Channel:")
                    TextField("13-62", value: $controller.selectedChannel, format: .number)
                        .frame(width: 60)
                    Button("Tune & Stream") {
                        Task { await controller.tuneAndStream() }
                    }
                    .disabled(controller.isStreaming)
                }

                if controller.signalLocked {
                    Text("Signal: \(controller.signalStrength)/100")
                        .foregroundColor(.green)
                }

                if controller.isStreaming {
                    VStack(spacing: 8) {
                        Text("Streaming")
                            .foregroundColor(.green).bold()
                        Text(controller.httpURL + "/stream")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Text("Open in VLC or ffplay")
                            .font(.caption).foregroundColor(.gray)

                        Link("Open Web Player", destination: URL(string: controller.httpURL)!)
                            .font(.caption)

                        Button("Stop") {
                            Task { await controller.stopStreaming() }
                        }
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
                }
            } else {
                Button("Connect") {
                    Task { await controller.connect() }
                }
            }

            if let error = controller.lastError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(30)
        .frame(minWidth: 450, minHeight: 400)
    }
}
