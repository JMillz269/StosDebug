import AVFoundation
import os.log

final class BackgroundAudioManager {
    static let shared = BackgroundAudioManager()
    
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var timer: Timer?
    private var isRunning = false
    
    private init() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recover()
        }
    }
    
    func start() {
        guard UserDefaults.standard.bool(forKey: "keepAliveAudio") else {
            print("[BGAudio] start() skipped: toggle is off")
            return
        }
        print("[BGAudio] start() called")
        guard !isRunning else {
            print("[BGAudio] Already running")
            return
        }
        isRunning = true
        startEngine()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.recover()
        }
    }
    
    func stop() {
        print("[BGAudio] stop() called")
        isRunning = false
        timer?.invalidate()
        timer = nil
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    
    private func startEngine() {
        do {
            print("[BGAudio] Starting audio engine")
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            
            engine.attach(player)
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            
            scheduleSilence(format: format)
            try engine.start()
            player.play()
            print("[BGAudio] Engine started successfully")
        } catch {
            print("[BGAudio] Failed to start: \(error.localizedDescription)")
        }
    }
    
    private func scheduleSilence(format: AVAudioFormat) {
        let frameCount = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            print("[BGAudio] Failed to create audio buffer")
            return
        }
        buffer.frameLength = frameCount
        player.scheduleBuffer(buffer, at: nil, options: .loops)
    }
    
    private func recover() {
        guard isRunning, !engine.isRunning || !player.isPlaying else { return }
        print("[BGAudio] Recovering audio session")
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning {
                try engine.start()
            }
            player.play()
        } catch {
            print("[BGAudio] Recovery failed: \(error.localizedDescription)")
        }
    }
}
