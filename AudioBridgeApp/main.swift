import Cocoa
import CoreAudio
import UserNotifications

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

func isAudioBridgeLoaded() -> Bool {
    getAllDeviceIDs().contains {
        getDeviceName(deviceID: $0)?.lowercased().contains("audiobridge") == true
    }
}

func setDefaultInput(deviceName: String) {
    for deviceID in getAllDeviceIDs() {
        guard let name = getDeviceName(deviceID: deviceID),
              name.lowercased().contains(deviceName.lowercased()) else { continue }
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
        return
    }
}

// MARK: - Monitor + Record Helpers

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
    for deviceID in getAllDeviceIDs() {
        guard let name = getDeviceName(deviceID: deviceID),
              name.lowercased().contains("audiobridge") else { continue }
        // Confirm it exposes output streams
        var streamAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        let s = AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &streamSize)
        if s == noErr && streamSize > 0 {
            return deviceID
        }
    }
    return nil
}

// Creates a Multi-Output (stacked aggregate) device that mirrors audio to both subdevices.
func createMonitorRecordAggregate(masterDeviceID: AudioDeviceID, bridgeDeviceID: AudioDeviceID) -> AudioDeviceID? {
    guard let masterUID = getDeviceUID(deviceID: masterDeviceID),
          let bridgeUID  = getDeviceUID(deviceID: bridgeDeviceID) else { return nil }

    let subDevices: [[String: Any]] = [
        [kAudioSubDeviceUIDKey as String: masterUID],
        [kAudioSubDeviceUIDKey as String: bridgeUID],
    ]
    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey          as String: "Monitor + Record",
        kAudioAggregateDeviceUIDKey           as String: "com.audiobridge.monitorrecord",
        kAudioAggregateDeviceSubDeviceListKey as String: subDevices,
        kAudioAggregateDeviceMasterSubDeviceKey as String: masterUID,
        kAudioAggregateDeviceIsStackedKey     as String: 1,  // Multi-Output: mirrors audio to all subdevices
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

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    var driverEnabled = false

    // Monitor + Record state
    var monitorRecordActive       = false
    var monitorRecordAggregateID: AudioDeviceID? = nil
    var originalDefaultOutputID:  AudioDeviceID? = nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        driverEnabled = isAudioBridgeLoaded()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "AudioBridge")
            button.image?.isTemplate = true
        }
        buildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if monitorRecordActive, let aggregateID = monitorRecordAggregateID {
            if let originalID = originalDefaultOutputID {
                setDefaultOutput(deviceID: originalID)
            }
            destroyAggregateDevice(deviceID: aggregateID)
        }
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
        driverEnabled.toggle()
        sender.state = driverEnabled ? .on : .off
        if !driverEnabled {
            let alert = NSAlert()
            alert.messageText    = "AudioBridge"
            alert.informativeText = "To fully disable AudioBridge, uninstall the driver and restart your Mac. The toggle reflects current detection state."
            alert.runModal()
        }
    }

    @objc func applyProfile(_ sender: NSMenuItem) {
        guard let deviceHint = sender.representedObject as? String else { return }
        guard isAudioBridgeLoaded() else {
            let alert = NSAlert()
            alert.messageText     = "AudioBridge not detected"
            alert.informativeText = "Install the AudioBridge driver and restart your Mac before using profiles."
            alert.runModal()
            return
        }
        setDefaultInput(deviceName: deviceHint)
        let alert = NSAlert()
        alert.messageText     = "\(sender.title) activated"
        alert.informativeText = "Default input set to \(deviceHint)."
        alert.runModal()
    }

    @objc func toggleMonitorRecord(_ sender: NSMenuItem) {
        if monitorRecordActive {
            // Tear down: restore original output and destroy aggregate
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
        } else {
            // Guard: AudioBridge must be loaded
            guard isAudioBridgeLoaded() else {
                let alert = NSAlert()
                alert.messageText     = "AudioBridge not detected"
                alert.informativeText = "Install the AudioBridge driver and restart your Mac before using profiles."
                alert.runModal()
                return
            }
            // Find current default output and AudioBridge output device
            guard let currentOutputID = getDefaultOutputDeviceID() else {
                let alert = NSAlert()
                alert.messageText     = "Setup failed"
                alert.informativeText = "Could not determine the current default output device."
                alert.runModal()
                return
            }
            guard let bridgeDeviceID = findAudioBridgeOutputDeviceID() else {
                let alert = NSAlert()
                alert.messageText     = "Setup failed"
                alert.informativeText = "Could not find an AudioBridge output device."
                alert.runModal()
                return
            }
            // Create the Multi-Output aggregate and set as system default
            guard let aggregateID = createMonitorRecordAggregate(
                masterDeviceID: currentOutputID,
                bridgeDeviceID: bridgeDeviceID
            ) else {
                let alert = NSAlert()
                alert.messageText     = "Setup failed"
                alert.informativeText = "Could not create the Monitor + Record device. Check Audio MIDI Setup."
                alert.runModal()
                return
            }
            originalDefaultOutputID  = currentOutputID
            monitorRecordAggregateID = aggregateID
            setDefaultOutput(deviceID: aggregateID)
            monitorRecordActive = true
            sender.state = .on
            postNotification(title: "AudioBridge", body: "Monitor + Record active")
        }
    }

    @objc func openAudioMIDISetup() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Utilities/Audio MIDI Setup.app"))
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText     = "AudioBridge"
        alert.informativeText = """
        Version 2.1.0
        Virtual audio routing for macOS.

        Based on BlackHole by Existential Audio Inc.
        GPL-3.0 licensed.
        """
        alert.runModal()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Entry Point

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
