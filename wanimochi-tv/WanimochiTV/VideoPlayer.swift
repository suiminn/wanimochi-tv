/*
 * VideoPlayer.swift - TS stream video playback
 *
 * Receives decrypted MPEG-2 TS data from StreamReader and provides
 * video/audio playback. Uses a pipe to ffplay or AVPlayer.
 *
 * For initial bring-up, this writes TS data to a named pipe that
 * ffplay reads from. Production use should integrate AVSampleBufferDisplayLayer.
 */

import Foundation
import AVFoundation

class TSVideoPlayer {
    private var outputPipe: Pipe?
    private var ffplayProcess: Process?
    private var outputFileHandle: FileHandle?
    private var outputURL: URL?

    enum OutputMode {
        case file(URL)       // Write to .ts file
        case pipe            // Pipe to ffplay
    }

    /// Start playback with given output mode.
    func start(mode: OutputMode) throws {
        switch mode {
        case .file(let url):
            outputURL = url
            FileManager.default.createFile(atPath: url.path, contents: nil)
            outputFileHandle = try FileHandle(forWritingTo: url)

        case .pipe:
            // Create a named pipe for ffplay
            let pipePath = NSTemporaryDirectory() + "wanimochitv.ts"
            if FileManager.default.fileExists(atPath: pipePath) {
                try FileManager.default.removeItem(atPath: pipePath)
            }
            mkfifo(pipePath, 0o644)

            // Launch ffplay reading from the pipe
            ffplayProcess = Process()
            ffplayProcess?.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffplay")
            ffplayProcess?.arguments = ["-i", pipePath, "-fflags", "nobuffer",
                                         "-flags", "low_delay", "-probesize", "32",
                                         "-analyzeduration", "0"]
            try ffplayProcess?.run()

            // Open pipe for writing
            outputFileHandle = FileHandle(forWritingAtPath: pipePath)
        }
    }

    /// Write decrypted TS data to output.
    func writeData(_ data: Data) {
        outputFileHandle?.write(data)
    }

    /// Stop playback and cleanup.
    func stop() {
        outputFileHandle?.closeFile()
        outputFileHandle = nil

        if let process = ffplayProcess, process.isRunning {
            process.terminate()
        }
        ffplayProcess = nil
    }
}
