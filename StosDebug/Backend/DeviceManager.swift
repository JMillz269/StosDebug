//
//  idevicemanager.swift
//  StosDebug
//
//  Created by Stossy11 on 27/3/2026.
//

import Foundation
import SwiftUI
import Combine
import Network
import BackgroundTasks
import UIKit

typealias RpPairingFileHandle = OpaquePointer
typealias IdeviceProviderHandle = OpaquePointer
typealias HeartbeatClientHandle = OpaquePointer
typealias LockdowndClientHandle = OpaquePointer
typealias ImageMounterHandle = OpaquePointer
typealias CoreDeviceProxyHandle = OpaquePointer
typealias AdapterHandle = OpaquePointer
typealias AdapterStreamHandle = OpaquePointer
typealias RsdHandshakeHandle = OpaquePointer
typealias RemoteServerHandle = OpaquePointer
typealias AppServerHandle = OpaquePointer
typealias DebugProxyHandle = OpaquePointer
typealias ProcessControlHandle = OpaquePointer
typealias InstallationProxyClientHandle = OpaquePointer
typealias SpringBoardServicesClientHandle = OpaquePointer
typealias MounterClientHandle = OpaquePointer
typealias CryptexdHandle = OpaquePointer

enum DeveloperDiskImage: String {
    case personalizedImage =
        "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg"

    case personalizedTrustCache =
        "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg.trustcache"

    case personalizedBuildManifest =
        "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/BuildManifest.plist"

    case cryptexImage =
        "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Cryptex/Image.dmg"

    case cryptexTrustCache =
        "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Cryptex/Image.dmg.trustcache"

    case cryptexBuildManifest =
        "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Cryptex/BuildManifest.plist"

    case cryptexInfo =
        "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Cryptex/Image.dmg.cryptex_info"

    case cryptexRootHash =
        "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Cryptex/Image.dmg.root_hash"
}

private var usesCryptexDDI: Bool {
    let version = ProcessInfo.processInfo.operatingSystemVersion

    return version.majorVersion > 26 ||
        (version.majorVersion == 26 && version.minorVersion >= 4)
}

final class DeviceManager: ObservableObject {
    static let shared = DeviceManager()
    private init() {}

    @Published public var jsViewModel: RunJSViewModel?
    let fileManager = FileManager.default

    var pairingFileURL = URL.documentsDirectory.appendingPathComponent("pairingFile.plist")

    let pairingFileURL1 = URL.documentsDirectory.appendingPathComponent("pairingFile.plist")
    let pairingFileURL2 = URL.documentsDirectory.appendingPathComponent("ios_pairing_file.plist")

    var adapter: AdapterHandle?
    var handshake: RsdHandshakeHandle?
    var pairing: RpPairingFileHandle?

    private var tunnelHealthTask: Task<Bool, Never>?
    private var tunnelRebuildTask: Task<Void, Never>?
    private let sessionLock = NSLock()
    private var activeSessionCount = 0
    
    // GCD queue for blocking FFI calls to avoid starving the Swift cooperative pool
    private let ffiQueue = DispatchQueue(label: "stosdebug.ffi", qos: .userInitiated)

    var isDebugSessionActive: Bool {
        sessionLock.withLock { activeSessionCount > 0 }
    }

    private func beginDebugSession() {
        sessionLock.withLock { activeSessionCount += 1 }
    }

    private func endDebugSession() {
        sessionLock.withLock { activeSessionCount = max(0, activeSessionCount - 1) }
    }

    @Published var checkMounted: Task<Void, Never>? = nil
    @Published var isMounted: DeviceError = .none

    @Published var mountTask: Task<Void, Never>? = nil
    @Published var isMounting: DeviceError = .none
    
    // Helper to run blocking FFI work off the cooperative pool
    private func runBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            ffiQueue.async { cont.resume(with: Result { try work() }) }
        }
    }
    
    // Snapshot handles on the main actor to prevent data races
    @MainActor
    private func currentHandles() -> (AdapterHandle, RsdHandshakeHandle)? {
        guard let adapter, let handshake else { return nil }
        return (adapter, handshake)
    }

    func runMountDDI(_ check: Bool = false) {
        if check && isMounting == .success {
            return
        }

        mountTask?.cancel()

        mountTask = Task {
                        // Ensure adapter/handshake are healthy before attempting mount.
             await ensureTunnelReady()
             await MainActor.run {
                isMounting = .loading
            }

            do {
                if usesCryptexDDI {
                    try await mountCryptexDDI()
                } else {
                    try await mountPersonalDDI(
                        imagePath: DeveloperDiskImage.personalizedImage.rawValue,
                        trustcachePath: DeveloperDiskImage.personalizedTrustCache.rawValue,
                        manifestPath: DeveloperDiskImage.personalizedBuildManifest.rawValue
                    )
                }

                                await MainActor.run {
                    isMounting = .success
                }

                // Cryptex/DDI install can leave the existing RSD adapter stale
                // for debug services. Rebuild so Apps launch works without
                // manually pressing Restart Tunnel.
                await MainActor.run {
                    self.stopTunnel()
                }
                do {
                    try await self.setupTunnel()
                } catch {
                    await MainActor.run {
                        self.isMounted = .failure(issue: "Mounted, but tunnel rebuild failed: \(error.localizedDescription)")
                    }
                    return
                }

                runCheckMounted()
            } catch {
                await MainActor.run {
                    isMounting = .failure(issue: error.localizedDescription)
                }
            }
        }
    }
            func setupTunnel() async throws {
        // Always dispose of any existing tunnel before creating a new one
        await MainActor.run {
            self.stopTunnel()
        }

        let newPairing: RpPairingFileHandle? = try await runBlocking { [self] in
            let string = strdup(URL.documentsDirectory.appendingPathComponent("idevice_log.txt").path)
            idevice_init_logger(Debug, Debug, string)
            defer { free(string) }

            var pairingHandle: RpPairingFileHandle?
            let err = rp_pairing_file_read(self.pairingFileURL.path, &pairingHandle)
            if let err {
                throw "Pairing read failed: \(err.pointee.code) \(err.pointee.message.string)"
            }
            return pairingHandle
        }

        pairing = newPairing

        var addr = sockaddr_in()
        memset(&addr, 0, MemoryLayout<sockaddr_in>.size)

        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(49152)

        guard inet_pton(AF_INET, "10.7.0.1", &addr.sin_addr) == 1 else {
            throw "Invalid IP (shouldn't be possible)"
        }

        let pairing = pairing
        let (newAdapter, newHandshake): (AdapterHandle?, RsdHandshakeHandle?) = try await runBlocking {
            var createdAdapter: AdapterHandle?
            var createdHandshake: RsdHandshakeHandle?

            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    tunnel_create_rppairing(
                        ptr,
                        socklen_t(MemoryLayout<sockaddr_in>.size),
                        "StosDebug",
                        pairing,
                        nil,
                        nil,
                        &createdAdapter,
                        &createdHandshake
                    )
                }
            }

            if let result {
                throw "Tunnel creation failed: \(result.pointee.code) \(result.pointee.message.string)"
            }

            return (createdAdapter, createdHandshake)
        }

        await MainActor.run {
            self.adapter = newAdapter
            self.handshake = newHandshake
        }
    }

        /// Stops the RSD tunnel and frees all native handles.
    @MainActor
    func stopTunnel() {
        tunnelRebuildTask?.cancel()
        tunnelRebuildTask = nil
        tunnelHealthTask?.cancel()
        tunnelHealthTask = nil

        if let adapter {
            _ = adapter_close(adapter)
            adapter_free(adapter)
        }
        if let handshake {
            rsd_handshake_free(handshake)
        }
        if let pairing {
            rp_pairing_file_free(pairing)
        }

        self.adapter = nil
        self.handshake = nil
        self.pairing = nil
    }

    @MainActor
    func ensureTunnelReady() async {
        if isDebugSessionActive { return }

        if let task = tunnelRebuildTask {
            await task.value
            return
        }

        let task = Task { @MainActor in
            defer { self.tunnelRebuildTask = nil }

            let needsRebuild: Bool
            if self.adapter == nil || self.handshake == nil {
                needsRebuild = true
            } else {
                needsRebuild = !(await self.tunnelHealthCheck(timeout: 3.0))
            }

            guard needsRebuild else { return }

            self.stopTunnel()

            do {
                try await self.setupTunnel()
                self.runCheckMounted(mountIfNeeded: false)
            } catch {
                self.isMounted = .failure(issue: error.localizedDescription)
            }
        }

        tunnelRebuildTask = task
        await task.value
    }

    private func tunnelHealthCheck(timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                (try? await self.isMounted()) != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    func startDebugApp(
        bundleID: String? = nil,
        pid: Int? = nil,
        forcePID: Bool = false,
        launchApp: Bool = false,
        useScript: Bool = false,
        script: Scripts? = nil,
        whenJSCreated: ((RunJSViewModel) -> Void)? = nil
    ) -> Int {

        beginDebugSession()
        defer { endDebugSession() }

        // ---- Keep-alive for the whole session ----
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        if useScript {
            let startKeepAlive = {
                bgTask = UIApplication.shared.beginBackgroundTask(withName: "StosDebugSession") {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
                BackgroundLocationManager.shared.start()
                BackgroundAudioManager.shared.start()
                print("[Session] Background task and keep-alive started")
            }

            if Thread.isMainThread {
                startKeepAlive()
            } else {
                DispatchQueue.main.async(execute: startKeepAlive)
            }
        }
        defer {
            if useScript {
                DispatchQueue.main.async {
                    BackgroundLocationManager.shared.stop()
                    BackgroundAudioManager.shared.stop()
                    if bgTask != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTask)
                        bgTask = .invalid
                    }
                }
            }
        }
        // ---- end keep-alive ----

        guard let adapter, let handshake else {
            print("Tunnel not initialized")
            return 1
        }

        var err: UnsafeMutablePointer<IdeviceFfiError>?

        var remoteServer: RemoteServerHandle?
        err = remote_server_connect_rsd(adapter, handshake, &remoteServer)

        if let err {
            print("Remote server failed: \(err.pointee.message.string)")
            return 1
        }

        var debugProxy: DebugProxyHandle?
        err = debug_proxy_connect_rsd(adapter, handshake, &debugProxy)

        if let err {
        print("Debug proxy failed: \(err.pointee.message.string)")
    if let remoteServer {
        remote_server_free(remoteServer)
    }
    return 1
}

// Free both handles on every exit path from here on
defer {
    if let debugProxy {
        debug_proxy_free(debugProxy)
    }
    if let remoteServer {
        remote_server_free(remoteServer)
    }
}

        var finalPID = UInt64(pid ?? 0)

        if let bundleID, let pid, launchApp {
            var backPid: UInt64 = 0
            var processControl: ProcessControlHandle?
            err = process_control_new(remoteServer, &processControl)

            if err == nil {
                err = process_control_launch_app(
                    processControl,
                    bundleID,
                    nil,
                    0,
                    nil,
                    0,
                    false,
                    false,
                    &backPid
                )

                _ = process_control_disable_memory_limit(processControl, finalPID)
                process_control_free(processControl)
            }

            if backPid != pid && finalPID != 0 && !forcePID {
                finalPID = backPid
            }

        } else if let bundleID {
            var processControl: ProcessControlHandle?
            err = process_control_new(remoteServer, &processControl)

            if err == nil {
                err = process_control_launch_app(
                    processControl,
                    bundleID,
                    nil,
                    0,
                    nil,
                    0,
                    true,
                    false,
                    &finalPID
                )

                _ = process_control_disable_memory_limit(processControl, finalPID)
                process_control_free(processControl)
            }
        }

        if finalPID == 0 {
            return 2
        }

        debug_proxy_send_ack(debugProxy)
        debug_proxy_send_ack(debugProxy)

        var disableResponse: UnsafeMutablePointer<CChar>?
        let disableAckCommand = debugserver_command_new("QStartNoAckMode", nil, 0)
        debug_proxy_send_command(debugProxy, disableAckCommand, &disableResponse)
        debugserver_command_free(disableAckCommand)
        if disableResponse != nil {
        idevice_string_free(disableResponse)
    }
        debug_proxy_set_ack_mode(debugProxy, 0)

        if useScript, let script {
            let semaphore: dispatch_semaphore_t = DispatchSemaphore(value: 0)

            let viewModel = RunJSViewModel(pid: Int(finalPID), debugProxy: debugProxy, remoteServer: remoteServer, semaphore: semaphore)

                DispatchQueue.main.async { [weak self] in
                    self?.jsViewModel = viewModel
                    whenJSCreated?(viewModel)
                        }

            guard let scriptData = script.scriptData else {
                Alert.showSyncAlert(title: "Missing Script Data", message: "Unable to get the Script Data", alertHandler: { _ in })
                debug_proxy_free(debugProxy)
                return 3
            }

            viewModel.runScript(data: scriptData, name: script.scriptName)
            
            let waitResult = semaphore.wait(timeout: .now() + 30)
            if waitResult == .timedOut {
                Alert.showSyncAlert(
                    title: "Script Timeout",
                    message: "Script execution timed out after 30 seconds.",
                    alertHandler: { _ in }
                )
            }
            
            let _ = debug_proxy_send_raw(debugProxy, "\\x03", 1)
            
            if !script.persistent {
                if let (key, _) = Scripts.customScript.first(where: { $0.value == script }) {
                    Scripts.customScript.removeValue(forKey: key)
                }
            }
            
            usleep(500)
            
        } else {
            let attachStr = String(format: "vAttach;%llx", finalPID)
            let attachCmd = debugserver_command_new(attachStr, nil, 0)

            var response: UnsafeMutablePointer<CChar>?
            _ = debug_proxy_send_command(debugProxy, attachCmd, &response)

            if response != nil {
                idevice_string_free(response)
            }

            debugserver_command_free(attachCmd)

            if let detachCmd = debugserver_command_new("D", nil, 0) {
                var detachResp: UnsafeMutablePointer<CChar>?
                for _ in 0..<3 {
                    _ = debug_proxy_send_command(debugProxy, detachCmd, &detachResp)
                }
                if detachResp != nil {
                    idevice_string_free(detachResp)
                }
                debugserver_command_free(detachCmd)
            }
        }

        return 0
    }

    func listApps(gettaskallow: Bool = true) throws -> [SideApp] {
        var client: InstallationProxyClientHandle? = nil

        let error = installation_proxy_connect_rsd(adapter, handshake, &client)
        if let error = error?.pointee {
            print("First one")
            print(error.message.string)
            return []
        }

        defer { installation_proxy_client_free(client) }

        var resultPlist: UnsafeMutableRawPointer? = nil
var resultCount: Int = 0
let getAppsError = installation_proxy_get_apps(client, "User", nil, 0, &resultPlist, &resultCount)

defer {
    if let resultPlist {
        let appsArray = resultPlist.assumingMemoryBound(to: plist_t?.self)
        for i in 0..<resultCount {
            if let node = appsArray[i] {
                plist_free(node)
            }
        }
        idevice_data_free(
            resultPlist.assumingMemoryBound(to: UInt8.self),
            UInt(resultCount * MemoryLayout<plist_t?>.stride)
        )
    }
}

if let error = getAppsError {
    print("second one")
    print(error.pointee.message.string)
    return []
}

guard let appsPointer = resultPlist else { return [] }
let appsArray = appsPointer.assumingMemoryBound(to: plist_t?.self)

        var sideApps: [SideApp] = []

        for i in 0..<resultCount {
            guard let app = appsArray[i] else { continue }

            if gettaskallow {
                guard
                    let entitlements = plist_dict_get_item(app, "Entitlements"),
                    let getTaskNode = plist_dict_get_item(entitlements, "get-task-allow")
                else { continue }

                var isAllowed: UInt8 = 0
                plist_get_bool_val(getTaskNode, &isAllowed)
                if isAllowed == 0 { continue }
            }

            guard let bidNode = plist_dict_get_item(app, "CFBundleIdentifier") else { continue }
            var bidC: UnsafeMutablePointer<CChar>? = nil
            plist_get_string_val(bidNode, &bidC)
            guard let bidCString = bidC, bidCString[0] != 0 else {
                free(bidC)
                continue
            }
            let bundleID = String(cString: bidCString)
            free(bidC)

            var appName = "Unknown"
            if let nameNode = plist_dict_get_item(app, "CFBundleName") {
                var nameC: UnsafeMutablePointer<CChar>? = nil
                plist_get_string_val(nameNode, &nameC)
                if let nameCString = nameC, nameCString[0] != 0 {
                    appName = String(cString: nameCString)
                }
                free(nameC)
            }

            let sideApp = SideApp(name: appName, bundleIdentifier: bundleID)
            sideApps.append(sideApp)
        }

        return sideApps
    }

    func getAppIcon(bundleID: String) async -> Data? {
        guard let (adapter, handshake) = await currentHandles() else { return nil }

            return await Task.detached(priority: .userInitiated) {
            var client: SpringBoardServicesClientHandle?

            if springboard_services_connect_rsd(adapter, handshake, &client) != nil {
            return nil
        }

        defer { springboard_services_free(client) }

        var iconData: UnsafeMutableRawPointer?
        var iconDataLen: Int = 0

        if springboard_services_get_icon(client, bundleID, &iconData, &iconDataLen) != nil {
            return nil
        }

        defer {
            if let iconData {
                idevice_data_free(
                    iconData.assumingMemoryBound(to: UInt8.self),
                    UInt(iconDataLen)
                )
            }
        }

        guard let iconData, iconDataLen > 0 else { return nil }
        return Data(bytes: iconData, count: iconDataLen)
    }.value
}

    func isMounted() async throws -> Bool {
        guard let (adapter, handshake) = await currentHandles() else {
            throw "Tunnel not initialized"
        }

        return try await runBlocking {
            var cryptex: UnsafeMutablePointer<InstalledCryptexC>?
            let cryptexError = cryptexd_installed_ddi(
                adapter,
                handshake,
                &cryptex
            )

            defer {
                cryptexd_free_installed_cryptex(cryptex)
            }

            if cryptex != nil {
                return true
            }

            var mounterClient: MounterClientHandle?
            let mounterError = image_mounter_connect_rsd(
                adapter,
                handshake,
                &mounterClient
            )

            if let mounterError {
                if let cryptexError {
                    throw cryptexError.pointee.message.string
                }

                throw mounterError.pointee.message.string
            }

            defer {
                image_mounter_free(mounterClient)
            }

            var devices: UnsafeMutablePointer<plist_t?>?
            var deviceCount: size_t = 0

            if let error = image_mounter_copy_devices(
                mounterClient,
                &devices,
                &deviceCount
            ) {
                throw error.pointee.message.string
            }

            if let devices {
                for index in 0..<Int(deviceCount) {
                    if let device = devices[index] {
                        plist_free(device)
                    }
                }

                idevice_data_free(
                    UnsafeMutableRawPointer(devices)
                        .assumingMemoryBound(to: UInt8.self),
                    UInt(deviceCount * MemoryLayout<plist_t?>.stride)
                )
            }

            return deviceCount > 0
        }
    }

    private func mountCryptexDDI() async throws {
        guard let adapter, let handshake else {
            throw "Tunnel not initialized"
        }

        let fileManager = FileManager.default
        let ddiDirectory = URL.documentsDirectory
            .appendingPathComponent("DDI", isDirectory: true)

        try fileManager.createDirectory(
            at: ddiDirectory,
            withIntermediateDirectories: true
        )

        let files: [(name: String, url: String)] = [
            (
                "BuildManifest.plist",
                DeveloperDiskImage.cryptexBuildManifest.rawValue
            ),
            (
                "Image.dmg",
                DeveloperDiskImage.cryptexImage.rawValue
            ),
            (
                "Image.dmg.trustcache",
                DeveloperDiskImage.cryptexTrustCache.rawValue
            ),
            (
                "Image.dmg.cryptex_info",
                DeveloperDiskImage.cryptexInfo.rawValue
            ),
            (
                "Image.dmg.root_hash",
                DeveloperDiskImage.cryptexRootHash.rawValue
            )
        ]

        for file in files {
            let destination = ddiDirectory
                .appendingPathComponent(file.name)

            if fileManager.fileExists(atPath: destination.path) {
                continue
            }

                try await downloadFile(from: file.url, to: destination)
        }

        var assets: OpaquePointer?

        let loadError = ddiDirectory.path.withCString { path in
            cryptex1_assets_load(path, &assets)
        }

        if let loadError {
            throw loadError.pointee.message.string
        }

        guard let assets else {
            throw "Cryptex DDI assets could not be loaded"
        }

        defer {
            cryptex1_assets_free(assets)
        }

        let installError: String? = try await runBlocking {
            if let e = cryptexd_install_ddi(adapter, handshake, assets, nil) {
                return String(cString: e.pointee.message)
            }
            return nil
        }
        
        if let installError {
            throw installError
        }
    }
   
    func downloadDataAsync(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "InvalidURL", code: 0)
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .useProtocolCachePolicy

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse {
            print("Status:", http.statusCode)
        }

        return data
    }

    /// Streams a remote file to disk and validates HTTP status.
    /// Use this for large DDI assets to avoid loading whole files into memory.
    func downloadFile(from urlString: String, to destination: URL) async throws {
        guard let url = URL(string: urlString) else {
            throw "Invalid URL: \(urlString)"
        }

        let (tmpURL, response) = try await URLSession.shared.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw "Download failed (HTTP \(status)) for \(url.lastPathComponent)"
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try fileManager.moveItem(at: tmpURL, to: destination)
    }

        /// Deletes the locally cached DDI files (Documents/DDI) that appear in the Files app.
    private func deleteLocalDDIFiles() {
        let ddiDirectory = URL.documentsDirectory
            .appendingPathComponent("DDI", isDirectory: true)

        guard fileManager.fileExists(atPath: ddiDirectory.path) else { return }

        do {
            // Remove the contents but keep the folder itself.
            let contents = try fileManager.contentsOfDirectory(
                at: ddiDirectory,
                includingPropertiesForKeys: nil
            )
            for item in contents {
                try fileManager.removeItem(at: item)
            }
        } catch {
            print("Failed to delete local DDI files: \(error.localizedDescription)")
        }
    }
    
        func runUnmountDDI() {
        Task {
            do {
                try await unmountDDI()

                // Optional but recommended: wipe cached DDI files from Documents/DDI
                deleteLocalDDIFiles()

                await MainActor.run {
                    self.stopTunnel()
                    self.isMounted = .notMounted
                    self.isMounting = .none
                }
            } catch {
                await MainActor.run {
                    self.isMounted = .failure(issue: error.localizedDescription)
                }
            }
        }
    }

    private func unmountDDI() async throws {
        guard let (adapter, handshake) = await currentHandles() else {
            throw "Tunnel not initialized"
        }

        let identifier: String = try await runBlocking {
            var installed: UnsafeMutablePointer<InstalledCryptexC>?
            if let installedError = cryptexd_installed_ddi(adapter, handshake, &installed) {
                throw installedError.pointee.message.string
            }

            guard let installed else {
                throw "No Cryptex DDI is currently installed"
            }
            defer { cryptexd_free_installed_cryptex(installed) }

            guard let identifierPtr = installed.pointee.identifier else {
                throw "Unable to determine installed Cryptex identifier"
            }
            return String(cString: identifierPtr)
        }

        try await runBlocking {
            var cryptexHandle: CryptexdHandle?
            if let connectError = cryptexd_connect_rsd(adapter, handshake, &cryptexHandle) {
                throw connectError.pointee.message.string
            }

            guard let cryptexHandle else {
                throw "Failed to create Cryptexd handle"
            }

            let identifierCString = strdup(identifier)
            defer { free(identifierCString) }

            if let uninstallError = cryptexd_uninstall(cryptexHandle, identifierCString, nil) {
                throw uninstallError.pointee.message.string
            }
        }
    }

    func runCheckMounted(mountIfNeeded: Bool = false) {
        checkMounted?.cancel()
        checkMounted = Task {
            do {
                await MainActor.run {
                    isMounted = .loading
                }
                let mounted = try await DeviceManager.shared.isMounted()
                await MainActor.run {
                    isMounted = mounted ? .success : .notMounted
                }

                if mountIfNeeded && !mounted {
                    runMountDDI()
                }
            } catch {
                await MainActor.run {
                    isMounted = .failure(issue: error.localizedDescription)
                }
            }
        }
    }

    func mountPersonalDDI(
        imagePath: String,
        trustcachePath: String,
        manifestPath: String
    ) async throws {
        let image = try await downloadDataAsync(from: imagePath)
        let trustcache = try await downloadDataAsync(from: trustcachePath)
        let buildManifest = try await downloadDataAsync(from: manifestPath)

        guard let (adapter, handshake) = await currentHandles() else {
            throw "Tunnel not initialized"
        }

        var lockdownClient: LockdowndClientHandle?
        var err = lockdownd_connect_rsd(adapter, handshake, &lockdownClient)
        if let err {
            throw err.pointee.message.string
        }

        var uniqueChipIdPlist: plist_t?
            err = lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &uniqueChipIdPlist)
            if let err {
                throw err.pointee.message.string
            }

            defer {
                if let uniqueChipIdPlist {
                plist_free(uniqueChipIdPlist)
        }
}

var chipId: UInt64 = 0
plist_get_uint_val(uniqueChipIdPlist, &chipId)

var mounterClient: MounterClientHandle?
err = image_mounter_connect_rsd(adapter, handshake, &mounterClient)
if let err {
    throw err.pointee.message.string
}

defer {
    image_mounter_free(mounterClient)
    lockdownd_client_free(lockdownClient)
}

        // Immutable copies: @Sendable closures can't capture `var`s.
        let mounter = mounterClient
        let uniqueChipId = chipId

        // Returns String? (Sendable) so no C pointer crosses the closure boundary.
        let mountError: String? = try await runBlocking { () -> String? in
            let result: UnsafeMutablePointer<IdeviceFfiError>? =
                image.withUnsafeBytes { (imagePtr: UnsafeRawBufferPointer) in
                    trustcache.withUnsafeBytes { (trustPtr: UnsafeRawBufferPointer) in
                        buildManifest.withUnsafeBytes { (manifestPtr: UnsafeRawBufferPointer) in
                            image_mounter_mount_personalized_rsd(
                                mounter,
                                adapter,
                                handshake,
                                imagePtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                image.count,
                                trustPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                trustcache.count,
                                manifestPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                buildManifest.count,
                                nil,
                                uniqueChipId
                            )
                        }
                    }
                }

            if let result {
                return String(cString: result.pointee.message)
            }
            return nil
        }

        if let mountError {
            throw mountError
        }
    }
}

struct SideApp: Codable, Identifiable, Equatable {
    var id: String { bundleIdentifier }
    var name: String
    var bundleIdentifier: String
    var version: String?
    var appIcon: Data?
    var path: String?
    var isSideStore: Bool {
        bundleIdentifier == Bundle.main.bundleIdentifier ?? "io.sidestore.SideStore.next"
    }

    init(name: String, bundleIdentifier: String, version: String? = nil, appIcon: Data? = nil, path: String? = nil) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.appIcon = appIcon
        self.path = path
    }
}

extension String: @retroactive LocalizedError {
    public var errorDescription: String? { self }
}

// MARK: - Helpers

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

extension UnsafeRawBufferPointer {
    var uint8Pointer: UnsafePointer<UInt8> { baseAddress!.assumingMemoryBound(to: UInt8.self) }
}

extension UnsafePointer where Pointee == CChar {
    var string: String {
        String(cString: self)
    }
}
