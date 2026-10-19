// MeetingRecorder — macOS menu bar app
// One click to record Zoom meetings: screen + system audio + mic
// No BlackHole, no Audio MIDI Setup, no config needed.
// Requires: Screen Recording + Microphone permission (prompted on first run)

import AppKit
import ScreenCaptureKit
import AVFoundation
import CoreMedia

// MARK: - Screen + system-audio recorder

@available(macOS 13.0, *)
class ScreenRecorder: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var started = false
    private let lock = NSLock()
    let tempURL: URL

    init(tempURL: URL) { self.tempURL = tempURL }

    func start(target: CaptureTarget? = nil) async throws {
        let content = try await SCShareableContent.current
        
        // Resolve display and filter from the capture target
        let display: SCDisplay
        let filter: SCContentFilter
        
        switch target {
        case .fullDisplay(let d):
            display = d
            // Exclude self so the menu bar app doesn't appear in the recording
            let selfApp = content.applications.first { $0.bundleIdentifier == "com.meetingrecorder.app" }
            let excluded = selfApp.map { [$0] } ?? []
            filter = SCContentFilter(display: d, excludingApplications: excluded, exceptingWindows: [])
            
        case .app(let app, let d):
            display = d
            // Capture only this app's windows — works regardless of focus / z-order
            let liveApp = content.applications.first { $0.processID == app.processID } ?? app
            filter = SCContentFilter(display: d, including: [liveApp], exceptingWindows: [])
            
        case nil:
            guard let d = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                       ?? content.displays.first else {
                throw NSError(domain: "rec", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No display found. Grant Screen Recording permission in System Settings."])
            }
            display = d
            filter = SCContentFilter(display: d, excludingApplications: [], exceptingWindows: [])
        }
        let cfg = SCStreamConfiguration()
        cfg.width  = display.width
        cfg.height = display.height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.capturesAudio = true
        cfg.sampleRate    = 44100
        cfg.channelCount  = 2
        cfg.showsCursor   = true

        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }
        assetWriter = try AVAssetWriter(outputURL: tempURL, fileType: .mov)

        let vidSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey:  display.width,
            AVVideoHeightKey: display.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 5_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: vidSettings)
        videoInput!.expectsMediaDataInRealTime = true
        assetWriter!.add(videoInput!)

        let audSettings: [String: Any] = [
            AVFormatIDKey:               kAudioFormatLinearPCM,
            AVSampleRateKey:             44100,
            AVNumberOfChannelsKey:       2,
            AVLinearPCMBitDepthKey:      16,
            AVLinearPCMIsFloatKey:       false,
            AVLinearPCMIsBigEndianKey:   false,
            AVLinearPCMIsNonInterleaved: false
        ]
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audSettings)
        audioInput!.expectsMediaDataInRealTime = true
        assetWriter!.add(audioInput!)

        stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream!.addStreamOutput(self, type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "sc.video"))
        try stream!.addStreamOutput(self, type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "sc.audio"))
        try await stream!.startCapture()
    }

    func stop() async {
        try? await stream?.stopCapture()
        await withCheckedContinuation { cont in
            assetWriter?.finishWriting { cont.resume() }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buf: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard buf.isValid else { return }
        lock.lock()
        if !started {
            assetWriter?.startWriting()
            assetWriter?.startSession(atSourceTime: buf.presentationTimeStamp)
            started = true
        }
        lock.unlock()
        switch type {
        case .screen: if videoInput?.isReadyForMoreMediaData == true { videoInput?.append(buf) }
        case .audio:  if audioInput?.isReadyForMoreMediaData == true { audioInput?.append(buf) }
        default: break
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("SCStream error: %@", error.localizedDescription)
    }
}

// MARK: - Mic recorder

class MicRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    let tempURL: URL
    init(tempURL: URL) { self.tempURL = tempURL }

    func start() throws {
        let input = engine.inputNode
        let fmt   = input.outputFormat(forBus: 0)
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }
        file = try AVAudioFile(forWriting: tempURL,
            settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            try? self?.file?.write(from: buf)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
    }
}

// MARK: - App Delegate

// MARK: - Capture target

@available(macOS 13.0, *)
enum CaptureTarget {
    case fullDisplay(SCDisplay)
    case app(SCRunningApplication, SCDisplay)  // app + the display it lives on
}

// MARK: - App Delegate

@available(macOS 13.0, *)
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var recordItem: NSMenuItem!
    private var statusLabel: NSMenuItem!
    private var captureParentItem: NSMenuItem!   // "Screen / App" top-level item
    private var captureSubmenu: NSMenu!

    private var screenRec: ScreenRecorder!
    private var micRec: MicRecorder!
    private var isRecording = false
    private var timer: Timer?
    private var elapsed: Int = 0
    private var outputURL: URL?

    private var captureTarget: CaptureTarget?    // what to record

    static let ffmpeg = "/Users/virgoh/.local/bin/ffmpeg"
    static let videoTemp = URL(fileURLWithPath: NSTemporaryDirectory() + "meeting_screen.mov")
    static let micTemp   = URL(fileURLWithPath: NSTemporaryDirectory() + "meeting_mic.wav")

    // MARK: - Icons

    private func micIcon() -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let img = NSImage(systemSymbolName: "mic", accessibilityDescription: "Record")!
            .withSymbolConfiguration(cfg)!
        img.isTemplate = true
        return img
    }

    private func recordingIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
            let p = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 10, height: 10))
            NSColor.systemRed.setFill(); p.fill(); return true
        }
        img.isTemplate = false; return img
    }

    // MARK: - Menu building

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = micIcon()
        statusItem.button?.imageScaling = .scaleProportionallyDown

        let menu = NSMenu()
        menu.delegate = self

        recordItem = NSMenuItem(title: "Start Recording",
                                action: #selector(toggleRecording), keyEquivalent: "")
        recordItem.target = self
        menu.addItem(recordItem)
        menu.addItem(.separator())

        captureParentItem = NSMenuItem(title: "Capture", action: nil, keyEquivalent: "")
        captureSubmenu = NSMenu()
        captureSubmenu.addItem(withTitle: "Checking permissions…",
                               action: nil, keyEquivalent: "")
        captureParentItem.submenu = captureSubmenu
        menu.addItem(captureParentItem)

        statusLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLabel.isEnabled = false
        menu.addItem(statusLabel)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu

        populateCaptureMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if !isRecording { populateCaptureMenu() }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if !isRecording { populateCaptureMenu() }
    }

    private func populateCaptureMenu() {
        Task {
            do {
                let content = try await SCShareableContent.current
                await MainActor.run { self.buildCaptureSubmenu(content: content) }
            } catch {
                await MainActor.run { self.showPermissionNeeded() }
            }
        }
    }

    private func showPermissionNeeded() {
        captureParentItem.title = "Capture: permission needed"
        captureSubmenu.removeAllItems()
        let grant = NSMenuItem(title: "Grant Screen Recording Access…",
                               action: #selector(openPrivacySettings), keyEquivalent: "")
        grant.target = self
        captureSubmenu.addItem(grant)
    }

    @objc private func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    private func buildCaptureSubmenu(content: SCShareableContent) {
        captureSubmenu.removeAllItems()
        let mainID = CGMainDisplayID()

        // --- Screens section ---
        captureSubmenu.addItem(sectionHeader("Screens"))
        for (i, display) in content.displays.enumerated() {
            let isMain = display.displayID == mainID
            let label = "Screen \(i+1)\(isMain ? " — Main" : "")  (\(display.width)×\(display.height))"
            let item = NSMenuItem(title: label,
                                  action: #selector(selectCaptureItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = CaptureTarget.fullDisplay(display)
            item.state = isCurrent(target: .fullDisplay(display)) ? .on : .off
            captureSubmenu.addItem(item)
        }

        // --- Apps section ---
        // Show only visible, non-system apps that have windows
        let interestingApps = content.applications
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { app in content.windows.contains { $0.owningApplication?.processID == app.processID } }
            .sorted { $0.applicationName < $1.applicationName }

        if !interestingApps.isEmpty {
            captureSubmenu.addItem(.separator())
            captureSubmenu.addItem(sectionHeader("App only (ignores focus)"))
            for app in interestingApps {
                // Find the display that holds this app's largest window
                let appDisplay = bestDisplay(for: app, in: content)
                let item = NSMenuItem(title: app.applicationName,
                                      action: #selector(selectCaptureItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = CaptureTarget.app(app, appDisplay)
                item.state = isCurrent(target: .app(app, appDisplay)) ? .on : .off
                captureSubmenu.addItem(item)
            }
        }

        // Default selection: main display if nothing chosen
        if captureTarget == nil, let mainDisplay = content.displays.first(where: { $0.displayID == mainID })
                                                ?? content.displays.first {
            captureTarget = .fullDisplay(mainDisplay)
            // Update checkmarks
            for item in captureSubmenu.items { item.state = isCurrent(target: item.representedObject as? CaptureTarget) ? .on : .off }
        }

        let label: String
        if let t = captureTarget {
            switch t {
            case .fullDisplay(let d): label = d.displayID == mainID ? "Capture: Screen (Main)" : "Capture: Screen"
            case .app(let a, _):      label = "Capture: \(a.applicationName)"
            }
        } else { label = "Capture" }
        captureParentItem.title = label
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor])
        return item
    }

    private func bestDisplay(for app: SCRunningApplication, in content: SCShareableContent) -> SCDisplay {
        let appWindows = content.windows.filter { $0.owningApplication?.processID == app.processID }
        let mainID = CGMainDisplayID()
        return content.displays.first { d in
            appWindows.contains { w in
                let wf = w.frame
                return wf.intersects(CGRect(x: 0, y: 0, width: CGFloat(d.width), height: CGFloat(d.height)))
            }
        } ?? content.displays.first(where: { $0.displayID == mainID }) ?? content.displays[0]
    }

    private func isCurrent(target: CaptureTarget?) -> Bool {
        guard let t = target, let c = captureTarget else { return false }
        switch (t, c) {
        case (.fullDisplay(let a), .fullDisplay(let b)): return a.displayID == b.displayID
        case (.app(let a, _), .app(let b, _)):           return a.processID == b.processID
        default: return false
        }
    }

    @objc private func selectCaptureItem(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? CaptureTarget else { return }
        captureTarget = target
        for item in captureSubmenu.items { item.state = isCurrent(target: item.representedObject as? CaptureTarget) ? .on : .off }
        // Update parent label
        switch target {
        case .fullDisplay(let d):
            captureParentItem.title = d.displayID == CGMainDisplayID() ? "Capture: Screen (Main)" : "Capture: Screen"
        case .app(let a, _):
            captureParentItem.title = "Capture: \(a.applicationName)"
        }
    }

    // MARK: - Recording

    @objc private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        let now = Date(); let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd_HHmmss"
        outputURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("meeting_\(fmt.string(from: now)).mp4")
        screenRec = ScreenRecorder(tempURL: AppDelegate.videoTemp)
        micRec    = MicRecorder(tempURL: AppDelegate.micTemp)

        Task {
            do {
                try self.micRec.start()
                try await self.screenRec.start(target: self.captureTarget)
                await MainActor.run {
                    self.isRecording = true; self.elapsed = 0
                    self.statusItem.button?.image = self.recordingIcon()
                    self.statusItem.button?.title = ""
                    self.recordItem.title = "Stop Recording"
                    self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                        guard let self else { return }
                        self.elapsed += 1
                        let m = self.elapsed/60, s = self.elapsed%60
                        self.statusLabel.title = String(format: "  %02d:%02d", m, s)
                    }
                }
            } catch {
                await MainActor.run { self.showError(error.localizedDescription) }
            }
        }
    }

    private func stopRecording() {
        guard let outURL = outputURL else { return }
        timer?.invalidate(); timer = nil
        isRecording = false
        statusItem.button?.image = micIcon()
        recordItem.title = "Start Recording"
        recordItem.isEnabled = false
        statusLabel.title = "  Saving…"

        Task {
            self.micRec.stop()
            await self.screenRec.stop()
            let merge = Process()
            merge.executableURL = URL(fileURLWithPath: AppDelegate.ffmpeg)
            merge.arguments = [
                "-y", "-loglevel", "error",
                "-i", AppDelegate.videoTemp.path,
                "-i", AppDelegate.micTemp.path,
                "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=first:dropout_transition=2[a]",
                "-map", "0:v", "-map", "[a]",
                "-vcodec", "copy", "-acodec", "aac", "-b:a", "192k",
                outURL.path
            ]
            try? merge.run(); merge.waitUntilExit()
            try? FileManager.default.removeItem(at: AppDelegate.videoTemp)
            try? FileManager.default.removeItem(at: AppDelegate.micTemp)

            await MainActor.run {
                self.statusItem.button?.image = self.micIcon()
                self.recordItem.title = "Start Recording"
                self.recordItem.isEnabled = true
                self.statusLabel.title = ""
                NSWorkspace.shared.selectFile(outURL.path, inFileViewerRootedAtPath: "")
                let n = NSUserNotification()
                n.title = "Recording saved"
                n.informativeText = outURL.lastPathComponent
                NSUserNotificationCenter.default.deliver(n)
            }
        }
    }

    private func showError(_ msg: String) {
        statusItem.button?.image = micIcon()
        recordItem.title = "Start Recording"
        statusLabel.title = "  Error: \(msg)"
    }
}

// MARK: - Entry point

guard #available(macOS 13.0, *) else {
    fatalError("Requires macOS 13+")
}
let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
