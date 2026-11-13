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
        let devices = availableInputDevices()
        // Device running state also includes playback on duplex devices, so prefer per-process input state.
        if let activeIDs = activeInputDeviceIDsFromProcesses() {
            return devices.filter { activeIDs.contains($0.0) }
        }
        return devices.filter { (id, _) in isDeviceRunning(id) }
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

    private func activeInputDeviceIDsFromProcesses() -> Set<AudioDeviceID>? {
        guard let processIDs = audioObjectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal
        ) else { return nil }

        var activeIDs = Set<AudioDeviceID>()
        var readProcessState = false
        for processID in processIDs {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isRunning: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &isRunning) == noErr else {
                continue
            }
            readProcessState = true
            guard isRunning != 0 else { continue }

            let deviceIDs = audioObjectIDs(
                processID,
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeInput
            ) ?? []
            activeIDs.formUnion(deviceIDs)
        }
        return readProcessState ? activeIDs : nil
    }

    private func allDeviceIDs() -> [AudioDeviceID] {
        return audioObjectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal
        ) ?? []
    }

    private func audioObjectIDs(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope) -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else { return nil }
        guard size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &objectIDs)
        guard status == noErr else { return nil }
        return objectIDs
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
        if let sourceName = inputSourceName(for: deviceID), !sourceName.isEmpty {
            return sourceName
        }

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

    private func inputSourceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var sourceID: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sourceID) == noErr else {
            return nil
        }

        address.mSelector = kAudioDevicePropertyDataSourceNameForIDCFString
        return withUnsafeMutablePointer(to: &sourceID) { sourcePointer in
            var output: Unmanaged<CFString>?
            return withUnsafeMutablePointer(to: &output) { outputPointer -> String? in
                var translation = AudioValueTranslation(
                    mInputData: sourcePointer,
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: outputPointer,
                    mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>>.size)
                )
                var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                let status = AudioObjectGetPropertyData(
                    deviceID, &address, 0, nil, &translationSize, &translation
                )
                guard status == noErr, let name = outputPointer.pointee else { return nil }
                return name.takeRetainedValue() as String
            }
        }
    }
}
