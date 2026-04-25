/*
 * TSHTTPServer.swift - Local HTTP server for TS stream delivery
 *
 * Raw TS stream + ffmpeg transcoded HLS (MPEG-2→H.264) for browser playback.
 *
 * Endpoints:
 *   GET /stream        - Raw TS stream (MPEG-2, for VLC/ffplay)
 *   GET /stream.m3u    - .m3u file to open raw stream in external player
 *   GET /playlist.m3u8 - HLS playlist (H.264, for browser playback)
 *   GET /hls/<seg>.ts  - HLS segments (served from ffmpeg output dir)
 *   GET /channels      - ISDB-T UHF channel list (JSON)
 *   POST /tune/:ch     - Tune to channel
 *   GET /status        - Current status (JSON)
 *   GET /              - Web player (hls.js + channel controls)
 */

import Foundation

class TSHTTPServer {
    private var serverSocket: Int32 = -1
    private var clients: [StreamClient] = []
    private let clientsLock = NSLock()
    private var running = false
    let port: UInt16

    var onTuneRequest: ((Int) -> Void)?

    var currentChannel: Int = 0
    var signalStrength: Int = 0
    var isStreaming: Bool = false

    // MARK: - ffmpeg HLS transcoder

    private var ffmpegProcess: Process?
    private var ffmpegPipe: Pipe?
    private let hlsDir = "/tmp/wanimochi_hls"

    init(port: UInt16 = 8888) {
        self.port = port
    }

    // MARK: - Start/Stop

    func start() throws {
        signal(SIGPIPE, SIG_IGN)

        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { throw GVM2TVError.iokitError(errno) }

        var opt: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverSocket)
            throw GVM2TVError.iokitError(errno)
        }

        listen(serverSocket, 10)
        running = true

        print("[HTTP] Server started on port \(port)")
        print("[HTTP] Player: http://localhost:\(port)/")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        running = false
        stopFFmpeg()
        clientsLock.lock()
        for c in clients { close(c.socket) }
        clients.removeAll()
        clientsLock.unlock()

        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }

    // MARK: - ffmpeg Process

    func startFFmpeg() {
        stopFFmpeg()

        // Create HLS output directory
        try? FileManager.default.createDirectory(atPath: hlsDir, withIntermediateDirectories: true)
        // Clean old segments
        if let files = try? FileManager.default.contentsOfDirectory(atPath: hlsDir) {
            for f in files { try? FileManager.default.removeItem(atPath: "\(hlsDir)/\(f)") }
        }

        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        proc.arguments = [
            "-y",
            "-i", "pipe:0",
            "-map", "0:v:0", "-map", "0:a:0",
            "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
            "-b:v", "3M", "-maxrate", "3M", "-bufsize", "6M",
            "-c:a", "aac", "-b:a", "128k",
            "-f", "hls",
            "-hls_time", "2",
            "-hls_list_size", "5",
            "-hls_flags", "delete_segments",
            "-hls_segment_filename", "\(hlsDir)/seg%d.ts",
            "\(hlsDir)/playlist.m3u8"
        ]
        proc.standardInput = pipe
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        ffmpegPipe = pipe
        ffmpegProcess = proc

        do {
            try proc.run()
            print("[HLS] ffmpeg started (MPEG-2 -> H.264)")
        } catch {
            print("[HLS] ffmpeg failed to start: \(error)")
            // Try /usr/local/bin/ffmpeg as fallback
            proc.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
            do {
                try proc.run()
                print("[HLS] ffmpeg started from /usr/local/bin")
            } catch {
                print("[HLS] ffmpeg not found. Browser playback unavailable.")
                ffmpegProcess = nil
                ffmpegPipe = nil
            }
        }
    }

    func stopFFmpeg() {
        if let proc = ffmpegProcess, proc.isRunning {
            ffmpegPipe?.fileHandleForWriting.closeFile()
            proc.terminate()
            proc.waitUntilExit()
            print("[HLS] ffmpeg stopped")
        }
        ffmpegProcess = nil
        ffmpegPipe = nil
    }

    /// Clear HLS state (used on channel change)
    func clearSegments() {
        stopFFmpeg()
        if let files = try? FileManager.default.contentsOfDirectory(atPath: hlsDir) {
            for f in files { try? FileManager.default.removeItem(atPath: "\(hlsDir)/\(f)") }
        }
    }

    // MARK: - Feed TS Data

    private var feedLogCounter = 0

    func feedTSData(_ data: Data) {
        // Feed to raw stream clients
        clientsLock.lock()
        var disconnected: [Int] = []
        for (i, client) in clients.enumerated() {
            if client.wantsStream {
                let sent = data.withUnsafeBytes { buf in
                    Darwin.send(client.socket, buf.baseAddress!, data.count, 0)
                }
                if sent < 0 {
                    disconnected.append(i)
                } else {
                    feedLogCounter += 1
                    if feedLogCounter <= 3 || feedLogCounter % 500 == 0 {
                        let count = clients.filter { $0.wantsStream }.count
                        print("[HTTP] Sent \(sent) bytes (total: \(feedLogCounter), clients: \(count))")
                    }
                }
            }
        }
        for i in disconnected.reversed() {
            close(clients[i].socket)
            clients.remove(at: i)
        }
        clientsLock.unlock()

        // Feed to ffmpeg for HLS transcoding
        if let pipe = ffmpegPipe {
            data.withUnsafeBytes { buf in
                if let ptr = buf.baseAddress {
                    pipe.fileHandleForWriting.write(Data(bytes: ptr, count: data.count))
                }
            }
        }
    }

    // MARK: - Accept Loop

    private func acceptLoop() {
        while running {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverSocket, sockPtr, &addrLen)
                }
            }
            guard clientSocket >= 0 else { continue }

            var noSigPipe: Int32 = 1
            setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleConnection(clientSocket)
            }
        }
    }

    // MARK: - Handle HTTP Request

    private func handleConnection(_ sock: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(sock, &buf, buf.count, 0)
        guard n > 0 else { close(sock); return }

        let request = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
        let firstLine = request.split(separator: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { close(sock); return }

        let method = String(parts[0])
        let path = String(parts[1])

        switch (method, path) {
        case ("GET", "/stream"):
            handleStream(sock)

        case ("GET", "/stream.m3u"):
            handleM3U(sock)

        case ("GET", "/playlist.m3u8"):
            handleHLSFile(sock, filename: "playlist.m3u8", contentType: "application/vnd.apple.mpegurl")

        case ("GET", let p) where p.hasPrefix("/hls/") && p.hasSuffix(".ts"):
            let filename = String(p.dropFirst(5)) // remove "/hls/"
            handleHLSFile(sock, filename: filename, contentType: "video/mp2t")

        case ("GET", "/status"):
            handleStatus(sock)

        case ("GET", "/channels"):
            handleChannels(sock)

        case (_, let p) where p.hasPrefix("/tune/"):
            let chStr = p.replacingOccurrences(of: "/tune/", with: "")
            if let ch = Int(chStr) {
                currentChannel = ch
                onTuneRequest?(ch)
                sendJSON(sock, ["status": "ok", "channel": ch])
            } else {
                sendJSON(sock, ["status": "error", "message": "invalid channel"], code: 400)
            }

        case ("GET", "/"):
            handlePlayerPage(sock)

        default:
            sendResponse(sock, code: 404, contentType: "text/plain", body: "Not Found")
        }
    }

    // MARK: - Stream Handler (raw TS)

    private func handleStream(_ sock: Int32) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nCache-Control: no-cache\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        _ = header.withCString { send(sock, $0, header.utf8.count, 0) }

        let client = StreamClient(socket: sock, wantsStream: true)
        clientsLock.lock()
        clients.append(client)
        clientsLock.unlock()
    }

    private func handleM3U(_ sock: Int32) {
        let body = "#EXTM3U\n#EXTINF:-1,WanimochiTV CH\(currentChannel)\nhttp://localhost:\(port)/stream\n"
        let header = "HTTP/1.1 200 OK\r\nContent-Type: audio/x-mpegurl\r\nContent-Disposition: attachment; filename=\"wanimochi.m3u\"\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        _ = header.withCString { send(sock, $0, header.utf8.count, 0) }
        _ = body.withCString { send(sock, $0, body.utf8.count, 0) }
        close(sock)
    }

    // MARK: - HLS (serve ffmpeg output files)

    private func handleHLSFile(_ sock: Int32, filename: String, contentType: String) {
        let filePath = "\(hlsDir)/\(filename)"

        guard FileManager.default.fileExists(atPath: filePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            sendResponse(sock, code: 404, contentType: "text/plain", body: "Not ready")
            return
        }

        // For m3u8: rewrite segment paths to include /hls/ prefix
        if filename == "playlist.m3u8" {
            let m3u8 = String(data: data, encoding: .utf8) ?? ""
            let rewritten = m3u8.replacingOccurrences(of: "seg", with: "/hls/seg")
            sendResponse(sock, code: 200, contentType: contentType, body: rewritten)
            return
        }

        sendBinaryResponse(sock, code: 200, contentType: contentType, data: data)
    }

    // MARK: - API Handlers

    private func handleStatus(_ sock: Int32) {
        sendJSON(sock, [
            "channel": currentChannel,
            "signalStrength": signalStrength,
            "streaming": isStreaming
        ])
    }

    private func handleChannels(_ sock: Int32) {
        var channels: [[String: Any]] = []
        for ch in 13...62 {
            let freq = ch * 6000 + 395143
            channels.append(["channel": ch, "frequency_khz": freq])
        }
        sendJSON(sock, ["channels": channels])
    }

    // MARK: - Player Page

    private func handlePlayerPage(_ sock: Int32) {
        let html = """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>WanimochiTV</title>
        <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #0a0a0a; color: #e0e0e0; }
        .container { max-width: 960px; margin: 0 auto; padding: 16px; }
        h1 { text-align: center; font-size: 1.5em; margin: 12px 0; color: #fff; }
        #player-wrap {
            width: 100%; background: #000; border-radius: 8px; overflow: hidden;
            margin-bottom: 16px; aspect-ratio: 16/9; position: relative;
        }
        video { width: 100%; height: 100%; display: block; background: #000; }
        #overlay {
            position: absolute; top: 0; left: 0; right: 0; bottom: 0;
            display: flex; align-items: center; justify-content: center;
            color: #888; font-size: 1.1em; pointer-events: none; text-align: center; padding: 20px;
        }
        #status-bar {
            display: flex; justify-content: space-between; align-items: center;
            padding: 10px 16px; background: #1a1a1a; border-radius: 6px; margin-bottom: 12px;
        }
        #status-bar .ch { color: #2196f3; font-weight: bold; font-size: 1.2em; }
        #status-bar .signal { color: #4caf50; }
        .channels {
            display: grid; grid-template-columns: repeat(auto-fill, minmax(120px, 1fr));
            gap: 8px; margin-bottom: 16px;
        }
        .ch-btn {
            padding: 10px 8px; border: 1px solid #333; background: #1a1a1a;
            color: #ccc; border-radius: 6px; cursor: pointer; text-align: center;
            font-size: 0.85em; transition: all 0.15s;
        }
        .ch-btn:hover { background: #2a2a2a; border-color: #555; }
        .ch-btn.active { background: #1a3a5c; border-color: #2196f3; color: #fff; }
        .ch-btn .num { font-size: 1.1em; font-weight: bold; display: block; }
        .ch-btn .name { font-size: 0.8em; color: #999; }
        .ch-btn.active .name { color: #90caf9; }
        .urls { text-align: center; padding: 12px; background: #111; border-radius: 6px; font-size: 0.85em; color: #666; }
        .urls code { color: #4caf50; }
        .urls a { color: #4caf50; }
        </style>
        </head><body>
        <div class="container">
            <h1>WanimochiTV</h1>
            <div id="player-wrap">
                <video id="video" controls autoplay muted playsinline></video>
                <div id="overlay">Waiting for stream...</div>
            </div>
            <div id="status-bar">
                <span>CH <span class="ch" id="s-ch">--</span></span>
                <span>Signal: <span class="signal" id="s-sig">--</span>/100</span>
                <span id="s-state">--</span>
            </div>
            <div class="channels" id="channels"></div>
            <div class="urls">
                <a href="/stream.m3u">Open in VLC/IINA (raw MPEG-2)</a>
            </div>
        </div>

        <script src="https://cdn.jsdelivr.net/npm/hls.js@1"></script>
        <script>
        const video = document.getElementById('video');
        const overlay = document.getElementById('overlay');
        let currentCh = 0;
        let hls = null;

        function startPlayer() {
            if (hls) { hls.destroy(); hls = null; }
            video.removeAttribute('src');

            const url = '/playlist.m3u8';

            if (video.canPlayType('application/vnd.apple.mpegurl')) {
                // Safari / iOS: native HLS
                video.src = url;
                video.load();
                video.play().catch(() => {});
                video.onplaying = () => { overlay.style.display = 'none'; };
                video.onerror = () => {
                    overlay.textContent = 'Waiting for transcoder...';
                    setTimeout(startPlayer, 3000);
                };
            } else if (typeof Hls !== 'undefined' && Hls.isSupported()) {
                // Firefox / Chrome: hls.js
                hls = new Hls({
                    liveSyncDurationCount: 3,
                    liveMaxLatencyDurationCount: 6,
                    enableWorker: true,
                });
                hls.loadSource(url);
                hls.attachMedia(video);
                hls.on(Hls.Events.MANIFEST_PARSED, () => {
                    video.play().catch(() => {});
                    overlay.style.display = 'none';
                });
                hls.on(Hls.Events.ERROR, (e, data) => {
                    if (data.type === Hls.ErrorTypes.NETWORK_ERROR) {
                        overlay.textContent = 'Waiting for transcoder...';
                        hls.destroy(); hls = null;
                        setTimeout(startPlayer, 3000);
                    } else if (data.fatal) {
                        overlay.textContent = 'Playback error: ' + data.details;
                    }
                });
            } else {
                overlay.textContent = 'HLS not supported in this browser.';
            }
        }

        function tune(ch) {
            currentCh = ch;
            updateButtons();
            overlay.textContent = 'Tuning to CH ' + ch + '...';
            overlay.style.display = 'flex';
            if (hls) { hls.destroy(); hls = null; }
            video.removeAttribute('src');

            fetch('/tune/' + ch, {method: 'POST'}).then(r => r.json()).then(() => {
                setTimeout(startPlayer, 6000);
            });
        }

        function updateButtons() {
            document.querySelectorAll('.ch-btn').forEach(b => {
                b.classList.toggle('active', parseInt(b.dataset.ch) === currentCh);
            });
        }

        function updateStatus() {
            fetch('/status').then(r => r.json()).then(d => {
                currentCh = d.channel;
                document.getElementById('s-ch').textContent = d.channel || '--';
                document.getElementById('s-sig').textContent = d.signalStrength;
                document.getElementById('s-state').textContent = d.streaming ? 'Streaming' : 'Stopped';
                updateButtons();
            }).catch(() => {});
        }

        const channels = [
            {ch: 13, name: 'NHK\\u7DCF\\u5408'}, {ch: 14, name: 'NHK E\\u30C6\\u30EC'},
            {ch: 15, name: '\\u65E5\\u30C6\\u30EC'}, {ch: 16, name: 'TBS'},
            {ch: 17, name: '\\u30D5\\u30B8'}, {ch: 18, name: '\\u30C6\\u30EC\\u671D'},
            {ch: 20, name: '\\u30C6\\u30EC\\u6771'}, {ch: 21, name: 'MX'},
            {ch: 22, name: '\\u653E\\u9001\\u5927\\u5B66'}, {ch: 23, name: '\\u653E\\u59272'},
            {ch: 24, name: '\\u30D5\\u30B82'}, {ch: 25, name: 'MX2'},
            {ch: 26, name: '\\u65E5\\u30C6\\u30EC2'}, {ch: 27, name: 'NHK\\u7DCF\\u54082'},
        ];
        const container = document.getElementById('channels');
        channels.forEach(c => {
            const btn = document.createElement('div');
            btn.className = 'ch-btn';
            btn.dataset.ch = c.ch;
            btn.innerHTML = '<span class="num">' + c.ch + '</span><span class="name">' + c.name + '</span>';
            btn.onclick = () => tune(c.ch);
            container.appendChild(btn);
        });

        setInterval(updateStatus, 3000);
        updateStatus();
        setTimeout(startPlayer, 4000);
        </script>
        </body></html>
        """
        sendResponse(sock, code: 200, contentType: "text/html; charset=utf-8", body: html)
    }

    // MARK: - HTTP Response Helpers

    private func sendResponse(_ sock: Int32, code: Int, contentType: String, body: String) {
        let status: String
        switch code {
        case 200: status = "OK"
        case 400: status = "Bad Request"
        case 404: status = "Not Found"
        case 503: status = "Service Unavailable"
        default: status = "Error"
        }
        let response = "HTTP/1.1 \(code) \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n\(body)"
        _ = response.withCString { send(sock, $0, response.utf8.count, 0) }
        close(sock)
    }

    private func sendBinaryResponse(_ sock: Int32, code: Int, contentType: String, data: Data) {
        let header = "HTTP/1.1 \(code) OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        _ = header.withCString { send(sock, $0, header.utf8.count, 0) }
        data.withUnsafeBytes { buf in
            _ = Darwin.send(sock, buf.baseAddress!, data.count, 0)
        }
        close(sock)
    }

    private func sendJSON(_ sock: Int32, _ dict: [String: Any], code: Int = 200) {
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            sendResponse(sock, code: code, contentType: "application/json", body: json)
        }
    }
}

private struct StreamClient {
    let socket: Int32
    let wantsStream: Bool
}
