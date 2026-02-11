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

    /// Stacked mode: number of device input buffers to skip before tap buffers
    private var stackedInputOffset: Int = 0
    private var isStacked: Bool = false

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

        // Get default output device info
        guard let outputDevID = getDefaultOutputDeviceID(),
              let outputDeviceUID = getDeviceUID(outputDevID) else {
            dlog("ERROR: getDefaultOutputDeviceUID")
            cleanup()
            return false
        }

        let outName = getDeviceName(outputDevID)
        let outTransport = getTransportType(outputDevID)
        let outRate = readSampleRate(deviceID: outputDevID)
        dlog("Output device: \(outName) (id=\(outputDevID), transport=\(outTransport), rate=\(outRate ?? 0))")

        // Create aggregate device with tap (stacked mode for better Bluetooth clock sync)
        let isBT = outTransport == kAudioDeviceTransportTypeBluetooth
                 || outTransport == kAudioDeviceTransportTypeBluetoothLE
        dlog("Using stacked=\(isBT) mode")

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TeamsVolume-Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: isBT,
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

        // Match aggregate sample rate to output device
        if let targetRate = outRate {
            let aggRate = readSampleRate(deviceID: aggregateDeviceID)
            dlog("Aggregate rate=\(aggRate ?? 0), output rate=\(targetRate)")
            if aggRate != targetRate {
                dlog("Setting aggregate sample rate to \(targetRate)")
                setSampleRate(deviceID: aggregateDeviceID, sampleRate: targetRate)
                CFRunLoopRunInMode(.defaultMode, 0.1, false)
            }
        }

        // Match buffer size to output device (never override Bluetooth native size)
        let outBuf = readBufferFrameSize(deviceID: outputDevID)
        let aggBuf = readBufferFrameSize(deviceID: aggregateDeviceID)
        dlog("Buffer sizes: output=\(outBuf), aggregate=\(aggBuf)")
        if outBuf > 0 && aggBuf != outBuf {
            dlog("Setting aggregate buffer to \(outBuf) to match output device")
            setBufferFrameSize(deviceID: aggregateDeviceID, size: outBuf)
        }

        // Set clock source to the output device for better sync
        setClockSource(aggregateID: aggregateDeviceID, masterUID: outputDeviceUID)

        // Store stacked mode info for processAudio
        isStacked = isBT
        if isBT {
            stackedInputOffset = countInputChannels(deviceID: outputDevID)
            dlog("Stacked input offset=\(stackedInputOffset) (device input channels)")
        } else {
            stackedInputOffset = 0
        }

        // Compute ramp coefficient from device sample rate
        if let sampleRate = readSampleRate(deviceID: aggregateDeviceID) {
            rampCoefficient = 1 - exp(-1 / (Float(sampleRate) * 0.030))
            dlog("Final aggregate rate=\(sampleRate), rampCoeff=\(rampCoefficient)")
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

        // Log buffer format on first callback
        if callbackCount == 1 {
            dlog("IO callback #1: inBufs=\(inputBuffers.count), outBufs=\(outputBuffers.count), stacked=\(isStacked), offset=\(stackedInputOffset)")
            for i in 0..<inputBuffers.count {
                let b = inputBuffers[i]
                dlog("  in[\(i)]: channels=\(b.mNumberChannels), bytes=\(b.mDataByteSize), data=\(b.mData != nil)")
            }
            for i in 0..<outputBuffers.count {
                let b = outputBuffers[i]
                dlog("  out[\(i)]: channels=\(b.mNumberChannels), bytes=\(b.mDataByteSize), data=\(b.mData != nil)")
            }
        }

        // In stacked mode, input buffers are: [device_input..., tap...]
        // We skip device input buffers and read from tap buffers
        let inputOffset = isStacked ? stackedInputOffset : 0

        for outputIndex in 0..<outputBuffers.count {
            let outputBuffer = outputBuffers[outputIndex]
            guard let outputData = outputBuffer.mData else { continue }

            let inputIndex = outputIndex + inputOffset
            guard inputIndex < inputBuffers.count,
                  let inputData = inputBuffers[inputIndex].mData else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(inputBuffers[inputIndex].mDataByteSize) / MemoryLayout<Float>.size
            let outSampleCount = Int(outputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            let count = min(sampleCount, outSampleCount)

            // Fast path: volume at 100%, just copy
            if targetVol >= 0.999 && currentVol >= 0.999 {
                memcpy(outputData, inputData, count * MemoryLayout<Float>.size)
                // Zero any remaining output samples
                if outSampleCount > count {
                    let remaining = (outSampleCount - count) * MemoryLayout<Float>.size
                    memset(outputData.advanced(by: count * MemoryLayout<Float>.size), 0, remaining)
                }
                for i in 0..<count {
                    let absVal = abs(inputSamples[i])
                    if absVal > maxPeak { maxPeak = absVal }
                }
            } else {
                for i in 0..<count {
                    currentVol += (targetVol - currentVol) * ramp
                    outputSamples[i] = inputSamples[i] * currentVol
                    let absVal = abs(inputSamples[i])
                    if absVal > maxPeak { maxPeak = absVal }
                }
                // Zero remaining
                for i in count..<outSampleCount {
                    outputSamples[i] = 0
                }
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

    func getDefaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    private func getDeviceUID(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? uid as String : nil
    }

    private func getDeviceName(_ deviceID: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? name as String : "unknown"
    }

    func getTransportType(_ deviceID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return transport
    }

    private func setSampleRate(deviceID: AudioObjectID, sampleRate: Float64) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = sampleRate
        AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                   UInt32(MemoryLayout<Float64>.size), &rate)
    }

    private func readBufferFrameSize(deviceID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bufSize: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &bufSize)
        return bufSize
    }

    private func setBufferFrameSize(deviceID: AudioObjectID, size bufFrames: UInt32) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var val = bufFrames
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                                UInt32(MemoryLayout<UInt32>.size), &val)
        dlog("setBufferFrameSize(\(bufFrames)): \(status == noErr ? "OK" : "ERR \(status)")")
    }

    private func countInputChannels(deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
            return 0
        }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func setClockSource(aggregateID: AudioObjectID, masterUID: String) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyMainSubDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = masterUID as CFString
        let status = withUnsafePointer(to: &uid) { ptr in
            AudioObjectSetPropertyData(aggregateID, &address, 0, nil,
                                       UInt32(MemoryLayout<CFString>.size), UnsafeMutableRawPointer(mutating: ptr))
        }
        dlog("setClockSource(\(masterUID)): \(status == noErr ? "OK" : "ERR \(status)")")
    }

    private func getDefaultOutputDeviceUID() -> String? {
        guard let devID = getDefaultOutputDeviceID() else { return nil }
        return getDeviceUID(devID)
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
    private var outputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var isReconnecting = false

    private var permissionCheckTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        dlog("=== TeamsVolume launched ===")

        permissionGranted = AudioTapEngine.hasPermission
        dlog("Permission: \(permissionGranted)")

        setupMenuBar()

        if permissionGranted {
            startPolling()
            registerOutputDeviceChangeListener()
        } else {
            AudioTapEngine.requestPermission()
            // Poll for permission grant (user may grant in System Settings)
            permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                guard let self = self else { timer.invalidate(); return }
                if AudioTapEngine.hasPermission {
                    timer.invalidate()
                    self.permissionCheckTimer = nil
                    self.permissionGranted = true
                    dlog("Permission granted!")
                    self.startPolling()
                    self.registerOutputDeviceChangeListener()
                    self.updateIcon()
                }
            }
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
        if let block = outputDeviceListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                block
            )
        }
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

    // MARK: - Audio Device Change Handling

    private func registerOutputDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        outputDeviceListenerBlock = { [weak self] (_, _) in
            DispatchQueue.main.async {
                self?.handleOutputDeviceChanged()
            }
        }

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            outputDeviceListenerBlock!
        )
    }

    private func handleOutputDeviceChanged() {
        dlog("Output device changed")
        guard isConnected, currentPID > 0, !isReconnecting else { return }
        isReconnecting = true

        let pid = currentPID
        engine.stop()
        isConnected = false

        // Bluetooth devices need more time to settle their audio stack
        var delay = 0.5
        if let devID = engine.getDefaultOutputDeviceID() {
            let transport = engine.getTransportType(devID)
            let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth
                           || transport == kAudioDeviceTransportTypeBluetoothLE
            if isBluetooth {
                delay = 3.0
                dlog("Bluetooth device detected, using \(delay)s delay")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.isReconnecting = false

            if self.engine.start(pid: pid) {
                self.isConnected = true
                self.currentPID = pid
                self.engine.volume = Float(self.volumePercent) / 100.0
                dlog("Reconnected after device change pid=\(pid)")
            } else {
                self.currentPID = 0
                dlog("Failed to reconnect after device change")
            }
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkTeamsStatus()
        }
        checkTeamsStatus()
    }

    private var lastLoggedCallbackCount: Int = 0

    private func checkTeamsStatus() {
        guard !isReconnecting else { return }

        // Log audio activity periodically
        if isConnected {
            let cc = engine.callbackCount
            let peak = engine.peakLevel
            if cc != lastLoggedCallbackCount {
                dlog("Audio status: callbacks=\(cc), peak=\(peak), active=\(engine.active)")
                lastLoggedCallbackCount = cc
            } else if cc == 0 {
                dlog("WARNING: No IO callbacks yet, active=\(engine.active)")
            }
        }

        // Detect dead tap: engine reports inactive but we think we're connected
        if isConnected && !engine.active {
            dlog("Dead tap detected, reconnecting...")
            isConnected = false
            engine.stop()
            // Fall through to reconnect below
        }

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
