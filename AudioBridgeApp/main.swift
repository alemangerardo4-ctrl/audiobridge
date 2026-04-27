import Cocoa
import CoreAudio
import AudioToolbox
import UserNotifications

// MARK: - Driver constants

// The AudioBridge driver (forked from BlackHole) exposes devices with these
// UIDs and bundle ID. Detection by UID is more robust than by name match.
let kAudioBridgeBundleID = "design.publicworks.AudioBridge"
let kAudioBridgeUIDs: Set<String> = [
    "AudioBridge2ch_UID",
    "AudioBridge16ch_UID",
    "AudioBridge24ch_UID",
]

// MARK: - CoreAudio Helpers

func getAllDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
    guard status == noErr, dataSize > 0 else { return [] }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids)
    return ids
}

func getDeviceName(deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 256
    var buf = [CChar](repeating: 0, count: 256)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &buf) == noErr else { return nil }
    return String(cString: buf)
}

func getDeviceUID(deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<CFString?>.size)
    var uid: CFString? = nil
    let status = withUnsafeMutablePointer(to: &uid) {
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
    }
    guard status == noErr, let uid else { return nil }
    return uid as String
}

func deviceHasStreams(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
    return status == noErr && size > 0
}

func isAudioBridgeDevice(deviceID: AudioDeviceID) -> Bool {
    if let uid = getDeviceUID(deviceID: deviceID), kAudioBridgeUIDs.contains(uid) {
        return true
    }
    // Fallback: name match (covers any future device variants the driver may add)
    return getDeviceName(deviceID: deviceID)?.lowercased().hasPrefix("audiobridge") == true
}

func isAudioBridgeLoaded() -> Bool {
    getAllDeviceIDs().contains(where: isAudioBridgeDevice)
}

func findAudioBridgeDeviceID(channelHint: Int? = nil) -> AudioDeviceID? {
    let ids = getAllDeviceIDs()
    if let channelHint {
        let suffix = "\(channelHint)ch_UID"
        for id in ids {
            if let uid = getDeviceUID(deviceID: id), uid.hasPrefix("AudioBridge"), uid.hasSuffix(suffix) {
                return id
            }
        }
    }
    return ids.first(where: isAudioBridgeDevice)
}

func setDefaultInput(deviceID: AudioDeviceID) {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var mutableID = deviceID
    AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
        UInt32(MemoryLayout<AudioDeviceID>.size), &mutableID
    )
}

func setDefaultInputByName(_ deviceName: String) {
    for deviceID in getAllDeviceIDs() {
        guard let name = getDeviceName(deviceID: deviceID),
              name.lowercased().contains(deviceName.lowercased()) else { continue }
        setDefaultInput(deviceID: deviceID)
        return
    }
}

func getDefaultOutputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
    return deviceID
}

func getDefaultInputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
    return deviceID
}

func setDefaultOutput(deviceID: AudioDeviceID) {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var mutableID = deviceID
    AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
        UInt32(MemoryLayout<AudioDeviceID>.size), &mutableID
    )
}

func findAudioBridgeOutputDeviceID() -> AudioDeviceID? {
    for deviceID in getAllDeviceIDs() where isAudioBridgeDevice(deviceID: deviceID) {
        if deviceHasStreams(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput) {
            return deviceID
        }
    }
    return nil
}

// MARK: - Aggregate device helpers

// Multi-Output (stacked) aggregate: master + AudioBridge — mirrors output to both.
func createMonitorRecordAggregate(masterDeviceID: AudioDeviceID, bridgeDeviceID: AudioDeviceID) -> AudioDeviceID? {
    guard let masterUID = getDeviceUID(deviceID: masterDeviceID),
          let bridgeUID  = getDeviceUID(deviceID: bridgeDeviceID) else { return nil }

    let subDevices: [[String: Any]] = [
        [kAudioSubDeviceUIDKey as String: masterUID],
        [kAudioSubDeviceUIDKey as String: bridgeUID],
    ]
    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey            as String: "Monitor + Record",
        kAudioAggregateDeviceUIDKey             as String: "design.publicworks.AudioBridge.monitorrecord",
        kAudioAggregateDeviceSubDeviceListKey   as String: subDevices,
        kAudioAggregateDeviceMasterSubDeviceKey as String: masterUID,
        kAudioAggregateDeviceIsStackedKey       as String: 1,
    ]
    var aggregateID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
    guard status == noErr, aggregateID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
    return aggregateID
}

// Aggregate input: microphone + AudioBridge 2ch — single device that exposes
// mic channels and system-audio channels side-by-side. DAWs see one input.
func createVoicePlusSystemAggregate(micDeviceID: AudioDeviceID, bridgeDeviceID: AudioDeviceID) -> AudioDeviceID? {
    guard let micUID    = getDeviceUID(deviceID: micDeviceID),
          let bridgeUID = getDeviceUID(deviceID: bridgeDeviceID) else { return nil }

    let subDevices: [[String: Any]] = [
        [kAudioSubDeviceUIDKey as String: micUID],
        [kAudioSubDeviceUIDKey as String: bridgeUID],
    ]
    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey            as String: "Voice + System Audio",
        kAudioAggregateDeviceUIDKey             as String: "design.publicworks.AudioBridge.voiceplussystem",
        kAudioAggregateDeviceSubDeviceListKey   as String: subDevices,
        kAudioAggregateDeviceMasterSubDeviceKey as String: micUID,
        kAudioAggregateDeviceIsStackedKey       as String: 0,
    ]
    var aggregateID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
    guard status == noErr, aggregateID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
    return aggregateID
}

func destroyAggregateDevice(deviceID: AudioDeviceID) {
    AudioHardwareDestroyAggregateDevice(deviceID)
}

func postNotification(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body  = body
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
}

// MARK: - Recorder

// Records audio from a specific CoreAudio input device into a .m4a (AAC) file.
//
// Uses AUHAL (kAudioUnitSubType_HALOutput configured as input) bound directly
// to a chosen AudioDeviceID, with ExtAudioFile handling the AAC encode. This
// records from AudioBridge regardless of the system default input, so the
// user's mic is never disturbed.
final class Recorder {
    private var audioUnit: AudioUnit?
    private var extFile: ExtAudioFileRef?
    private var clientFormat = AudioStreamBasicDescription()
    private var renderBuffer: UnsafeMutableRawPointer?
    private var renderBufferBytes: Int = 0
    private(set) var url: URL?
    private(set) var startedAt: Date?

    var isRecording: Bool { audioUnit != nil }

    static var recordingsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Music/AudioBridge", isDirectory: true)
    }

    static func makeRecordingURL(date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale     = Locale(identifier: "en_US_POSIX")
        formatter.timeZone   = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "AudioBridge_\(formatter.string(from: date)).m4a"
        return recordingsDirectory.appendingPathComponent(name)
    }

    private static let inputCallback: AURenderCallback = { (
        inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _
    ) -> OSStatus in
        let recorder = Unmanaged<Recorder>.fromOpaque(inRefCon).takeUnretainedValue()
        return recorder.captureFrames(
            actionFlags: ioActionFlags,
            timeStamp: inTimeStamp,
            busNumber: inBusNumber,
            numberFrames: inNumberFrames
        )
    }

    func start(deviceID: AudioDeviceID) throws -> URL {
        var desc = AudioComponentDescription(
            componentType:         kAudioUnitType_Output,
            componentSubType:      kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags:        0,
            componentFlagsMask:    0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw rerr(-1, "AUHAL component not available.")
        }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au), "AudioComponentInstanceNew")
        guard let unit = au else { throw rerr(-1, "AudioUnit allocation failed.") }

        var enableInput: UInt32  = 1
        var disableOutput: UInt32 = 0
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &enableInput, UInt32(MemoryLayout.size(ofValue: enableInput))
        ), "EnableIO input")
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &disableOutput, UInt32(MemoryLayout.size(ofValue: disableOutput))
        ), "DisableIO output")

        var dev = deviceID
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &dev, UInt32(MemoryLayout<AudioDeviceID>.size)
        ), "CurrentDevice")

        var deviceFormat = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout.size(ofValue: deviceFormat))
        try check(AudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
            &deviceFormat, &fmtSize
        ), "Get device StreamFormat")

        let channels   = max(deviceFormat.mChannelsPerFrame, 1)
        let sampleRate = deviceFormat.mSampleRate > 0 ? deviceFormat.mSampleRate : 48_000
        var client     = AudioStreamBasicDescription()
        client.mSampleRate       = sampleRate
        client.mFormatID         = kAudioFormatLinearPCM
        client.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        client.mChannelsPerFrame = channels
        client.mBitsPerChannel   = 32
        client.mFramesPerPacket  = 1
        client.mBytesPerFrame    = 4 * channels
        client.mBytesPerPacket   = 4 * channels

        try check(AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &client, UInt32(MemoryLayout.size(ofValue: client))
        ), "Set client StreamFormat")

        let outURL = Recorder.makeRecordingURL()
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        try? FileManager.default.removeItem(at: outURL)

        var fileFormat = AudioStreamBasicDescription()
        fileFormat.mSampleRate       = sampleRate
        fileFormat.mFormatID         = kAudioFormatMPEG4AAC
        fileFormat.mChannelsPerFrame = channels
        fileFormat.mFramesPerPacket  = 1024

        var extRef: ExtAudioFileRef?
        try check(ExtAudioFileCreateWithURL(
            outURL as CFURL,
            kAudioFileM4AType,
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &extRef
        ), "ExtAudioFileCreateWithURL")
        guard let ext = extRef else { throw rerr(-1, "ExtAudioFile not created.") }

        try check(ExtAudioFileSetProperty(
            ext, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout.size(ofValue: client)), &client
        ), "Set ClientDataFormat")

        // Prime the encoder on a non-realtime thread before any render callback
        // tries to write — ExtAudioFileWriteAsync(0, nil) is the documented
        // priming idiom, and it must happen off the audio thread.
        try check(ExtAudioFileWriteAsync(ext, 0, nil), "Prime ExtAudioFile")

        var callback = AURenderCallbackStruct(
            inputProc: Recorder.inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout.size(ofValue: callback))
        ), "SetInputCallback")

        // Pre-allocate a render buffer big enough for any reasonable AUHAL slice.
        // 16384 frames * 8 bytes/frame (stereo float32) ≈ 128 KB; resized on
        // demand if the audio unit asks for more.
        renderBufferBytes = 16_384 * Int(client.mBytesPerFrame)
        renderBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: renderBufferBytes, alignment: 16
        )

        try check(AudioUnitInitialize(unit), "AudioUnitInitialize")
        try check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")

        self.audioUnit    = unit
        self.extFile      = ext
        self.clientFormat = client
        self.url          = outURL
        self.startedAt    = Date()
        return outURL
    }

    @discardableResult
    func stop() -> URL? {
        guard let unit = audioUnit else { return nil }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        if let ext = extFile {
            ExtAudioFileDispose(ext)
        }
        if let buf = renderBuffer {
            buf.deallocate()
        }
        let saved = url
        audioUnit = nil
        extFile = nil
        renderBuffer = nil
        renderBufferBytes = 0
        url = nil
        startedAt = nil
        return saved
    }

    fileprivate func captureFrames(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        numberFrames: UInt32
    ) -> OSStatus {
        guard let unit = audioUnit, let ext = extFile, var buffer = renderBuffer else {
            return noErr
        }
        let bytesNeeded = Int(numberFrames) * Int(clientFormat.mBytesPerFrame)
        if bytesNeeded > renderBufferBytes {
            // Grow the buffer if AUHAL ever asks for a bigger slice than we sized for.
            buffer.deallocate()
            renderBufferBytes = bytesNeeded
            buffer = UnsafeMutableRawPointer.allocate(byteCount: bytesNeeded, alignment: 16)
            renderBuffer = buffer
        }
        var bufList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: clientFormat.mChannelsPerFrame,
                mDataByteSize:   UInt32(bytesNeeded),
                mData:           buffer
            )
        )
        let renderStatus = AudioUnitRender(
            unit, actionFlags, timeStamp, busNumber, numberFrames, &bufList
        )
        if renderStatus != noErr { return renderStatus }
        return ExtAudioFileWriteAsync(ext, numberFrames, &bufList)
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr {
            throw rerr(Int(status), "\(what) failed (OSStatus \(status)).")
        }
    }

    private func rerr(_ code: Int, _ msg: String) -> NSError {
        NSError(domain: "AudioBridge.Recorder", code: code,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// MARK: - Menu bar icon

// Stepped square spiral, monochrome template — same shape as the
// publicworks.design favicon and the app icon. Path is normalized to an
// 8-unit space (the favicon's spiral only occupies the 4..12 sub-region
// of its 16-unit viewBox; renormalizing lets the mark fill the menu bar
// height with a small margin instead of floating in the middle).
func makeMenuBarIcon(active: Bool) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { _ in
        let strokeUnits: CGFloat = active ? 0.7 : 0.6
        // Reserve room for square stroke caps (extend half-stroke past the
        // path endpoints) so the spiral hugs the bounds without clipping.
        let span = size.width - 2.0
        let scale = span / (8 + strokeUnits)
        let inset = (size.width - 8 * scale) / 2

        let p: [(CGFloat, CGFloat)] = [
            (0, 0), (8, 0), (8, 8), (2, 8), (2, 2),
            (6, 2), (6, 6), (4, 6), (4, 4),
        ]
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: inset + x * scale, y: size.height - inset - y * scale)
        }

        let path = NSBezierPath()
        path.move(to: pt(p[0].0, p[0].1))
        for q in p.dropFirst() { path.line(to: pt(q.0, q.1)) }
        path.lineWidth     = strokeUnits * scale
        path.lineCapStyle  = .square
        path.lineJoinStyle = .miter

        NSColor.black.set()
        path.stroke()
        return true
    }
    image.isTemplate = true
    return image
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    var driverEnabled = false

    // Monitor + Record state
    var monitorRecordActive       = false
    var monitorRecordAggregateID: AudioDeviceID? = nil
    var originalDefaultOutputID:  AudioDeviceID? = nil

    // Voice + System Audio state
    var voicePlusSystemActive       = false
    var voicePlusSystemAggregateID: AudioDeviceID? = nil
    var originalDefaultInputID:    AudioDeviceID? = nil

    // Recording state
    let recorder = Recorder()
    var recordMenuItem: NSMenuItem?
    var recordingTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        driverEnabled = isAudioBridgeLoaded()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = makeMenuBarIcon(active: driverEnabled)
        }
        buildMenu()

        // React to device list changes (driver install/uninstall, hot-plugged audio)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            self?.refreshDriverState()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if recorder.isRecording {
            _ = recorder.stop()
        }
        if monitorRecordActive, let aggregateID = monitorRecordAggregateID {
            if let originalID = originalDefaultOutputID {
                setDefaultOutput(deviceID: originalID)
            }
            destroyAggregateDevice(deviceID: aggregateID)
        }
        if voicePlusSystemActive, let aggregateID = voicePlusSystemAggregateID {
            if let originalID = originalDefaultInputID {
                setDefaultInput(deviceID: originalID)
            }
            destroyAggregateDevice(deviceID: aggregateID)
        }
    }

    func refreshDriverState() {
        driverEnabled = isAudioBridgeLoaded()
        if let button = statusItem.button {
            button.image = makeMenuBarIcon(active: driverEnabled)
        }
        buildMenu()
    }

    func buildMenu() {
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "AudioBridge", action: nil, keyEquivalent: "")
        titleItem.attributedTitle = NSAttributedString(
            string: "AudioBridge",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let statusLabel = driverEnabled ? "Driver: detected" : "Driver: not installed"
        let statusItemRow = NSMenuItem(title: statusLabel, action: nil, keyEquivalent: "")
        statusItemRow.isEnabled = false
        menu.addItem(statusItemRow)
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(title: "Enable AudioBridge", action: #selector(toggleDriver(_:)), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state  = driverEnabled ? .on : .off
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        // Quick Profiles submenu
        let profilesItem = NSMenuItem(title: "Quick Profiles", action: nil, keyEquivalent: "")
        let profilesMenu = NSMenu()

        let profiles: [(String, String, String)] = [
            ("Podcast Recording", "audiobridge 2ch",  "p"),
            ("Music Production",  "audiobridge 16ch", "m"),
            ("Streaming",         "audiobridge 2ch",  "s"),
            ("Screen Recording",  "audiobridge 2ch",  "r"),
        ]
        for (label, deviceHint, key) in profiles {
            let item = NSMenuItem(title: label, action: #selector(applyProfile(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self
            item.representedObject = deviceHint
            profilesMenu.addItem(item)
        }

        profilesMenu.addItem(.separator())

        let voiceItem = NSMenuItem(
            title: "Voice + System Audio",
            action: #selector(toggleVoicePlusSystem(_:)),
            keyEquivalent: "v"
        )
        voiceItem.keyEquivalentModifierMask = [.command, .option]
        voiceItem.target = self
        voiceItem.state  = voicePlusSystemActive ? .on : .off
        profilesMenu.addItem(voiceItem)

        let monitorItem = NSMenuItem(
            title: "Monitor + Record",
            action: #selector(toggleMonitorRecord(_:)),
            keyEquivalent: "o"
        )
        monitorItem.keyEquivalentModifierMask = [.command, .option]
        monitorItem.target = self
        monitorItem.state  = monitorRecordActive ? .on : .off
        profilesMenu.addItem(monitorItem)

        profilesItem.submenu = profilesMenu
        menu.addItem(profilesItem)
        menu.addItem(.separator())

        let recItem = NSMenuItem(title: recordMenuTitle(), action: #selector(toggleRecording(_:)), keyEquivalent: "r")
        recItem.keyEquivalentModifierMask = [.command, .shift]
        recItem.target = self
        recItem.isEnabled = driverEnabled || recorder.isRecording
        if recorder.isRecording {
            recItem.image = NSImage(systemSymbolName: "record.circle.fill",
                                    accessibilityDescription: "Recording")
        } else {
            recItem.image = NSImage(systemSymbolName: "record.circle",
                                    accessibilityDescription: "Record")
        }
        menu.addItem(recItem)
        recordMenuItem = recItem

        let recordingsItem = NSMenuItem(title: "Recordings…", action: #selector(openRecordingsFolder), keyEquivalent: "")
        recordingsItem.target = self
        menu.addItem(recordingsItem)
        menu.addItem(.separator())

        let midiItem = NSMenuItem(title: "Open Audio MIDI Setup", action: #selector(openAudioMIDISetup), keyEquivalent: "")
        midiItem.target = self
        menu.addItem(midiItem)

        let installItem = NSMenuItem(title: "Install Driver…", action: #selector(openInstaller), keyEquivalent: "")
        installItem.target = self
        menu.addItem(installItem)

        let aboutItem = NSMenuItem(title: "About AudioBridge", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc func toggleDriver(_ sender: NSMenuItem) {
        // Detection-only toggle. Disabling means uninstalling the driver,
        // which we surface as guidance rather than performing automatically.
        if driverEnabled {
            let alert = NSAlert()
            alert.messageText     = "Disable AudioBridge"
            alert.informativeText = "To disable AudioBridge, remove /Library/Audio/Plug-Ins/HAL/AudioBridge.driver and restart your Mac."
            alert.runModal()
        } else {
            openInstaller()
        }
    }

    @objc func applyProfile(_ sender: NSMenuItem) {
        guard let deviceHint = sender.representedObject as? String else { return }
        guard isAudioBridgeLoaded() else {
            showDriverMissingAlert()
            return
        }
        setDefaultInputByName(deviceHint)
        postNotification(title: "AudioBridge", body: "\(sender.title): default input set to \(deviceHint)")
    }

    @objc func toggleVoicePlusSystem(_ sender: NSMenuItem) {
        if voicePlusSystemActive {
            if let originalID = originalDefaultInputID {
                setDefaultInput(deviceID: originalID)
            }
            if let aggregateID = voicePlusSystemAggregateID {
                destroyAggregateDevice(deviceID: aggregateID)
            }
            voicePlusSystemActive       = false
            voicePlusSystemAggregateID  = nil
            originalDefaultInputID      = nil
            sender.state = .off
            postNotification(title: "AudioBridge", body: "Voice + System Audio off")
            return
        }

        guard isAudioBridgeLoaded() else {
            showDriverMissingAlert()
            return
        }
        guard let micID = getDefaultInputDeviceID() else {
            showError("No default microphone found. Connect a microphone or set one as the default input first.")
            return
        }
        // If the current default input is already the AudioBridge driver, the
        // aggregate would just be AudioBridge twice — abort and tell the user.
        if isAudioBridgeDevice(deviceID: micID) {
            showError("The default input is already AudioBridge. Set a real microphone as the default input first (System Settings → Sound → Input).")
            return
        }
        guard let bridgeID = findAudioBridgeDeviceID(channelHint: 2) else {
            showError("AudioBridge 2ch device not found.")
            return
        }
        guard let aggregateID = createVoicePlusSystemAggregate(micDeviceID: micID, bridgeDeviceID: bridgeID) else {
            showError("Could not create the Voice + System Audio device. Check Audio MIDI Setup.")
            return
        }

        originalDefaultInputID     = micID
        voicePlusSystemAggregateID = aggregateID
        setDefaultInput(deviceID: aggregateID)
        voicePlusSystemActive = true
        sender.state = .on
        postNotification(title: "AudioBridge", body: "Voice + System Audio active — select it as input in your DAW")
    }

    @objc func toggleMonitorRecord(_ sender: NSMenuItem) {
        if monitorRecordActive {
            if let originalID = originalDefaultOutputID {
                setDefaultOutput(deviceID: originalID)
            }
            if let aggregateID = monitorRecordAggregateID {
                destroyAggregateDevice(deviceID: aggregateID)
            }
            monitorRecordActive       = false
            monitorRecordAggregateID  = nil
            originalDefaultOutputID   = nil
            sender.state = .off
            postNotification(title: "AudioBridge", body: "Monitor + Record off")
            return
        }

        guard isAudioBridgeLoaded() else {
            showDriverMissingAlert()
            return
        }
        guard let currentOutputID = getDefaultOutputDeviceID() else {
            showError("Could not determine the current default output device.")
            return
        }
        guard let bridgeDeviceID = findAudioBridgeOutputDeviceID() else {
            showError("Could not find an AudioBridge output device.")
            return
        }
        guard let aggregateID = createMonitorRecordAggregate(
            masterDeviceID: currentOutputID,
            bridgeDeviceID: bridgeDeviceID
        ) else {
            showError("Could not create the Monitor + Record device. Check Audio MIDI Setup.")
            return
        }
        originalDefaultOutputID  = currentOutputID
        monitorRecordAggregateID = aggregateID
        setDefaultOutput(deviceID: aggregateID)
        monitorRecordActive = true
        sender.state = .on
        postNotification(title: "AudioBridge", body: "Monitor + Record active")
    }

    @objc func openAudioMIDISetup() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Utilities/Audio MIDI Setup.app"))
    }

    @objc func openInstaller() {
        // Look for the bundled installer pkg next to the app, then in common dist locations.
        let candidates: [URL] = [
            Bundle.main.url(forResource: "AudioBridge-Driver-2.2.0-signed", withExtension: "pkg"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("dist/AudioBridge-Driver-2.2.0-signed.pkg"),
        ].compactMap { $0 }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
            return
        }
        let alert = NSAlert()
        alert.messageText     = "Driver installer not found"
        alert.informativeText = "Download AudioBridge-Driver-2.2.0-signed.pkg from the project release and double-click to install."
        alert.runModal()
    }

    @objc func showAbout() {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let alert = NSAlert()
        alert.messageText     = "AudioBridge"
        alert.informativeText = """
        Version \(version)
        Virtual audio routing for macOS.

        Driver bundle ID: \(kAudioBridgeBundleID)
        Driver location:  /Library/Audio/Plug-Ins/HAL/AudioBridge.driver

        Based on BlackHole by Existential Audio Inc. (GPL-3.0)
        """
        alert.runModal()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Recording

    func recordMenuTitle() -> String {
        guard recorder.isRecording, let startedAt = recorder.startedAt else {
            return "Record"
        }
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        let mins = elapsed / 60
        let secs = elapsed % 60
        return String(format: "Stop Recording  •  %d:%02d", mins, secs)
    }

    @objc func toggleRecording(_ sender: NSMenuItem) {
        if recorder.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard isAudioBridgeLoaded() else {
            showDriverMissingAlert()
            return
        }
        guard let bridgeID = findAudioBridgeDeviceID(channelHint: 2) ?? findAudioBridgeDeviceID() else {
            showError("AudioBridge input device not found.")
            return
        }
        do {
            let url = try recorder.start(deviceID: bridgeID)
            postNotification(title: "AudioBridge", body: "Recording to \(url.lastPathComponent)")
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.recordMenuItem?.title = self?.recordMenuTitle() ?? "Stop Recording"
            }
            buildMenu()
        } catch {
            showError("Could not start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        guard let url = recorder.stop() else {
            buildMenu()
            return
        }
        buildMenu()
        let alert = NSAlert()
        alert.messageText     = "Recording saved"
        alert.informativeText = url.path
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Done")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        postNotification(title: "AudioBridge", body: "Saved \(url.lastPathComponent)")
    }

    @objc func openRecordingsFolder() {
        let dir = Recorder.recordingsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    // MARK: - Alerts

    func showDriverMissingAlert() {
        let alert = NSAlert()
        alert.messageText     = "AudioBridge driver not detected"
        alert.informativeText = "Install AudioBridge-Driver-2.2.0-signed.pkg and restart your Mac before using profiles."
        alert.addButton(withTitle: "Open Installer…")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openInstaller()
        }
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText     = "AudioBridge"
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - Entry Point

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
