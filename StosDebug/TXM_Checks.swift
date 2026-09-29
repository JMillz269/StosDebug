import Foundation

public extension ProcessInfo {
    var hasTXM: Bool {
        if UserDefaults.standard.bool(forKey: "forceTXM") {
            return true
        }

        let hardware = hardwareIdentifier()

        if #available(iOS 27.0, *) {
            return hardware != "iPad8,11" && hardware != "iPad8,12"
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

    private func hardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)

        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    private func deviceVersion(from identifier: String) -> Double? {
        let pattern: String

        if identifier.hasPrefix("iPhone") {
            pattern = #"iPhone(\d+),(\d+)"#
        } else if identifier.hasPrefix("iPad") {
            pattern = #"iPad(\d+),(\d+)"#
        } else {
            return nil
        }

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: identifier,
                  range: NSRange(identifier.startIndex..., in: identifier)
              ),
              let majorRange = Range(match.range(at: 1), in: identifier),
              let minorRange = Range(match.range(at: 2), in: identifier),
              let major = Double(identifier[majorRange]),
              let minor = Double(identifier[minorRange])
        else {
            return nil
        }

        let minorDigits = String(Int(minor)).count
        return major + minor / pow(10.0, Double(minorDigits))
    }
}
