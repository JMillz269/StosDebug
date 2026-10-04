import CoreLocation

final class BackgroundLocationManager: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundLocationManager()
    
    private let manager = CLLocationManager()
    private var wantsRunning = false
    
    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }
    
    func start() {
        guard UserDefaults.standard.bool(forKey: "keepAliveLocation") else {
            print("[BGLoc] start() skipped: toggle is off")
            return
        }
        print("[BGLoc] start() called")
        wantsRunning = true
        switch manager.authorizationStatus {
        case .authorizedAlways:
            print("[BGLoc] Already authorized, starting updates")
            manager.startUpdatingLocation()
        case .authorizedWhenInUse, .notDetermined:
            print("[BGLoc] Requesting Always authorization")
            manager.requestAlwaysAuthorization()
        default:
            print("[BGLoc] Permission denied/restricted, falling back to audio")
            BackgroundAudioManager.shared.start()
        }
    }
    
    func stop() {
        print("[BGLoc] stop() called")
        wantsRunning = false
        manager.stopUpdatingLocation()
    }
    
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        print("[BGLoc] Authorization changed to: \(m.authorizationStatus.rawValue)")
        switch m.authorizationStatus {
        case .authorizedAlways:
            if wantsRunning {
                print("[BGLoc] Starting updates")
                m.startUpdatingLocation()
            }
        case .denied, .restricted:
            if wantsRunning {
                print("[BGLoc] Permission denied, falling back to audio")
                BackgroundAudioManager.shared.start()
            }
        default: 
            break
        }
    }
    
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        print("[BGLoc] Location error: \(error)")
    }
}
