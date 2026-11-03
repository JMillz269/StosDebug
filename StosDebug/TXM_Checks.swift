import Foundation
import Metal

private enum ChipSeries { case a, m }
private struct ChipInfo { let series: ChipSeries; let number: Int }

private let txmFirmware = "usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4"

private extension FileManager {
    /// First entry in `path` whose name is exactly `nameLength` characters long.
    func firstEntry(atPath path: String, nameLength: Int) -> String? {
        guard let name = try? contentsOfDirectory(atPath: path)
            .first(where: { $0.count == nameLength }) else { return nil }
        return "\(path)/\(name)"
    }
}

public extension ProcessInfo {

    /// iOS 26.0–26.5: the TXM firmware image exists in Preboot.
    var hasTXMClassic: Bool {
        if isiOSAppOnMac { return false }
        let fm = FileManager.default

        if let uuid = fm.firstEntry(atPath: "/System/Volumes/Preboot", nameLength: 36),
           let boot = fm.firstEntry(atPath: "\(uuid)/boot", nameLength: 96) {
            return access("\(boot)/\(txmFirmware)", F_OK) == 0
        }
        if let boot = fm.firstEntry(atPath: "/private/preboot", nameLength: 96) {
            return access("\(boot)/\(txmFirmware)", F_OK) == 0
        }
        return false
    }

    var detectedTXM: Bool {
        if isiOSAppOnMac { return false }

        if #available(iOS 27.0, *) {
            if let chip = chipInfo(), chip.series == .a { return chip.number > 12 } // A12 = last non-TXM
            return true
        }

        if #available(iOS 26.6, *), !hasTXMClassic {
            guard let chip = chipInfo() else { return false }
            return chip.series == .m ? chip.number >= 2 : chip.number >= 15 // M2+ / A15+
        }

        return hasTXMClassic
    }

    var hasTXM: Bool {
        UserDefaults.standard.bool(forKey: "forceTXM") || detectedTXM
    }

    private func chipInfo() -> ChipInfo? {
        guard let name = MTLCreateSystemDefaultDevice()?.name.uppercased(),
              let regex = try? NSRegularExpression(pattern: #"APPLE\s+([MA])(\d+)"#),
              let m = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let letterR = Range(m.range(at: 1), in: name),
              let numR = Range(m.range(at: 2), in: name),
              let number = Int(name[numR])
        else { return nil }

        return ChipInfo(series: name[letterR] == "M" ? .m : .a, number: number)
    }
}
