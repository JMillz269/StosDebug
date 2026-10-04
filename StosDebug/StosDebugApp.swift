//
//  StosDebugApp.swift
//  StosDebug
//
//  Created by Stossy11 on 27/3/2026.
//

import SwiftUI

@main
struct StosDebugApp: App {
    
    init() {
        let cache = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024
        )
        URLCache.shared = cache
        
        UserDefaults.standard.register(defaults: [
            "keepAliveLocation": true,
            "keepAliveAudio": true
        ])
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
