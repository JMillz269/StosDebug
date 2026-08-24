//
//  Scripts.swift
//  StosDebug
//
//  Created by Stossy11 on 28/3/2026.
//

import Foundation

struct Scripts: Equatable {
    let name: String
    let customURL: URL?
    let customData: Data?
    let persistent: Bool
    
    static var customScript: [String: Scripts] = [:]
    
    static let classic        = Scripts("classic")
    static let classic_geode  = Scripts("classic_geode")
    static let universal      = Scripts("universal")
    static let `universal+manic` = Scripts("universal+manic")
    
    static func custom(name: String, url: URL) -> Scripts {
        Scripts(name, customURL: url)
    }
    
    static func custom(name: String, data: Data, persistent: Bool = false) -> Scripts {
        Scripts(name, customData: data, persistent: persistent)
    }
    
    private init(_ name: String, customData: Data?, persistent: Bool) {
        self.name = name
        self.customData = customData
        self.customURL = nil
        self.persistent = persistent
    }
    
    private init(_ name: String, customURL: URL? = nil) {
        self.name = name
        self.customURL = customURL
        self.customData = nil
        self.persistent = true
    }
    
    enum Apps: String, CaseIterable {
        case manic
        case melonx
        case amethyst
        case utm
        case dolphin
        case flycast
        case geode
        case other
        
        var script: Scripts {
            switch self {
            case .manic:
                return .`universal+manic`
            case .utm, .dolphin, .flycast:
                return .classic
            case .geode:
                return .classic_geode
            case .amethyst, .melonx, .other:
                return .universal
            }
        }
    }
    
    static func getScriptFromName(_ name: String) -> Scripts {
        if let script = customScript[name] { return script }
        let name = Scripts.Apps.allCases.first(where: { name.lowercased().contains($0.rawValue) })
        if let name { return name.script }
        return .universal
    }
}

extension Scripts {
    var isCustom: Bool { customURL != nil && customData != nil }
    
    var scriptPath: URL {
        customURL ?? Bundle.main.bundleURL.appendingPathComponent(name)
    }
    
    var scriptName: String {
        components.suffix ?? name
    }
    
    var scriptData: Data? {
        if let data = customData {
            return data
        }
        
        if let url = customURL {
            return try? Data(contentsOf: url)
        }
        
        let (prefix, suffix) = components
        guard suffix != nil else {
            return try? Data(contentsOf: scriptPath.appendingPathExtension("js"))
        }
        
        let bundleURL = Bundle.main.bundleURL
        let patchPath = bundleURL.appendingPathComponent("\(name).jitrpl")
        let fileURL   = bundleURL.appendingPathComponent("\(prefix).js")
        return try? applyPatch(toURL: fileURL, patchURL: patchPath)
    }
    
    var components: (prefix: String, suffix: String?) {
        let parts = name.split(separator: "+", maxSplits: 1)
        return (
            prefix: String(parts[0]),
            suffix: parts.count > 1 ? String(parts[1]) : nil
        )
    }
    
    func applyPatch(toURL template: URL, patchURL: URL) throws -> Data {
        
        let patchContent = try String(contentsOf: patchURL, encoding: .utf8)
        let template = try String(contentsOf: template, encoding: .utf8)
        var result = template

        var lines = patchContent.components(separatedBy: "\n")[...]
        while let line = lines.first {
            lines = lines.dropFirst()

            if line == ":RPL" {
                var findLines: [String] = []
                var replaceLines: [String] = []

                while let l = lines.first, l != ":WITH" {
                    findLines.append(l)
                    lines = lines.dropFirst()
                }
                lines = lines.dropFirst()

                while let l = lines.first, l != ":ENDRPL" {
                    replaceLines.append(l)
                    lines = lines.dropFirst()
                }
                lines = lines.dropFirst()

                let find = findLines.joined(separator: "\n")
                let replace = replaceLines.joined(separator: "\n")
                result = result.replacingOccurrences(of: find, with: replace)
            }
        }
        

        return result.data(using: .utf8) ?? Data()
    }
}
