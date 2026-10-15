import CoreAudio
import Foundation

/// Core Audio inventory and notifications, shared by recording and Settings.
final class AudioInputDevices {
    static let shared = AudioInputDevices()
    static let didChange = Notification.Name("FlowScribeAudioInputDevicesChanged")

    private let listenerQueue = DispatchQueue(label: "com.flowscribe.inputdevices")
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private init() {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyServiceRestarted] {
            var address = Self.address(selector)
            let listener: AudioObjectPropertyListenerBlock = { _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.didChange, object: nil)
                }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &address, listenerQueue, listener) == noErr {
                listeners.append((address, listener))
            }
        }
    }

    deinit {
        for (var address, listener) in listeners {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                    &address, listenerQueue, listener)
        }
    }

    func available() -> [AudioInputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id),
                  let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, selector: kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func defaultDeviceID() -> AudioDeviceID? {
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    func selectedDevice() -> AudioInputDevice? {
        AudioInputSelection.resolve(preferredUID: AudioInputSelection.selectedUID,
                                    devices: available(), defaultDeviceID: defaultDeviceID())
    }

    private func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration,
                                   scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              Int(size) >= MemoryLayout<AudioBufferList>.size else { return false }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        // Core Audio transfers ownership of name/UID properties to the caller.
        return value?.takeRetainedValue() as String?
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
