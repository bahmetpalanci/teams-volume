import Cocoa
import CoreAudio
import AudioToolbox
import CoreGraphics

// MARK: - Logger

final class Logger {
    static let shared = Logger()
    private let handle: FileHandle?
    private init() {
        let path = "/tmp/teamsvolume-debug.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }
    func log(_ msg: String) {
        let line = "\(Date()): \(msg)\n"
        if let data = line.data(using: .utf8) {
            handle?.write(data)
            handle?.synchronizeFile()
        }
    }
}

func dlog(_ msg: String) { Logger.shared.log(msg) }

// MARK: - Core Audio Tap Engine

final class AudioTapEngine {
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var deviceProcID: AudioDeviceIOProcID?
    private var isActive = false

    /// Volume gain factor (0.0 = silent, 1.0 = full volume)
    var volume: Float = 1.0

    /// Current ramped volume (used in audio callback for smooth transitions)
    private var currentVolume: Float = 1.0

    /// Ramp coefficient for click-free volume changes
    private var rampCoefficient: Float = 0.0007

    var active: Bool { isActive }

    /// Callback count for status display
    nonisolated(unsafe) var callbackCount: Int = 0

    /// Peak level for status display
    nonisolated(unsafe) var peakLevel: Float = 0.0

    static var hasPermission: Bool {
        return CGPreflightScreenCaptureAccess()
    }

    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    func start(pid: pid_t) -> Bool {
        guard !isActive else { return true }

        dlog("start(pid=\(pid))")

        // Translate PID to AudioObjectID
        guard let processObjectID = translatePIDToAudioObject(pid: pid) else {
            dlog("ERROR: translatePID failed")
            return false
        }

        // Create tap description
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        let tapUUID = UUID()
        tapDesc.uuid = tapUUID
        tapDesc.muteBehavior = .mutedWhenTapped

        // Create the process tap
        var newTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
        guard status == noErr else {
            dlog("ERROR: CreateProcessTap \(status)")
            return false
        }
        tapID = newTapID

        // Get default output device UID
        guard let outputDeviceUID = getDefaultOutputDeviceUID() else {
            dlog("ERROR: getDefaultOutputDeviceUID")
            cleanup()
            return false
        }

        // Create aggregate device with tap (non-stacked, AudioCap-style)
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TeamsVolume-Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]

        var newAggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard status == noErr else {
            dlog("ERROR: CreateAggregateDevice \(status)")
            cleanup()
            return false
        }
        aggregateDeviceID = newAggregateID

        // Wait for device ready
        guard waitForDeviceReady(deviceID: aggregateDeviceID, timeout: 3.0) else {
            dlog("ERROR: waitForDeviceReady timeout")
            cleanup()
            return false
        }

        // Compute ramp coefficient from device sample rate
        if let sampleRate = readSampleRate(deviceID: aggregateDeviceID) {
            rampCoefficient = 1 - exp(-1 / (Float(sampleRate) * 0.030))
        }

        // Create IO Proc
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil) {
            [weak self] _, inInputData, _, outOutputData, _ in
            self?.processAudio(inInputData, to: outOutputData)
        }
        guard status == noErr, let procID = procID else {
            dlog("ERROR: CreateIOProcIDWithBlock \(status)")
            cleanup()
            return false
        }
        deviceProcID = procID

        // Start the IO proc
        status = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard status == noErr else {
            dlog("ERROR: AudioDeviceStart \(status)")
            cleanup()
            return false
        }

        isActive = true
        currentVolume = volume
        callbackCount = 0
        peakLevel = 0.0
        dlog("Tap started, volume=\(volume)")
        return true
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        dlog("Tap stopped")
        cleanup()
    }

    private func cleanup() {
        let aggID = aggregateDeviceID
        let procID = deviceProcID
        let tap = tapID

        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        deviceProcID = nil
        tapID = AudioObjectID(kAudioObjectUnknown)

        if let procID = procID, aggID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
        }
        if aggID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tap != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    private func processAudio(
        _ inputBufferList: UnsafePointer<AudioBufferList>,
        to outputBufferList: UnsafeMutablePointer<AudioBufferList>
    ) {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputBufferList)
        let inputBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputBufferList)
        )

        let targetVol = volume
        var currentVol = currentVolume
        let ramp = rampCoefficient
        var maxPeak: Float = 0.0

        callbackCount += 1

        for outputIndex in 0..<outputBuffers.count {
            let outputBuffer = outputBuffers[outputIndex]
            guard let outputData = outputBuffer.mData else { continue }

            // Non-stacked: input and output buffers map 1:1
            guard outputIndex < inputBuffers.count,
                  let inputData = inputBuffers[outputIndex].mData else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(inputBuffers[outputIndex].mDataByteSize) / MemoryLayout<Float>.size

            for i in 0..<sampleCount {
                currentVol += (targetVol - currentVol) * ramp
                outputSamples[i] = inputSamples[i] * currentVol
                let absVal = abs(inputSamples[i])
                if absVal > maxPeak { maxPeak = absVal }
            }
        }

        currentVolume = currentVol
        if maxPeak > peakLevel { peakLevel = maxPeak }
    }

    // MARK: - Core Audio Helpers

    private func waitForDeviceReady(deviceID: AudioObjectID, timeout: TimeInterval) -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isAlive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isAlive)
            if status == noErr && isAlive != 0 {
                return true
            }
            CFRunLoopRunInMode(.defaultMode, 0.01, false)
        }
        return false
    }

    private func readSampleRate(deviceID: AudioObjectID) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        return status == noErr ? sampleRate : nil
    }

    private func translatePIDToAudioObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var objectID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

        let status = withUnsafePointer(to: &pidValue) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qualifierSize,
                pidPtr,
                &size,
                &objectID
            )
        }

        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        return objectID
    }

    private func getDefaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else { return nil }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)

        status = withUnsafeMutablePointer(to: &uid) { uidPtr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, uidPtr)
        }

        guard status == noErr else { return nil }
        return uid as String
    }

    deinit {
        stop()
    }
}

// MARK: - Process Finder

func findProcessPID(name: String) -> pid_t? {
    for args in [["-x", name], ["-f", name]] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            continue
        }

        let firstLine = output.components(separatedBy: "\n").first ?? output
        if let pid = pid_t(firstLine) {
            return pid
        }
    }
    return nil
}

// MARK: - Menu Bar App

class TeamsVolumeDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engine = AudioTapEngine()
    private var pollTimer: Timer?
    private var isConnected = false
    private var currentPID: pid_t = 0
    private var volumePercent: Int = 100
    private var permissionGranted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        dlog("=== TeamsVolume launched ===")

        permissionGranted = AudioTapEngine.hasPermission
        dlog("Permission: \(permissionGranted)")

        if !permissionGranted {
            AudioTapEngine.requestPermission()
        }

        setupMenuBar()

        if permissionGranted {
            startPolling()
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseDown, .rightMouseUp])

        updateIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showQuitMenu()
        } else {
            showVolumeMenu()
        }
    }

    private func showVolumeMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 220

        if !permissionGranted {
            let permItem = NSMenuItem(title: "Permission required", action: nil, keyEquivalent: "")
            permItem.isEnabled = false
            menu.addItem(permItem)

            let openSettings = NSMenuItem(title: "Open System Settings...",
                                          action: #selector(openPermissionSettings),
                                          keyEquivalent: "")
            openSettings.target = self
            menu.addItem(openSettings)
        } else {
            // Status line
            let statusText = isConnected
                ? "Microsoft Teams (connected)"
                : "Microsoft Teams (searching...)"
            let statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
            statusMenuItem.isEnabled = false
            menu.addItem(statusMenuItem)

            menu.addItem(NSMenuItem.separator())

            // Volume slider
            let sliderView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 24))

            let slider = NSSlider(value: Double(volumePercent), minValue: 0, maxValue: 100,
                                  target: self, action: #selector(sliderChanged(_:)))
            slider.frame = NSRect(x: 20, y: 2, width: 140, height: 20)
            slider.isContinuous = true
            sliderView.addSubview(slider)

            let label = NSTextField(labelWithString: "\(volumePercent)%")
            label.frame = NSRect(x: 166, y: 2, width: 40, height: 20)
            label.alignment = .left
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.tag = 100
            sliderView.addSubview(label)

            let sliderMenuItem = NSMenuItem()
            sliderMenuItem.view = sliderView
            menu.addItem(sliderMenuItem)
        }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit TeamsVolume", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        if let button = statusItem.button {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.height + 5),
                       in: button)
        }
    }

    @objc private func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        volumePercent = Int(sender.doubleValue)
        engine.volume = Float(volumePercent) / 100.0
        updateIcon()

        if let view = sender.superview,
           let label = view.viewWithTag(100) as? NSTextField {
            label.stringValue = "\(volumePercent)%"
        }
    }

    private func showQuitMenu() {
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit TeamsVolume", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        if let button = statusItem.button {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.height + 5),
                       in: button)
        }
    }

    @objc private func quit() {
        engine.stop()
        NSApplication.shared.terminate(nil)
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbolName: String
        if !permissionGranted {
            symbolName = "speaker.badge.exclamationmark.fill"
        } else if volumePercent == 0 {
            symbolName = "speaker.slash.fill"
        } else if volumePercent < 33 {
            symbolName = "speaker.wave.1.fill"
        } else if volumePercent < 66 {
            symbolName = "speaker.wave.2.fill"
        } else {
            symbolName = "speaker.wave.3.fill"
        }
        let image = NSImage(systemSymbolName: symbolName,
                            accessibilityDescription: "TeamsVolume")
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.image = image?.withSymbolConfiguration(config)
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkTeamsStatus()
        }
        checkTeamsStatus()
    }

    private func checkTeamsStatus() {
        if let pid = findProcessPID(name: "MSTeams") {
            if !isConnected || pid != currentPID {
                engine.stop()
                if engine.start(pid: pid) {
                    isConnected = true
                    currentPID = pid
                    engine.volume = Float(volumePercent) / 100.0
                    dlog("Connected to Teams pid=\(pid)")
                } else {
                    isConnected = false
                    currentPID = 0
                }
            }
        } else {
            if isConnected {
                engine.stop()
                isConnected = false
                currentPID = 0
            }
        }
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = TeamsVolumeDelegate()
app.delegate = delegate
app.run()
