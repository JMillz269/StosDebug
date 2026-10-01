//
//  ContentView.swift
//  StosDebug
//
//  Created by Stossy11 on 27/3/2026.
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit
import CoreLocation


struct ContentView: View {
    @State var showingScript: Bool = false
    @StateObject var deviceManager: DeviceManager = .shared
    
    var body: some View {
        TabView {
            Tab("Apps", systemImage: "square.stack.3d.up") {
                AppView(showingScript: $showingScript, isMounted: $deviceManager.isMounted)
            }
    
            Tab("Settings", systemImage: "gear") {
                SettingsView(deviceManager: deviceManager)
            }
    
        }
        .onOpenURL { url in
            switch url.host {
            case "enableJIT":
                Task {
                    while deviceManager.adapter == nil {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    
                    try? await Task.sleep(nanoseconds: 50_000_000)
                
                    let decoder = URLQueryDecoder()
                    
                    guard let params = try? decoder.decode(EnableJIT.self, from: url) else {
                        print("unable to decode")
                        return
                    }
                
                    var shouldLaunchApp: Bool = false
                    if params.pid != nil {
                        shouldLaunchApp = params.relaunchApp ?? true
                    }
                    
                    if ProcessInfo.processInfo.hasTXM {
                        showingScript = true
                        
                        if let script = params.scriptData {
                            _ = deviceManager.startDebugApp(bundleID: params.bundleId, pid: params.pid, forcePID: params.forcePID ?? false, launchApp: shouldLaunchApp, useScript: true, script: Scripts.custom(name: params.appName.lowercased(), data: script))
                        } else {
                            let script = Scripts.getScriptFromName(params.appName)
                            _ = deviceManager.startDebugApp(bundleID: params.bundleId, pid: params.pid, forcePID: params.forcePID ?? false, launchApp: shouldLaunchApp, useScript: true, script: script)
                        }
                    } else {
                        _ = deviceManager.startDebugApp(bundleID: params.bundleId, pid: params.pid, forcePID: params.forcePID ?? false, launchApp: shouldLaunchApp)
                    }
                }
            default:
                break
            }
        }
    }
}

struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    
    var text: String
    
    init(text: String = "") {
        self.text = text
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
                let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = string
    }
 
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: .utf8)!
        return FileWrapper(regularFileWithContents: data)
    }
}

// Port is 49152 from what jackson said

struct AppView: View {
    @State var thread: Thread?
    @State var apps: [SideApp] = []
    @State var logs: [String] = []
    @Binding var showingScript: Bool
    @Binding var isMounted: DeviceError  // Updated to DeviceError
    @State private var mountTask: Task<Void, Never>?
    @State private var isLoadingApps: Bool = false
    
    let locationDelegate = LocationDelegate()
    let deviceManager = DeviceManager.shared
    
    var body: some View {
        VStack {
            ScrollView {
                LazyVStack {
                    ForEach(apps.indices, id: \.self) { index in
                        AppListRow(app: apps[index])
                            .padding()
                            .onTapGesture {
                                if deviceManager.isMounted != .success {
                                    Alert.showSyncAlert(title: "DDI is not mounted", message: "Please go into settings and mount the Developer Disk Image.", actions: []) { _ in }
                                    return
                                }
                                
                                Thread.detachNewThread {
                                    if ProcessInfo.processInfo.hasTXM {
                                        let script = Scripts.getScriptFromName(apps[index].name)
                                        
                                        _ = deviceManager.startDebugApp(bundleID: apps[index].bundleIdentifier, useScript: true, script: script) { viewModel in
                                            DispatchQueue.main.async {
                                                showingScript = true
                                            }
                                        }
                                        
                                    } else {
                                        _ = deviceManager.startDebugApp(bundleID: apps[index].bundleIdentifier)
                                    }
                                }
                            }
                        
                        if index != apps.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .overlay(alignment: .center) {
                if deviceManager.adapter == nil && !isLoadingApps {
                    EmptyView()
                } else if isLoadingApps && apps.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Connecting…")
                            .foregroundStyle(.secondary)
                    }
                } else if case .failure(let issue) = deviceManager.isMounted {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(issue)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                        Button("Retry") { startTunnel() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else if apps.isEmpty {
                    Text("No Apps")
                }
            }
        }
        .sheet(isPresented: $showingScript) {
            LogsView()
        }
        .onAppear() {
            if FileManager.default.fileExists(atPath: deviceManager.pairingFileURL.path) {
                locationDelegate.start()
                
                startTunnel()
            } else {
                FileImporterManager.shared.importFiles(types: [.item], allowMultiple: false) { result in
                    switch result {
                    case .success(let urls):
                        let url = urls.first!
                        let securityScoped = url.startAccessingSecurityScopedResource()
                        defer { if securityScoped {  url.stopAccessingSecurityScopedResource() }}
                        
                        let pairingURL = deviceManager.pairingFileURL
                        
                        if FileManager.default.fileExists(atPath: pairingURL.path) {
                            try? FileManager.default.removeItem(at: pairingURL)
                        }
                        
                        do {
                            try FileManager.default.copyItem(at: url, to: pairingURL)
                        } catch {
                            Alert.showSyncAlert(title: "Failed to copy pairing file", message: error.localizedDescription) { _ in }
                        }
                        
                    
                        locationDelegate.start()
                        
                        startTunnel()
                    case .failure:
                        break
                    }
                }
            }
        }
    }
    
    private func startTunnel() {
        isLoadingApps = true
        Task.detached(priority: .userInitiated) {
            do {
                try await deviceManager.setupTunnel()
                await deviceManager.runCheckMounted(mountIfNeeded: true)
                let result = try? await DeviceManager.shared.listApps()
                await MainActor.run {
                    let newApps = (result ?? []).sorted { $0.bundleIdentifier < $1.bundleIdentifier }
                    let newHash = newApps.map(\.bundleIdentifier).joined().hashValue
                    let oldHash = self.apps.map(\.bundleIdentifier).joined().hashValue
                    if newHash != oldHash {
                        self.apps = newApps
                    }
                    isLoadingApps = false
                }
            } catch {
                await MainActor.run {
                    isLoadingApps = false
                    deviceManager.isMounted = .failure(issue: error.localizedDescription)
                }
            }
        }
    }
    
}

struct SettingsView: View {

    @AppStorage("forceTXM") var forceTXM = false
    @ObservedObject var deviceManager: DeviceManager
    let pairingURL = DeviceManager.shared.pairingFileURL
    
    var body: some View {
        List {
            Section {
                Button("\(FileManager.default.fileExists(atPath: pairingURL.path) ? "Replace" : "Import") Pairing File") {
                    FileImporterManager.shared.importFiles(types: [.item], allowMultiple: false) { result in
                        switch result {
                        case .success(let urls):
                            let url = urls.first!
                            let securityScoped = url.startAccessingSecurityScopedResource()
                            defer { if securityScoped {  url.stopAccessingSecurityScopedResource() }}
                            
                            
                            if FileManager.default.fileExists(atPath: pairingURL.path) {
                                try? FileManager.default.removeItem(at: pairingURL)
                            }
                            
                            do {
                                try FileManager.default.copyItem(at: url, to: pairingURL)
                            } catch {
                                Alert.showSyncAlert(title: "Failed to copy pairing file", message: error.localizedDescription) { _ in }
                            }
                            
                            Task.detached(priority: .userInitiated) {
                                do {
                                    try await deviceManager.setupTunnel()
                                } catch {
                                    _ = await Alert.showAlert(title: "Failed to start tunnel", message: error.localizedDescription)
                                }
                            }

                        case .failure:
                            break
                        }
                    }
                }
                
                Button("\(deviceManager.adapter == nil ? "Start" : "Restart") Tunnel") {
                    Task.detached(priority: .userInitiated) {
                        do {
                            try await deviceManager.setupTunnel()
                        } catch {
                            _ = await Alert.showAlert(title: "Failed to start tunnel", message: error.localizedDescription)
                        }
                    }
                }
                .disabled(deviceManager.adapter == nil && deviceManager.isMounting == .loading)
                
                if deviceManager.isMounted != .success && deviceManager.isMounting != .loading {
                    HStack {
                        Button("Mount DDI") {
                            deviceManager.runMountDDI()
                        }
                        
                        if deviceManager.isMounted.isFailure {
                            Spacer()
                            
                            Button {
                                Alert.showSyncAlert(title: "DDI failed to mount", message:  deviceManager.isMounted.failureReason ?? "Unknown error", hasCancel: false) { _ in}
                            } label: {
                                Image(systemName: "questionmark.circle")
                            }
                        }
                    }
                    

                } else if deviceManager.isMounting == .loading {
                    Text("DDI is currently mounting...")
                } else {
    HStack {
        Button("Mount DDI") {}
            .disabled(true)

        Spacer()

        Button {
            Alert.showSyncAlert(
                title: "DDI is already mounted",
                message: "The Developer Disk Image is already mounted.",
                hasCancel: false
            ) { _ in }
        } label: {
            Image(systemName: "questionmark.circle")
        }
    }
}

                if deviceManager.isMounted == .success {
                    Button("Unmount DDI") {
                        deviceManager.runUnmountDDI()
                }
            }
                
                if !ProcessInfo.processInfo.detectedTXM {
                    Toggle("Force TXM", isOn: $forceTXM)
                }
            } footer: {
                Text("\(UIDevice.modelName) | \(ProcessInfo.processInfo.alhasTXM ? "TXM" : "Non-TXM") | \(deviceManager.adapter == nil ? "Tunnel not started" : "Tunnel Started") | \(deviceManager.mountStatusText)")
            }
//            Section("TXM Debug") {
//                Text("Detected TXM: \(ProcessInfo.processInfo.detectedTXM)")
//                Text("Force TXM: \(forceTXM)")
//                Text("Has TXM: \(ProcessInfo.processInfo.hasTXM)")
//            }
        }
        .onAppear() {
            deviceManager.runCheckMounted(mountIfNeeded: true)
        }
    }
}

private extension DeviceManager {
    var mountStatusText: String {
        switch isMounted {
        case .none:      return "Unknown"
        case .loading:   return "Checking..."
        case .success:   return "Mounted"
        case .notMounted: return "Not Mounted"
        case .failure(let issue): return "Error: \(issue)"
        }
    }
}

struct AppIcon: View {
    let app: SideApp
    @State var appIconData: Data?
    @State private var fetchTask: Task<Void, Never>?

    var body: some View {
        if let iconData = app.appIcon ?? appIconData, let uiImage = UIImage(data: iconData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 15.0, style: .continuous))
                .clipped()
        } else {
            ZStack {
                Rectangle()
                    .foregroundStyle(.tertiary)
                ProgressView()
            }
            .clipShape(RoundedRectangle(cornerRadius: 15.0, style: .continuous))
            .onAppear {
                fetchTask = Task {
                    let data = await DeviceManager.shared.getAppIcon(bundleID: app.bundleIdentifier)
                    await MainActor.run {
                        appIconData = data
                    }
                }
            }
            .onDisappear {
                fetchTask?.cancel()
            }
        }
    }
}

struct LogsView: View {
    @State var logs: [String] = []
    @State var showScriptExport: Bool = false
    @State private var logsHash: Int = 0
    let deviceManager = DeviceManager.shared
    @State var timer: Timer?
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack {
                    ForEach(logs.indices, id: \.self) { index in
                        VStack {
                            HStack {
                                Text(logs[index])
                                Spacer()
                            }
                            if index != logs.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Export") {
                        showScriptExport = true
                    }
                }
            }
            .navigationTitle(DeviceManager.shared.jsViewModel?.scriptName ?? "Missing Script ViewModel")
            .onAppear() {
                logs = DeviceManager.shared.jsViewModel?.logs ?? []
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    let newLogs = DeviceManager.shared.jsViewModel?.logs ?? []
                    let newHash = newLogs.joined().hashValue
                    if newHash != logsHash {
                        logsHash = newHash
                        let appended = Array(newLogs.dropFirst(logs.count))
                        if !appended.isEmpty {
                            logs.append(contentsOf: appended)
                        }
                    }
                }
            }
            .onDisappear() {
                timer?.invalidate()
            }
            .fileExporter(isPresented: $showScriptExport, document: TextDocument(text: logs.joined(separator: "\n"))) { _ in
                
            }
        }
    }
}

struct AppListRow: View {
    let app: SideApp


    var body: some View {
        HStack {
            AppIcon(app: app)
                .frame(width: 60, height: 60)
                .aspectRatio(1, contentMode: .fill)
                .padding(.leading)
                .padding(.trailing, 8)
            
            
            
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.headline)
                }
                
                HStack(spacing: 4) {
                    Text(app.bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption2)
            }

            Spacer()
            

        }
        .shadow(radius: 10)
    }
}

class LocationDelegate: NSObject, CLLocationManagerDelegate {

    let locationManager = CLLocationManager()

    func start() {
        guard ProcessInfo.processInfo.hasTXM else { return }
        
        locationManager.delegate = self
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false

        locationManager.requestAlwaysAuthorization()
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
        case .denied, .restricted:
            print("Location permission denied")
        case .notDetermined:
            print("not determined")
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // intentionally do nothing
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error)")
    }
}

#Preview {
    ContentView()
}
