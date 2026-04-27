# WanimochiTV

WanimochiTV is a macOS companion app for GV-M2TV. It initializes the device, tunes an ISDB-T channel, decrypts MPEG-TS packets, and hands the decrypted TS stream directly to VLCKit through a local FIFO.

## Build

Install the VLCKit dependency, then open the generated workspace:

```sh
cd wanimochi-tv
pod install
open wanimochi-tv.xcworkspace
```

Build and run the `WanimochiTV` app target from Xcode.

## Playback Path

The in-app player does not use the local HTTP server. The current path is:

```text
GV-M2TV -> DriverKit -> StreamingEngine -> AES decrypt -> FIFO -> VLCKit
```

`TSHTTPServer.swift` is still present for the older browser/VLC-over-HTTP path, but the SwiftUI app now uses direct VLCKit playback.
