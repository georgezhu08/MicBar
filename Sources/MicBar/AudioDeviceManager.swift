import CoreAudio
import Foundation

/// Manages audio input device queries, switching, and change notifications via CoreAudio HAL.
final class AudioDeviceManager {
    static let shared = AudioDeviceManager()

    /// Callback fired when the default input device changes or its running state changes.
    var onDeviceChanged: (() -> Void)?

    private var propertyListenerBlock: AudioObjectPropertyListenerBlock?
    private var pollTimer: Timer?

    private init() {
        installListeners()
        startPolling()
    }

    deinit {
        removeListeners()
        pollTimer?.invalidate()
    }

    // MARK: - Public API

    /// Returns the name of the current default input device, or nil if none.
    func defaultInputDeviceName() -> String? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        return nameForDevice(deviceID)
    }

    /// Returns input devices that currently have active audio streams (some process is using them).
    func activeInputDevices() -> [(AudioDeviceID, String)] {
        return availableInputDevices().filter { (id, _) in isDeviceRunning(id) }
    }

    /// Returns all available input devices as (id, name) pairs.
    func availableInputDevices() -> [(AudioDeviceID, String)] {
        let deviceIDs = allDeviceIDs()
        return deviceIDs.compactMap { id in
            guard hasInputStreams(id) else { return nil }
            guard let name = nameForDevice(id) else { return nil }
            return (id, name)
        }
    }

    /// Returns true if ANY input device is currently running.
    func isAnyInputDeviceRunning() -> Bool {
        return !activeInputDevices().isEmpty
    }

    /// Returns the current default input device ID.
    func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Sets the default input device.
    @discardableResult
    func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, size, &id
        )
        return status == noErr
    }

    /// Returns whether the current default input device is running (has active IO).
    func isDefaultInputDeviceRunning() -> Bool {
        guard let deviceID = defaultInputDeviceID() else { return false }
        return isDeviceRunning(deviceID)
    }

    /// Returns whether a specific device has active INPUT (mic capture) running.
    func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        guard status == noErr else { return false }
        return isRunning != 0
    }

    // MARK: - Private

    private func installListeners() {
        // Listen for default input device changes
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.onDeviceChanged?()
            }
        }
        self.propertyListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main,
            block
        )

        // Listen for device list changes (devices added/removed)
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            block
        )
    }

    /// Poll every 2 seconds to detect running-state changes on any input device.
    /// CoreAudio property listeners on per-device running state are unreliable for
    /// devices opened by other processes, so we supplement with polling.
    private func startPolling() {
        var lastActiveIDs = Set<AudioDeviceID>()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let currentActive = Set(self.activeInputDevices().map { $0.0 })
            if currentActive != lastActiveIDs {
                lastActiveIDs = currentActive
                self.onDeviceChanged?()
            }
        }
    }

    private func removeListeners() {
        guard let block = propertyListenerBlock else { return }

        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main,
            block
        )

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            block
        )
    }

    private func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceIDs
        )
        guard status == noErr else { return [] }
        return deviceIDs
    }

    private func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr else { return false }
        return size > 0
    }

    private func nameForDevice(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        var unmanagedName: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &unmanagedName)
        guard status == noErr, let cfName = unmanagedName?.takeUnretainedValue() else { return nil }
        return cfName as String
    }
}
