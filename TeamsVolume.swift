import Cocoa
import CoreAudio
import AudioToolbox

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

    /// Ramp coefficient for click-free volume changes (~30ms ramp at 48kHz)
    private let rampCoefficient: Float = 0.001

    var active: Bool { isActive }

    func start(pid: pid_t) -> Bool {
        guard !isActive else { return true }

        // Translate PID to AudioObjectID
        guard let processObjectID = translatePIDToAudioObject(pid: pid) else {
            print("Failed to translate PID \(pid) to AudioObjectID")
            return false
        }

        // Create tap description
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .mutedWhenTapped

        // Create the process tap
        var newTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
        guard status == noErr else {
            print("Failed to create process tap: \(status)")
            return false
        }
        tapID = newTapID

        // Get tap UID
        guard let tapUID = getTapUID(tapID: tapID) else {
            print("Failed to get tap UID")
            cleanup()
            return false
        }

        // Get default output device UID
        guard let outputDeviceUID = getDefaultOutputDeviceUID() else {
            print("Failed to get default output device UID")
            cleanup()
            return false
        }

        // Create aggregate device
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TeamsVolume-Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceClockDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID
                ]
            ]
        ]

        var newAggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard status == noErr else {
            print("Failed to create aggregate device: \(status)")
            cleanup()
            return false
        }
        aggregateDeviceID = newAggregateID

        // Wait for the aggregate device to be ready
        usleep(500_000) // 500ms

        // Create IO Proc
        let queue = DispatchQueue(label: "com.teamsvolume.audio", qos: .userInteractive)
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, queue) {
            [weak self] _, inInputData, _, outOutputData, _ in
            self?.processAudio(inInputData, to: outOutputData)
        }
        guard status == noErr, let procID = procID else {
            print("Failed to create IO proc: \(status)")
            cleanup()
            return false
        }
        deviceProcID = procID

        // Start the IO proc
        status = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard status == noErr else {
            print("Failed to start audio device: \(status)")
            cleanup()
            return false
        }

        isActive = true
        currentVolume = volume
        print("Audio tap started for PID \(pid)")
        return true
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        cleanup()
        print("Audio tap stopped")
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

        let inputCount = inputBuffers.count
        let outputCount = outputBuffers.count

        for outputIndex in 0..<outputCount {
            let outputBuffer = outputBuffers[outputIndex]
            guard let outputData = outputBuffer.mData else { continue }

            // Route: if more inputs than outputs, use the last N inputs
            let inputIndex: Int
            if inputCount > outputCount {
                inputIndex = inputCount - outputCount + outputIndex
            } else {
                inputIndex = outputIndex
            }

            guard inputIndex < inputCount else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let inputBuffer = inputBuffers[inputIndex]
            guard let inputData = inputBuffer.mData else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size

            for i in 0..<sampleCount {
                currentVol += (targetVol - currentVol) * ramp
                outputSamples[i] = inputSamples[i] * currentVol
            }
        }

        currentVolume = currentVol
    }

    // MARK: - Core Audio Helpers

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

    private func getTapUID(tapID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var uid: CFString = "" as CFString

        let status = withUnsafeMutablePointer(to: &uid) { uidPtr in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, uidPtr)
        }

        guard status == noErr else { return nil }
        return uid as String
    }

    private func getDefaultOutputDeviceUID() -> String? {
        // Get default output device
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceID
        )
        guard status == noErr else { return nil }

        // Get device UID
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
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-f", name]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    try? task.run()
    task.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !output.isEmpty else {
        return nil
    }

    // Take the first PID
    let firstLine = output.components(separatedBy: "\n").first ?? output
    return pid_t(firstLine)
}

// MARK: - Menu Bar App

class TeamsVolumeDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engine = AudioTapEngine()
    private var pollTimer: Timer?
    private var isConnected = false
    private var currentPID: pid_t = 0
    private var volumePercent: Int = 100

    // Menu items
    private var statusMenuItem: NSMenuItem!
    private var sliderMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseDown, .rightMouseUp])

        updateIcon()
        startPolling()
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

        // Status line
        let statusText = isConnected
            ? "Microsoft Teams (connected)"
            : "Microsoft Teams (searching...)"
        statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Volume slider
        let sliderView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))

        let label = NSTextField(labelWithString: "\(volumePercent)%")
        label.frame = NSRect(x: 165, y: 5, width: 35, height: 20)
        label.alignment = .right
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.tag = 100
        sliderView.addSubview(label)

        let slider = NSSlider(value: Double(volumePercent), minValue: 0, maxValue: 100,
                              target: self, action: #selector(sliderChanged(_:)))
        slider.frame = NSRect(x: 15, y: 5, width: 145, height: 20)
        slider.isContinuous = true
        sliderView.addSubview(slider)

        sliderMenuItem = NSMenuItem()
        sliderMenuItem.view = sliderView
        menu.addItem(sliderMenuItem)

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

    @objc private func sliderChanged(_ sender: NSSlider) {
        volumePercent = Int(sender.doubleValue)
        engine.volume = Float(volumePercent) / 100.0
        updateIcon()

        // Update label in the slider's parent view
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
        if volumePercent == 0 {
            symbolName = "speaker.slash.fill"
        } else if volumePercent < 33 {
            symbolName = "speaker.wave.1.fill"
        } else if volumePercent < 66 {
            symbolName = "speaker.wave.2.fill"
        } else {
            symbolName = "speaker.wave.3.fill"
        }
        let image = NSImage(systemSymbolName: symbolName,
                            accessibilityDescription: "Volume")
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.image = image?.withSymbolConfiguration(config)
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkTeamsStatus()
        }
        // Also check immediately
        checkTeamsStatus()
    }

    private func checkTeamsStatus() {
        if let pid = findProcessPID(name: "Microsoft Teams") {
            if !isConnected || pid != currentPID {
                // Teams found (or restarted), connect tap
                engine.stop()
                if engine.start(pid: pid) {
                    isConnected = true
                    currentPID = pid
                    engine.volume = Float(volumePercent) / 100.0
                } else {
                    isConnected = false
                    currentPID = 0
                }
            }
        } else {
            if isConnected {
                // Teams quit, disconnect tap
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
