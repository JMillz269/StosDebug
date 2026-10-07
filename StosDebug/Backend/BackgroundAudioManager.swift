import AVFoundation

final class BackgroundAudioManager {
    static let shared = BackgroundAudioManager()
    
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var timer: Timer?
    private var isRunning = false
    private var interruptionObserver: NSObjectProtocol?
    
    private init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recover()
        }
    }
    
    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }
    
    func start() {
        guard UserDefaults.standard.bool(forKey: "keepAliveAudio") else {
            return
        }
        guard !isRunning else {
            return
        }
        isRunning = true
        startEngine()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.recover()
        }
    }
    
    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    
    private func startEngine() {
        do {
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
        } catch {
        }
    }
    
    private func scheduleSilence(format: AVAudioFormat) {
        let frameCount = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        buffer.frameLength = frameCount
        player.scheduleBuffer(buffer, at: nil, options: .loops)
    }
    
    private func recover() {
        guard isRunning, !engine.isRunning || !player.isPlaying else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning {
                try engine.start()
            }
            player.play()
        } catch {
        }
    }
}
