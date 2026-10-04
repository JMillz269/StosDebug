//
//  RunJSView.swift
//  StikJIT
//
//  Created by s s on 2025/4/24.
//

import SwiftUI
import Combine
import JavaScriptCore

final class RunJSViewModel: ObservableObject {
    var context: JSContext?
    @Published var logs: [String] = []
    @Published var scriptName: String = "Script"
    var executionInterrupted = false
    var pid: Int
    var debugProxy: OpaquePointer?
    var remoteServer: OpaquePointer?
    var semaphore: dispatch_semaphore_t?
    
    init(pid: Int, debugProxy: OpaquePointer?, remoteServer: OpaquePointer?, semaphore: dispatch_semaphore_t?) {
        self.pid = pid
        self.debugProxy = debugProxy
        self.remoteServer = remoteServer
        self.semaphore = semaphore
    }
    
    func runScript(data: Data, name: String? = nil) {
        let scriptContent = String(data: data, encoding: .utf8)
        let resolvedName = name ?? "Script"
        DispatchQueue.main.async { self.scriptName = resolvedName }
        
        let getPidFunction: @convention(block) () -> Int = {
            return self.pid
        }
        
        let sendCommandFunction: @convention(block) (String?) -> String? = { commandStr in
            guard let commandStr else {
                self.context?.exception = JSValue(object: "Command should not be nil.", in: self.context!)
                return ""
            }
            if self.executionInterrupted {
                self.context?.exception = JSValue(object: "Script execution is interrupted by StikDebug.", in: self.context!)
                return ""
            }
            
            return handleJSContextSendDebugCommand(context: self.context!, commandStr: commandStr, debugProxy: self.debugProxy) ?? ""
        }
        
        let logFunction: @convention(block) (String) -> Void = { logStr in
            DispatchQueue.main.async {
                self.logs.append(logStr)
            }
        }
        
        
        let prepareMemoryRegionFunction: @convention(block) (UInt64, UInt64) -> String = { startAddr, regionSize in
            return handleJITPageWrite(context: self.context!, startAddr: startAddr, JITPagesSize: regionSize, debugProxy: self.debugProxy) ?? ""
        }
        
        context = JSContext()
        context?.setObject(getPidFunction, forKeyedSubscript: "get_pid" as NSString)
        context?.setObject(sendCommandFunction, forKeyedSubscript: "send_command" as NSString)
        context?.setObject(prepareMemoryRegionFunction, forKeyedSubscript: "prepare_memory_region" as NSString)
        context?.setObject(logFunction, forKeyedSubscript: "log" as NSString)
        
        
        context?.evaluateScript(scriptContent)
        if let semaphore {
            semaphore.signal()
        }

        DispatchQueue.main.async {
            if let exception = self.context?.exception {
                self.logs.append(exception.debugDescription)
            }
            self.logs.append("Script Execution Completed")
            self.logs.append("You are safe to close the PIP Window.")
        }
    }
    

    private func screenshotFileURL(preferredName: String?) throws -> URL {
        let directory = URL.documentsDirectory.appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileManager = FileManager.default
        let initialName = sanitizedScreenshotName(from: preferredName)
        var targetURL = directory.appendingPathComponent(initialName)
        guard fileManager.fileExists(atPath: targetURL.path) else {
            return targetURL
        }
        
        let baseName = targetURL.deletingPathExtension().lastPathComponent
        let ext = targetURL.pathExtension.isEmpty ? "png" : targetURL.pathExtension
        var counter = 1
        repeat {
            let candidate = "\(baseName)-\(counter).\(ext)"
            targetURL = directory.appendingPathComponent(candidate)
            counter += 1
        } while fileManager.fileExists(atPath: targetURL.path)
        return targetURL
    }
    
    private func sanitizedScreenshotName(from preferredName: String?) -> String {
        let defaultName = "screenshot-\(Int(Date().timeIntervalSince1970))"
        guard var candidate = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else {
            return "\(defaultName).png"
        }
        
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var sanitized = ""
        sanitized.reserveCapacity(candidate.count)
        for scalar in candidate.unicodeScalars {
            if allowed.contains(scalar) {
                sanitized.append(Character(scalar))
            } else {
                sanitized.append("_")
            }
        }
        if sanitized.isEmpty {
            sanitized = defaultName
        }
        if !sanitized.lowercased().hasSuffix(".png") {
            sanitized += ".png"
        }
        return sanitized
    }
    
    private func describeIdeviceError(_ error: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        if let messagePointer = error.pointee.message {
            return "[\(error.pointee.code)] \(String(cString: messagePointer))"
        }
        return "[\(error.pointee.code)] Unknown error"
    }
    
    private func raiseException(_ message: String) {
        guard let context else { return }
        context.exception = JSValue(object: message, in: context)
    }
}
