import Foundation

struct AudioInputDevice: Equatable {
    let id: UInt32
    let uid: String
    let name: String
}

enum AudioInputSelection {
    static let defaultsKey = "audioInputDeviceUID"
    static let didChange = Notification.Name("FlowScribeAudioInputSelectionChanged")

    /// Persist the stable UID, since Core Audio device IDs change across reconnects.
    static var selectedUID: String? {
        get { UserDefaults.standard.string(forKey: defaultsKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// A disconnected preferred microphone falls back without forgetting the preference.
    static func resolve(preferredUID: String?, devices: [AudioInputDevice],
                        defaultDeviceID: UInt32?) -> AudioInputDevice? {
        if let preferredUID, let device = devices.first(where: { $0.uid == preferredUID }) {
            return device
        }
        return devices.first { $0.id == defaultDeviceID }
    }
}
