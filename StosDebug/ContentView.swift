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
        .onAppear {
            if ProcessInfo.processInfo.hasTXM {
                BackgroundLocationManager.shared.requestAuthorizationIfNeeded()
            }
        }
        .onOpenURL { url in
            let host = url.host?.lowercased()

            switch host {
            case "enableJIT".lowercased(), "enable-jit":
                Task.detached(priority: .userInitiated) {
                await deviceManager.ensureTunnelReady()
    
            // Replaces Thread.sleep(forTimeInterval: 0.05)
            try? await Task.sleep(nanoseconds: 50_000_000)
    
            let decoder = URLQueryDecoder()
    
            guard let params = try? decoder.decode(EnableJIT.self, from: url) else {
                print("unable to decode")
                return
            }
    
            let scheme = url.scheme?.lowercased() ?? ""
            let isStosDebug = scheme == "stosdebug"
    
            if isStosDebug, (params.appName?.isEmpty ?? true) {
                print("unable to decode: appName is required for stosdebug:// URLs")
                return
            }
    
            var shouldLaunchApp: Bool = false
            if params.pid != nil {
                shouldLaunchApp = params.relaunchApp ?? true
            }
    
            let launchApp = shouldLaunchApp
            let bundleId = params.bundleId
            let pid = params.pid
            let forcePID = params.forcePID ?? false
    
            if ProcessInfo.processInfo.hasTXM {
                let script: Scripts
                if let data = params.scriptData {
                    let name = (params.appName?.isEmpty == false ? params.appName! : bundleId)
                    script = Scripts.custom(name: name.lowercased(), data: data)
                } else if let appName = params.appName, !appName.isEmpty {
                    script = Scripts.getScriptFromName(appName)
                } else if isStosDebug {
                    print("unable to decode: appName is required for stosdebug:// URLs without a script")
                    return
                } else {
                    script = .universal
                }
    
                _ = deviceManager.startDebugApp(
                    bundleID: bundleId,
                    pid: pid,
                    forcePID: forcePID,
                    launchApp: launchApp,
                    useScript: true,
                    script: script
                ) { _ in
                    DispatchQueue.main.async { showingScript = true }
                }
            } else {
                _ = deviceManager.startDebugApp(
                    bundleID: bundleId,
                    pid: pid,
                    forcePID: forcePID,
                    launchApp: launchApp
                )
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
    @Binding var isMounted: DeviceError
    @State private var mountTask: Task<Void, Never>?
    @State private var isLoadingApps: Bool = false

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
                                    Alert.showSyncAlert(
                                        title: "DDI is not mounted",
                                        message: "Please go into settings and mount the Developer Disk Image.",
                                        actions: []
                                    ) { _ in }
                                    return
                                }
                                
                                let app = apps[index]
                                Task.detached(priority: .userInitiated) {
                                    await deviceManager.ensureTunnelReady()
                                
                                    if ProcessInfo.processInfo.hasTXM {
                                        let script = Scripts.getScriptFromName(app.name)
                                
                                        _ = deviceManager.startDebugApp(
                                            bundleID: app.bundleIdentifier,
                                            useScript: true,
                                            script: script
                                        ) { _ in
                                            DispatchQueue.main.async {
                                                showingScript = true
                                            }
                                        }
                                    } else {
                                        _ = deviceManager.startDebugApp(bundleID: app.bundleIdentifier)
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
                startTunnel()
            } else {
                FileImporterManager.shared.importFiles(types: [.item], allowMultiple: false) { result in
                    switch result {
                    case .success(let urls):
                        let url = urls.first!
                        let securityScoped = url.startAccessingSecurityScopedResource()
                        defer { if securityScoped { url.stopAccessingSecurityScopedResource() } }

                        let pairingURL = deviceManager.pairingFileURL

                        if FileManager.default.fileExists(atPath: pairingURL.path) {
                            try? FileManager.default.removeItem(at: pairingURL)
                        }

                        do {
                            try FileManager.default.copyItem(at: url, to: pairingURL)
                        } catch {
                            Alert.showSyncAlert(
                                title: "Failed to copy pairing file",
                                message: error.localizedDescription
                            ) { _ in }
                        }

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
    Task {
        await deviceManager.ensureTunnelReady()
        deviceManager.runCheckMounted(mountIfNeeded: true)
        let result = try? await DeviceManager.shared.listApps()

        let newApps = (result ?? []).sorted { $0.bundleIdentifier < $1.bundleIdentifier }
        let newHash = newApps.map(\.bundleIdentifier).joined().hashValue

        await MainActor.run {
            let oldHash = self.apps.map(\.bundleIdentifier).joined().hashValue
            if newHash != oldHash {
                self.apps = newApps
            }
            self.isLoadingApps = false
        }
    }
}
}

struct SettingsView: View {
    @AppStorage("forceTXM") var forceTXM = false
    @AppStorage("keepAliveLocation") var keepAliveLocation = true
    @AppStorage("keepAliveAudio") var keepAliveAudio = true
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
                            defer { if securityScoped { url.stopAccessingSecurityScopedResource() } }

                            if FileManager.default.fileExists(atPath: pairingURL.path) {
                                try? FileManager.default.removeItem(at: pairingURL)
                            }

                            do {
                                try FileManager.default.copyItem(at: url, to: pairingURL)
                            } catch {
                                Alert.showSyncAlert(
                                    title: "Failed to copy pairing file",
                                    message: error.localizedDescription
                                ) { _ in }
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
                    if deviceManager.isMounted == .success {
                        Button("\(deviceManager.adapter == nil ? "Start" : "Restart") Tunnel") {
                            Task.detached(priority: .userInitiated) {
                                do {
                                    try await deviceManager.setupTunnel()
                                } catch {
                                    _ = await Alert.showAlert(title: "Failed to start tunnel", message: error.localizedDescription)
                                }
                            }
                        }
                    }
                    
                    if deviceManager.isMounted != .success && deviceManager.isMounting != .loading {
                        HStack {
                            Button("Mount DDI & Start Tunnel") {
                                deviceManager.runMountDDI()
                            }
                    
                            if deviceManager.isMounted.isFailure {
                                Spacer()
                    
                                Button {
                                    Alert.showSyncAlert(
                                        title: "DDI failed to mount",
                                        message: deviceManager.isMounted.failureReason ?? "Unknown error",
                                        hasCancel: false
                                    ) { _ in }
                                } label: {
                                    Image(systemName: "questionmark.circle")
                                }
                            }
                        }
                    } else if deviceManager.isMounting == .loading {
                        Text("DDI is currently mounting...")
                    } else if deviceManager.isMounted == .success {
                        HStack {
                            Button("Mount DDI & Start Tunnel") {}
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
                Text("\(UIDevice.modelName) | \(ProcessInfo.processInfo.hasTXM ? "TXM" : "Non-TXM") | \(deviceManager.adapter == nil ? "Tunnel not started" : "Tunnel Started") | \(deviceManager.mountStatusText)")
            }

            Section {
                Toggle("Location Keep-Alive", isOn: $keepAliveLocation)
                    .onChange(of: keepAliveLocation) { _, isOn in
                        if isOn {
                            BackgroundLocationManager.shared.requestAuthorizationIfNeeded()
                        } else {
                            BackgroundLocationManager.shared.stop()
                        }
                    }

                Toggle("Background Audio Keep-Alive", isOn: $keepAliveAudio)
                    .onChange(of: keepAliveAudio) { _, isOn in
                        if !isOn {
                            BackgroundAudioManager.shared.stop()
                        }
                    }
            } header: {
                Text("Keep Alive")
            } footer: {
                Text("Keeps StosDebug running in the background while a script is active. Location uses the background location indicator. Audio plays silence and may interrupt other audio apps' ducking. Turn both off only if you don't need background execution.")
            }
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
    @ObservedObject private var deviceManager = DeviceManager.shared

    var body: some View {
        if let model = deviceManager.jsViewModel {
            LogsContent(model: model)
                .id(ObjectIdentifier(model))
        } else {
            NavigationStack {
                Text("No script running")
                    .foregroundStyle(.secondary)
                    .navigationTitle("Script")
            }
        }
    }
}

private struct LogsContent: View {
    @ObservedObject var model: RunJSViewModel
    @State private var showScriptExport: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack {
                    ForEach(model.logs.indices, id: \.self) { index in
                        VStack {
                            HStack {
                                Text(model.logs[index])
                                Spacer()
                            }
                            if index != model.logs.count - 1 {
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
            .navigationTitle(model.scriptName)
            .fileExporter(
                isPresented: $showScriptExport,
                document: TextDocument(text: model.logs.joined(separator: "\n"))
            ) { _ in }
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

#Preview {
    ContentView()
}
