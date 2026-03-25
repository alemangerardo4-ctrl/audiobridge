import Cocoa
import CoreAudio

// MARK: - CoreAudio Helpers

func isAudioBridgeLoaded() -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0, nil,
        &dataSize
    )
    guard status == noErr else { return false }

    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0, nil,
        &dataSize,
        &deviceIDs
    )

    for deviceID in deviceIDs {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameSize: UInt32 = 256
        var name = [CChar](repeating: 0, count: 256)
        let nameStatus = AudioObjectGetPropertyData(
            deviceID,
            &nameAddress,
            0, nil,
            &nameSize,
            &name
        )
        if nameStatus == noErr {
            let deviceName = String(cString: name)
            if deviceName.lowercased().contains("audiobridge") {
                return true
            }
        }
    }
    return false
}

func setDefaultInput(deviceName: String) {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)

    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs)

    for deviceID in deviceIDs {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameSize: UInt32 = 256
        var name = [CChar](repeating: 0, count: 256)
        AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
        let foundName = String(cString: name)

        if foundName.lowercased().contains(deviceName.lowercased()) {
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var mutableID = deviceID
            AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &inputAddress,
                0, nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &mutableID
            )
            return
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    var driverEnabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        driverEnabled = isAudioBridgeLoaded()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "AudioBridge")
            button.image?.isTemplate = true
        }

        buildMenu()
    }

    func buildMenu() {
        let menu = NSMenu()

        // Title
        let titleItem = NSMenuItem(title: "AudioBridge", action: nil, keyEquivalent: "")
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13)]
        titleItem.attributedTitle = NSAttributedString(string: "AudioBridge", attributes: attrs)
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(.separator())

        // Enable toggle
        let toggleItem = NSMenuItem(
            title: "Enable AudioBridge",
            action: #selector(toggleDriver(_:)),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.state = driverEnabled ? .on : .off
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // Quick Profiles submenu
        let profilesItem = NSMenuItem(title: "Quick Profiles", action: nil, keyEquivalent: "")
        let profilesMenu = NSMenu()

        let profiles: [(String, String, String)] = [
            ("Podcast Recording",  "audiobridge 2ch",  "p"),
            ("Music Production",   "audiobridge 16ch", "m"),
            ("Streaming",          "audiobridge 2ch",  "s"),
            ("Screen Recording",   "audiobridge 2ch",  "r"),
        ]

        for (label, deviceHint, key) in profiles {
            let item = NSMenuItem(title: label, action: #selector(applyProfile(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self
            item.representedObject = deviceHint
            profilesMenu.addItem(item)
        }

        profilesItem.submenu = profilesMenu
        menu.addItem(profilesItem)

        menu.addItem(.separator())

        // Open Audio MIDI Setup
        let midiItem = NSMenuItem(
            title: "Open Audio MIDI Setup",
            action: #selector(openAudioMIDISetup),
            keyEquivalent: ""
        )
        midiItem.target = self
        menu.addItem(midiItem)

        // About
        let aboutItem = NSMenuItem(
            title: "About AudioBridge",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        // Quit
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
            // No unload API without kernel extension management — notify user
            let alert = NSAlert()
            alert.messageText = "AudioBridge"
            alert.informativeText = driverEnabled
                ? "AudioBridge is active."
                : "To fully disable AudioBridge, uninstall the driver and restart your Mac. The toggle reflects current detection state."
            alert.runModal()
        }
    }

    @objc func applyProfile(_ sender: NSMenuItem) {
        guard let deviceHint = sender.representedObject as? String else { return }
        let loaded = isAudioBridgeLoaded()
        guard loaded else {
            let alert = NSAlert()
            alert.messageText = "AudioBridge not detected"
            alert.informativeText = "Install the AudioBridge driver and restart your Mac before using profiles."
            alert.runModal()
            return
        }
        setDefaultInput(deviceName: deviceHint)
        let alert = NSAlert()
        alert.messageText = "\(sender.title) activated"
        alert.informativeText = "Default input set to \(deviceHint)."
        alert.runModal()
    }

    @objc func openAudioMIDISetup() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Utilities/Audio MIDI Setup.app"))
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "AudioBridge"
        alert.informativeText = """
        Version 1.0
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
