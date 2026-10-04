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
            return
        }
        wantsRunning = true
        switch manager.authorizationStatus {
        case .authorizedAlways:
            manager.startUpdatingLocation()
        case .authorizedWhenInUse, .notDetermined:
            manager.requestAlwaysAuthorization()
        default:
            BackgroundAudioManager.shared.start()
        }
    }
    
    func stop() {
        wantsRunning = false
        manager.stopUpdatingLocation()
    }
    
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedAlways:
            if wantsRunning {
                m.startUpdatingLocation()
            }
        case .denied, .restricted:
            if wantsRunning {
                BackgroundAudioManager.shared.start()
            }
        default: 
            break
        }
    }
    
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
    }
}
