public extension ProcessInfo {
    var detectedTXM: Bool {
        let hardware = hardwareIdentifier()

        if #available(iOS 27.0, *) {
            return hardware != "iPad8,11" &&
                   hardware != "iPad8,12"
        }

        if #available(iOS 26.0, *) {
            guard let version = deviceVersion(from: hardware) else {
                return false
            }

            if hardware.hasPrefix("iPad") {
                return version >= 14.5
            }

            if hardware.hasPrefix("iPhone") {
                return version >= 14.2
            }
        }

        return false
    }

    var hasTXM: Bool {
        if UserDefaults.standard.bool(forKey: "forceTXM") {
            return true
        }

        return detectedTXM
    }
}
