import Cocoa
import CoreAudio
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

// MARK: - Menu bar icon

// Template icon: stylized suspension bridge (Public Works "Bridge" mark).
// Two pylons, two suspension cables, a deck spanning the full width, and
// a small connector dot at each pylon/deck intersection. Same geometry as
// the app icon so the menu bar reads as the same product.
//
// Two states:
//   - active (driver detected): filled connector dots, slightly heavier deck
//   - idle  (driver missing):   no connector dots, lighter strokes
//
// All strokes are template-black; macOS tints to match menu bar appearance.
func makeMenuBarIcon(active: Bool) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { _ in
        NSColor.black.set()

        let stroke: CGFloat   = active ? 1.4 : 1.2
        let deckStroke: CGFloat = active ? 1.7 : 1.4
        let cableStroke: CGFloat = 1.0

        func line(_ p1: NSPoint, _ p2: NSPoint, _ width: CGFloat) {
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineCapStyle = .round
            path.move(to: p1)
            path.line(to: p2)
            path.stroke()
        }

        // 18x18 grid. Bridge spans 2..16 horizontally, top cable at y=14,
        // deck at y=7, pylons go from y=14 down to y=3.
        let leftPylonX:  CGFloat = 6
        let rightPylonX: CGFloat = 12
        let topY:        CGFloat = 14
        let bottomY:     CGFloat = 3
        let deckY:       CGFloat = 7
        let deckLeft:    CGFloat = 2
        let deckRight:   CGFloat = 16

        // Suspension cables (drawn first, sit underneath).
        line(NSPoint(x: leftPylonX,  y: topY),
             NSPoint(x: deckLeft,    y: deckY), cableStroke)
        line(NSPoint(x: rightPylonX, y: topY),
             NSPoint(x: deckRight,   y: deckY), cableStroke)

        // Top cable connecting the pylons.
        line(NSPoint(x: leftPylonX,  y: topY),
             NSPoint(x: rightPylonX, y: topY), stroke)

        // Pylons.
        line(NSPoint(x: leftPylonX,  y: topY),
             NSPoint(x: leftPylonX,  y: bottomY), stroke)
        line(NSPoint(x: rightPylonX, y: topY),
             NSPoint(x: rightPylonX, y: bottomY), stroke)

        // Deck (heaviest line).
        line(NSPoint(x: deckLeft,    y: deckY),
             NSPoint(x: deckRight,   y: deckY), deckStroke)

        // Connector dots at the pylon/deck intersections — only shown when
        // the driver is detected, so the menu bar gives an at-a-glance state.
        if active {
            let r: CGFloat = 1.5
            for cx in [leftPylonX, rightPylonX] {
                NSBezierPath(ovalIn: NSRect(x: cx - r, y: deckY - r,
                                            width: 2 * r, height: 2 * r)).fill()
            }
        }

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
        let alert = NSAlert()
        alert.messageText     = "AudioBridge"
        alert.informativeText = """
        Version 2.2.1
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
