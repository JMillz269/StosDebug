//
//  RunJSView.swift
//  
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
    
    private var didSignalSemaphore = false
    
    init(pid: Int, debugProxy: OpaquePointer?, remoteServer: OpaquePointer?, semaphore: dispatch_semaphore_t?) {
        self.pid = pid
        self.debugProxy = debugProxy
        self.remoteServer = remoteServer
        self.semaphore = semaphore
    }
    
    func runScript(data: Data, name: String? = nil) {
        let scriptContent = String(data: data, encoding: .utf8) ?? ""
        let resolvedName = name ?? "Script"
        DispatchQueue.main.async { self.scriptName = resolvedName }
        
        let getPidFunction: @convention(block) () -> Int = { [weak self] in
            return self?.pid ?? -1
        }
        
        let sendCommandFunction: @convention(block) (String?) -> String? = { [weak self] commandStr in
            guard let self else { return "" }
            
            guard let commandStr else {
                if let ctx = self.context {
                    ctx.exception = JSValue(object: "Command should not be nil.", in: ctx)
                }
                return ""
            }
            
            if self.executionInterrupted {
                if let ctx = self.context {
                    ctx.exception = JSValue(object: "Script execution is interrupted by StikDebug.", in: ctx)
                }
                return ""
            }
            
            guard let ctx = self.context else { return "" }
            return handleJSContextSendDebugCommand(context: ctx, commandStr: commandStr, debugProxy: self.debugProxy) ?? ""
        }
        
        let logFunction: @convention(block) (String) -> Void = { [weak self] logStr in
            guard let self else { return }
            DispatchQueue.main.async {
                self.logs.append(logStr)
            }
        }
        
        let prepareMemoryRegionFunction: @convention(block) (UInt64, UInt64) -> String = { [weak self] startAddr, regionSize in
            guard let self, let ctx = self.context else { return "" }
            return handleJITPageWrite(context: ctx, startAddr: startAddr, JITPagesSize: regionSize, debugProxy: self.debugProxy) ?? ""
        }
        
        context = JSContext()
        context?.setObject(getPidFunction, forKeyedSubscript: "get_pid" as NSString)
        context?.setObject(sendCommandFunction, forKeyedSubscript: "send_command" as NSString)
        context?.setObject(prepareMemoryRegionFunction, forKeyedSubscript: "prepare_memory_region" as NSString)
        context?.setObject(logFunction, forKeyedSubscript: "log" as NSString)
        
        context?.evaluateScript(scriptContent)
        signalIfNeeded()
        
        DispatchQueue.main.async {
            if let exception = self.context?.exception {
                self.logs.append(exception.debugDescription)
            }
            self.logs.append("Script Execution Completed")
            self.logs.append("You are safe to close the PIP Window.")
        }
    }
    
    private func signalIfNeeded() {
        guard !didSignalSemaphore else { return }
        didSignalSemaphore = true
        semaphore?.signal()
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

        let ext = targetURL.pathExtension
        let base = targetURL.deletingPathExtension().lastPathComponent
        var counter = 1
        while fileManager.fileExists(atPath: targetURL.path) {
            let candidate = "\(base)-\(counter)"
            targetURL = directory.appendingPathComponent(candidate).appendingPathExtension(ext)
            counter += 1
        }
        return targetURL
    }

    private func sanitizedScreenshotName(from preferredName: String?) -> String {
        let fallback = "screenshot-\(Int(Date().timeIntervalSince1970)).png"
        guard let preferredName, !preferredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let clean = preferredName
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return fallback }
        return clean.hasSuffix(".png") ? clean : "\(clean).png"
    }
}
