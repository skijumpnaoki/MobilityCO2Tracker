import SwiftUI
import CoreLocation
import CoreMotion
import Charts
import MapKit
import UIKit
import AVFoundation
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import Network

// MARK: - Main App View
@main
struct MobilityCO2TrackerApp: App {
    @StateObject private var navigationManager = NavigationManager()
    @StateObject private var networkMonitor = NetworkMonitor()

    init() {
        FirebaseApp.configure() // Firebase を初期化
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(navigationManager)
                .environmentObject(networkMonitor)
                .onAppear {
                    TripManager.shared.start()
                    setupAudioSession()
                }
        }
    }
}

// MARK: - Network Monitor
class NetworkMonitor: ObservableObject {
    @Published var isConnected: Bool = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
                print("ネットワーク状態: \(self?.isConnected == true ? "オンライン" : "オフライン")")
            }
        }
        monitor.start(queue: queue)
    }
}

// MARK: - Emission Factors
enum EmissionFactor: Double, CaseIterable, Identifiable, Codable {
    case walk    = 0.0
    case bicycle = 0.0001
    case car     = 0.120
    case bus     = 0.065
    case train   = 0.041
    case plane   = 0.255
    case ferry   = 0.160

    var id: Double { rawValue }
    var label: String {
        switch self {
        case .walk:    return "Walk / 徒歩🚶"
        case .bicycle: return "Bicycle / 自転車🚲"
        case .car:     return "Car / 乗用車🚗"
        case .bus:     return "Bus / バス🚌"
        case .train:   return "Train / 鉄道🚃"
        case .plane:   return "Plane / 航空機✈️"
        case .ferry:   return "Ferry / フェリー🚢"
        }
    }
    var pixelIcon: String {
        switch self {
        case .walk:    return "pixel_kun_walk"
        case .bicycle: return "pixel_kun_bicycle"
        case .car:     return "pixel_kun_car"
        case .bus:     return "pixel_kun_bus"
        case .train:   return "pixel_kun_train"
        case .plane:   return "pixel_kun_plane"
        case .ferry:   return "pixel_kun_ferry"
        }
    }
    var color: Color {
        switch self {
        case .walk:    return Color.green
        case .bicycle: return Color.blue
        case .car:     return Color.red
        case .bus:     return Color.orange
        case .train:   return Color.purple
        case .plane:   return Color.gray
        case .ferry:   return Color.cyan
        }
    }
    static func fromMLLabel(_ label: String) -> EmissionFactor? {
        switch label {
        case "walk":    return .walk
        case "bicycle": return .bicycle
        case "car":     return .car
        case "bus":     return .bus
        case "train":   return .train
        case "plane":   return .plane
        case "ferry":   return .ferry
        default:        return nil
        }
    }
}

// MARK: - Trip Segment
struct TripSegment: Identifiable, Codable, Hashable {
    let id: UUID
    let start: Date
    let end: Date
    let startLatitude: Double
    let startLongitude: Double
    let endLatitude: Double
    let endLongitude: Double
    let distance: CLLocationDistance
    var mode: EmissionFactor

    var emissions: Double { (distance / 1000) * mode.rawValue }
    var startLocation: CLLocation { CLLocation(latitude: startLatitude, longitude: startLongitude) }
    var endLocation: CLLocation { CLLocation(latitude: endLatitude, longitude: endLongitude) }
}

// MARK: - TripManager
final class TripManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = TripManager()
    @Published var segments: [TripSegment] = []
    @Published var pendingSegments: [TripSegment] = []

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionActivityManager()
    private let geocoder = CLGeocoder()
    private let db = Firestore.firestore()

    private var currentStart: CLLocation?
    private var lastKnownLocation: CLLocation?
    private var currentMode: EmissionFactor = .walk
    private var lastWaterCheck: Date?
    private var isOverWater: Bool?
    private var accumulatedDistance: CLLocationDistance = 0
    private var lastUpdateTime: Date?
    private let waterInterval: TimeInterval = 60
    private let distanceThreshold: CLLocationDistance = 50
    private let accuracyThreshold: CLLocationDistance = 100
    private let minimumUpdateInterval: TimeInterval = 10
    private var currentUser: User?
    private var listener: ListenerRegistration?

    private override init() {
        super.init()
        loadSegments()
        loadPendingSegments()
        setupLocationManager()
        setupMotionManager()
        _ = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self = self else { return }
            self.currentUser = user
            if let user = user {
                print("ログイン検出: UID = \(user.uid)")
                self.fetchSegmentsFromServer(userId: user.uid)
                self.sendPendingSegments()
            } else {
                print("ログアウト検出")
                self.listener?.remove()
                self.listener = nil
                self.segments = self.segments.filter { segment in
                    self.pendingSegments.contains { $0.id == segment.id }
                }
            }
        }
    }

    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.activityType = .automotiveNavigation
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    private func setupMotionManager() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            print("モーションアクティビティ利用不可")
            return
        }
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self = self, let act = activity else { return }
            print("モーション検出: automotive=\(act.automotive), cycling=\(act.cycling), walking=\(act.walking)")
            self.predictMode(activity: act)
        }
    }

    private func predictMode(activity: CMMotionActivity) {
        if activity.automotive { self.currentMode = .car }
        else if activity.cycling { self.currentMode = .bicycle }
        else if activity.walking { self.currentMode = .walk }
        else { self.currentMode = .walk }
        print("予測モード: \(self.currentMode.label)")
    }

    func start() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            print("位置情報許可をリクエスト")
            locationManager.requestWhenInUseAuthorization()
        case .restricted, .denied:
            print("位置情報アクセスが拒否されています")
        case .authorizedAlways, .authorizedWhenInUse:
            print("位置情報更新を開始")
            startLocationUpdates()
            startMotionUpdates()
            if currentUser != nil {
                sendPendingSegments()
            }
        @unknown default:
            break
        }
    }

    private func startLocationUpdates() {
        if locationManager.authorizationStatus == .authorizedAlways {
            locationManager.allowsBackgroundLocationUpdates = true
        }
        locationManager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        print("位置情報許可が変更されました: \(manager.authorizationStatus.rawValue)")
        switch manager.authorizationStatus {
        case .authorizedAlways:
            print("常に許可が取得済み、バックグラウンド位置情報更新を有効化")
            manager.allowsBackgroundLocationUpdates = true
            startLocationUpdates()
            startMotionUpdates()
            if currentUser != nil {
                sendPendingSegments()
            }
        case .authorizedWhenInUse:
            print("使用中のみ許可が取得済み、位置情報更新開始")
            manager.allowsBackgroundLocationUpdates = false
            startLocationUpdates()
            startMotionUpdates()
            if currentUser != nil {
                sendPendingSegments()
            }
        case .denied, .restricted:
            print("位置情報アクセスが拒否されました")
        case .notDetermined:
            print("許可が未決定、リクエストを再試行")
            manager.requestWhenInUseAuthorization()
        @unknown default:
            print("未知の許可状態: \(manager.authorizationStatus.rawValue)")
        }
    }

    private func startMotionUpdates() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            print("モーションアクティビティ利用不可")
            return
        }
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self = self, let act = activity else { return }
            self.predictMode(activity: act)
        }
    }

    private func resetWaterChecks() {
        lastWaterCheck = nil
        isOverWater = nil
    }

    private func processLocation(_ location: CLLocation) {
        if location.horizontalAccuracy > accuracyThreshold {
            print("位置精度が低すぎます: \(location.horizontalAccuracy)m")
            return
        }

        lastKnownLocation = location

        if let lastTime = lastUpdateTime {
            let timeSinceLastUpdate = Date().timeIntervalSince(lastTime)
            guard timeSinceLastUpdate >= minimumUpdateInterval else {
                print("更新間隔が短すぎます: \(timeSinceLastUpdate)s")
                return
            }
        }
        lastUpdateTime = Date()

        guard let startLoc = currentStart else {
            print("初回位置設定: \(location.coordinate)")
            currentStart = location
            return
        }
        let dist = location.distance(from: startLoc)
        print("距離: \(dist)m, モード: \(currentMode.label), 速度: \(location.speed)")

        if location.speed > 70 {
            currentMode = .plane
            resetWaterChecks()
        } else if location.speed > 20 && currentMode != .car {
            currentMode = .train
            resetWaterChecks()
        } else if (5...20).contains(location.speed) && location.horizontalAccuracy < 30 {
            let now = Date()
            if lastWaterCheck == nil || now.timeIntervalSince(lastWaterCheck!) > waterInterval {
                lastWaterCheck = now
                geocoder.reverseGeocodeLocation(location) { [weak self] places, _ in
                    guard let self = self, let pm = places?.first else { return }
                    self.isOverWater = (pm.ocean != nil) || (pm.inlandWater != nil)
                    print("水域チェック: isOverWater = \(self.isOverWater ?? false)")
                    if self.isOverWater == true {
                        self.currentMode = .ferry
                    }
                }
            }
        } else {
            resetWaterChecks()
        }

        if dist >= distanceThreshold {
            let seg = TripSegment(
                id: UUID(),
                start: startLoc.timestamp,
                end: location.timestamp,
                startLatitude: startLoc.coordinate.latitude,
                startLongitude: startLoc.coordinate.longitude,
                endLatitude: location.coordinate.latitude,
                endLongitude: location.coordinate.longitude,
                distance: dist,
                mode: currentMode
            )
            print("セグメント生成: \(seg.mode.label), 距離: \(dist)m, CO2: \(seg.emissions)kg")
            DispatchQueue.main.async {
                self.segments.append(seg)
                self.saveSegments()
                if self.currentUser != nil {
                    self.sendSegmentToServer(segment: seg)
                }
            }
            currentStart = location
        }
    }

    // MARK: Persistence
    func saveSegments() {
        do {
            let data = try JSONEncoder().encode(segments)
            UserDefaults.standard.set(data, forKey: "segments")
            print("セグメント保存: \(segments.count)件")
        } catch {
            print("セグメント保存エラー: \(error)")
        }
    }

    func loadSegments() {
        if let data = UserDefaults.standard.data(forKey: "segments") {
            do {
                segments = try JSONDecoder().decode([TripSegment].self, from: data)
                print("セグメント読み込み: \(segments.count)件")
            } catch {
                print("セグメント読み込みエラー: \(error)")
            }
        }
    }

    // MARK: Pending Segments
    private func savePendingSegments() {
        do {
            let data = try JSONEncoder().encode(pendingSegments)
            UserDefaults.standard.set(data, forKey: "pendingSegments")
            print("送信待ちセグメント保存: \(pendingSegments.count)件")
        } catch {
            print("送信待ちセグメント保存エラー: \(error)")
        }
    }

    private func loadPendingSegments() {
        if let data = UserDefaults.standard.data(forKey: "pendingSegments") {
            do {
                pendingSegments = try JSONDecoder().decode([TripSegment].self, from: data)
                print("送信待ちセグメント読み込み: \(pendingSegments.count)件")
            } catch {
                print("送信待ちセグメント読み込みエラー: \(error)")
            }
        }
    }

    // MARK: Server Communication
    private func sendSegmentToServer(segment: TripSegment) {
        guard let userId = currentUser?.uid else {
            print("ユーザーがログインしていません")
            pendingSegments.append(segment)
            savePendingSegments()
            return
        }

        pendingSegments.append(segment)
        savePendingSegments()

        sendSegmentsToServer(segments: [segment], userId: userId) { success in
            if success {
                DispatchQueue.main.async {
                    self.pendingSegments.removeAll { $0.id == segment.id }
                    self.savePendingSegments()
                }
            }
        }
    }

    public func sendPendingSegments() { // Changed to public
        guard let userId = currentUser?.uid else {
            print("ユーザーがログインしていません")
            return
        }

        guard !pendingSegments.isEmpty else { return }
        print("送信待ちセグメントを送信: \(pendingSegments.count)件")
        sendSegmentsToServer(segments: pendingSegments, userId: userId) { success in
            if success {
                DispatchQueue.main.async {
                    self.pendingSegments.removeAll()
                    self.savePendingSegments()
                }
            }
        }
    }

    private func sendSegmentsToServer(segments: [TripSegment], userId: String, completion: @escaping (Bool) -> Void) {
        let batch = db.batch()

        for segment in segments {
            let docRef = db.collection("users").document(userId).collection("segments").document(segment.id.uuidString)
            do {
                let data = try JSONEncoder().encode(segment)
                let json = try JSONSerialization.jsonObject(with: data, options: [])
                batch.setData(json as! [String: Any], forDocument: docRef)
            } catch {
                print("エンコードエラー: \(error)")
                completion(false)
                return
            }
        }

        batch.commit { error in
            if let error = error {
                print("Firestore 書き込みエラー: \(error)")
                completion(false)
            } else {
                print("Firestore に送信成功")
                completion(true)
            }
        }
    }

    private func fetchSegmentsFromServer(userId: String) {
        listener?.remove()
        
        listener = db.collection("users").document(userId).collection("segments")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self = self else { return }
                if let error = error {
                    print("サーバーデータ取得エラー: \(error)")
                    return
                }
                guard let snapshot = snapshot else {
                    print("スナップショットがありません")
                    return
                }

                var newSegments: [TripSegment] = []
                for document in snapshot.documents {
                    do {
                        let data = try JSONSerialization.data(withJSONObject: document.data(), options: [])
                        let segment = try JSONDecoder().decode(TripSegment.self, from: data)
                        newSegments.append(segment)
                    } catch {
                        print("デコードエラー: \(error)")
                    }
                }

                DispatchQueue.main.async {
                    let existingIds = Set(self.segments.map { $0.id })
                    let newUniqueSegments = newSegments.filter { !existingIds.contains($0.id) }
                    self.segments.append(contentsOf: newUniqueSegments)
                    self.saveSegments()
                    print("サーバーからデータを取得: \(newSegments.count)件")
                }
            }
    }

    func updateMode(for segmentId: UUID, to newMode: EmissionFactor) {
        if let index = segments.firstIndex(where: { $0.id == segmentId }) {
            var updatedSegment = segments[index]
            updatedSegment.mode = newMode
            segments[index] = updatedSegment
            saveSegments()
        }
    }

    // MARK: Export CSV
    func exportCSV() {
        do {
            var csvString = "ID,Start,End,StartLatitude,StartLongitude,EndLatitude,EndLongitude,Distance(km),Mode,Emissions(kg CO₂)\n"
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            
            for segment in segments {
                let start = formatter.string(from: segment.start)
                let end = formatter.string(from: segment.end)
                let distanceKm = segment.distance / 1000
                let row = "\(segment.id.uuidString),\(start),\(end),\(segment.startLatitude),\(segment.startLongitude),\(segment.endLatitude),\(segment.endLongitude),\(String(format: "%.3f", distanceKm)),\(segment.mode.label),\(String(format: "%.3f", segment.emissions))\n"
                csvString.append(row)
            }
            
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MobilityCO2Segments.csv")
            try csvString.write(to: url, atomically: true, encoding: .utf8)
            
            UIApplication.shared.topMost?.present(UIActivityViewController(activityItems: [url], applicationActivities: nil), animated: true)
            print("CSV エクスポート成功: \(url.path)")
        } catch {
            print("CSV エクスポートエラー: \(error)")
        }
    }

    // MARK: Aggregation
    func aggregatedEmissions(granularity: Calendar.Component) -> [Date: Double] {
        var result: [Date: Double] = [:]
        let cal = Calendar.current
        for seg in segments {
            let key: Date
            switch granularity {
            case .day:
                key = cal.startOfDay(for: seg.start)
            case .weekOfYear:
                let components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: seg.start)
                key = cal.date(from: components) ?? seg.start
            case .month:
                key = cal.date(from: cal.dateComponents([.year, .month], from: seg.start)) ?? seg.start
            default:
                key = cal.startOfDay(for: seg.start)
            }
            result[key, default: 0] += seg.emissions
        }
        return result
    }

    // MARK: CLLocationManagerDelegate
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            print("位置情報更新: \(loc.coordinate)")
            processLocation(loc)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("位置情報エラー: \(error)")
    }
}

// MARK: - Merge Extension
extension Array where Element == TripSegment {
    func merged() -> [TripSegment] {
        guard !isEmpty else { return [] }
        var result: [TripSegment] = []
        var current = self[0]
        for seg in dropFirst() {
            if seg.mode == current.mode && abs(seg.start.timeIntervalSince(current.end)) < 1 {
                current = TripSegment(
                    id: current.id,
                    start: current.start,
                    end: seg.end,
                    startLatitude: current.startLatitude,
                    startLongitude: current.startLongitude,
                    endLatitude: seg.endLatitude,
                    endLongitude: seg.endLongitude,
                    distance: current.distance + seg.distance,
                    mode: current.mode
                )
            } else {
                result.append(current)
                current = seg
            }
        }
        result.append(current)
        return result
    }
}

// MARK: - Cloud Properties
struct Cloud: Identifiable {
    let id: Int
    let initialX: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let opacity: Double
    let animationDuration: Double
}

// MARK: - Pixel World Background
struct PixelWorldBackground: View {
    @State private var clouds: [Cloud] = (0..<5).map { index in
        Cloud(
            id: index,
            initialX: CGFloat.random(in: -100...UIScreen.main.bounds.width),
            y: CGFloat.random(in: 50...UIScreen.main.bounds.height * 0.5),
            width: CGFloat.random(in: 80...120),
            height: CGFloat.random(in: 40...60),
            opacity: Double.random(in: 0.5...0.9),
            animationDuration: Double.random(in: 15...25)
        )
    }
    @State private var cloudOffsets: [Int: CGFloat] = [:]
    @State private var stars: [StarPosition] = (0..<20).map { _ in
        StarPosition(
            x: CGFloat.random(in: 0...UIScreen.main.bounds.width),
            y: CGFloat.random(in: 0...UIScreen.main.bounds.height)
        )
    }
    
    var body: some View {
        ZStack {
            Color(hex: "#1A2A44")
                .overlay(
                    ForEach(stars) { star in
                        Circle()
                            .fill(Color.white)
                            .frame(width: 2, height: 2)
                            .position(x: star.x, y: star.y)
                    }
                )
            
            Image("PIXELPLANET")
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
                .position(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height * 0.75)
                .opacity(0.8)
            
            ForEach(clouds) { cloud in
                Image("pixelcloud")
                    .resizable()
                    .scaledToFit()
                    .frame(width: cloud.width, height: cloud.height)
                    .opacity(cloud.opacity)
                    .offset(x: (cloudOffsets[cloud.id] ?? cloud.initialX), y: cloud.y)
                    .onAppear {
                        withAnimation(.linear(duration: cloud.animationDuration).repeatForever(autoreverses: false)) {
                            cloudOffsets[cloud.id] = UIScreen.main.bounds.width + cloud.width
                        }
                    }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Pixel Kun View
struct PixelKunView: View {
    let co2Saved: Double
    @State private var isJumping = false
    
    var body: some View {
        VStack {
            Image("pixel_kun")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .offset(y: isJumping ? -20 : 0)
                .animation(.easeInOut(duration: 0.5).repeatCount(3), value: isJumping)
            
            Text("CO₂削減: \(String(format: "%.2f", co2Saved))kg")
                .font(.system(size: 16))
                .foregroundColor(.white)
        }
        .onChange(of: co2Saved) { _ in
            DispatchQueue.main.async {
                isJumping.toggle()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    playSound(name: "jump", volume: 0.5)
                }
            }
        }
    }
}

// MARK: - RealMapView
struct RealMapView: UIViewRepresentable {
    let segments: [TripSegment]
    @State private var pixelKunPosition: CLLocationCoordinate2D?

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RealMapView
        init(_ parent: RealMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 4
                return renderer
            }
            return MKOverlayRenderer()
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKPointAnnotation {
                let identifier = "PinAnnotation"
                var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                if annotationView == nil {
                    annotationView = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    annotationView?.canShowCallout = true
                } else {
                    annotationView?.annotation = annotation
                }
                return annotationView
            } else if annotation is PixelKunAnnotation {
                let identifier = "PixelKun"
                var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                if annotationView == nil {
                    annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    let imageView = UIImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
                    imageView.image = UIImage(named: "pixel_kun")
                    annotationView?.addSubview(imageView)
                    annotationView?.frame = imageView.frame
                } else {
                    annotationView?.annotation = annotation
                }
                return annotationView
            }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        guard !segments.isEmpty else { return }

        var allCoordinates: [CLLocationCoordinate2D] = []
        for segment in segments {
            let startCoord = segment.startLocation.coordinate
            let endCoord = segment.endLocation.coordinate
            allCoordinates.append(startCoord)
            allCoordinates.append(endCoord)

            let polyline = MKPolyline(coordinates: [startCoord, endCoord], count: 2)
            mapView.addOverlay(polyline)

            let startPin = MKPointAnnotation()
            startPin.coordinate = startCoord
            startPin.title = "開始"
            startPin.subtitle = segment.start.formatted(.dateTime.hour().minute())
            mapView.addAnnotation(startPin)

            let endPin = MKPointAnnotation()
            endPin.coordinate = endCoord
            endPin.title = "終了"
            endPin.subtitle = segment.end.formatted(.dateTime.hour().minute())
            mapView.addAnnotation(endPin)
        }

        if let firstSegment = segments.first {
            let startCoord = firstSegment.startLocation.coordinate
            let pixelKun = PixelKunAnnotation(coordinate: pixelKunPosition ?? startCoord)
            mapView.addAnnotation(pixelKun)

            if pixelKunPosition == nil {
                pixelKunPosition = startCoord
                animatePixelKun(mapView: mapView, coordinates: allCoordinates, annotation: pixelKun)
            }
        }

        let polyline = MKPolyline(coordinates: allCoordinates, count: allCoordinates.count)
        mapView.setVisibleMapRect(polyline.boundingMapRect, edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: true)
    }

    private func animatePixelKun(mapView: MKMapView, coordinates: [CLLocationCoordinate2D], annotation: PixelKunAnnotation) {
        guard !coordinates.isEmpty else { return }
        var currentIndex = 0

        func moveToNextCoordinate() {
            guard currentIndex < coordinates.count else {
                currentIndex = 0
                pixelKunPosition = coordinates[0]
                annotation.setCoordinate(coordinates[0])
                moveToNextCoordinate()
                return
            }

            let nextCoord = coordinates[currentIndex]
            let duration = 2.0

            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            annotation.setCoordinate(nextCoord)
            CATransaction.commit()

            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                self.pixelKunPosition = nextCoord
                currentIndex += 1
                moveToNextCoordinate()
            }
        }

        moveToNextCoordinate()
    }
}

class PixelKunAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        super.init()
    }

    func setCoordinate(_ newCoordinate: CLLocationCoordinate2D) {
        self.coordinate = newCoordinate
    }
}

// MARK: - RouteMapView
struct RouteMapView: UIViewRepresentable {
    let locations: [CLLocation]
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        return map
    }
    func updateUIView(_ uiView: MKMapView, context: Context) {
        uiView.removeOverlays(uiView.overlays)
        guard locations.count > 1 else { return }
        let coords = locations.map { $0.coordinate }
        let poly = MKPolyline(coordinates: coords, count: coords.count)
        uiView.addOverlay(poly)
        uiView.setVisibleMapRect(poly.boundingMapRect, edgePadding: .init(top: 40, left: 40, bottom: 40, right: 40), animated: true)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let poly = overlay as? MKPolyline else { return MKOverlayRenderer() }
            let r = MKPolylineRenderer(polyline: poly)
            r.lineWidth = 4
            r.strokeColor = .systemBlue
            return r
        }
    }
}

// MARK: - TripTimelineView
struct TripTimelineView: View {
    var segments: [TripSegment]
    var onUpdate: (TripSegment) -> Void
    @State private var editingSegment: TripSegment?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RealMapView(segments: segments)
                .frame(height: 200)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(segments.sorted(by: { $0.start < $1.start })) { seg in
                        HStack(alignment: .top, spacing: 12) {
                            VStack {
                                Circle().fill(Color(hex: "#2ECC71")).frame(width: 10, height: 10)
                                Rectangle().fill(Color.white.opacity(0.4))
                                    .frame(width: 2).frame(maxHeight: .infinity)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(seg.start, style: .time)
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                                HStack {
                                    Image(seg.mode.pixelIcon)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 30, height: 30)
                                    Text(seg.mode.label)
                                        .font(.body)
                                        .foregroundColor(.white)
                                }
                                Text(String(format: "%.1f km", seg.distance / 1000))
                                    .font(.caption)
                                    .foregroundColor(.white)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editingSegment = seg }
                    }
                }
                .padding(.horizontal)
            }
            .frame(maxHeight: 300)
        }
        .padding(.vertical)
        .sheet(item: $editingSegment) { seg in
            SegmentEditor(segment: seg) { newMode in
                var updated = seg
                updated.mode = newMode
                onUpdate(updated)
                TripManager.shared.updateMode(for: seg.id, to: newMode)
            }
        }
    }
}

// MARK: - SegmentEditor
struct SegmentEditor: View {
    let segment: TripSegment
    let onSave: (EmissionFactor) -> Void
    @Environment(\.presentationMode) private var presentationMode
    @State private var selectedMode: EmissionFactor

    init(segment: TripSegment, onSave: @escaping (EmissionFactor) -> Void) {
        self.segment = segment
        self.onSave = onSave
        _selectedMode = State(initialValue: segment.mode)
    }

    var body: some View {
        NavigationView {
            ZStack {
                PixelWorldBackground()
                Form {
                    Section(header: Text("移動手段を選択").foregroundColor(.white)) {
                        Picker("モード", selection: $selectedMode) {
                            ForEach(EmissionFactor.allCases) { mode in
                                HStack {
                                    Image(mode.pixelIcon)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 40, height: 40)
                                        .padding(4)
                                    Text(mode.label)
                                        .foregroundColor(.white)
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 12)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .background(Color(hex: "#2A3A54"))
                                .cornerRadius(8)
                                .tag(mode)
                            }
                        }
                        .pickerStyle(.inline)
                        .listRowBackground(Color(hex: "#1A2A44"))
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color(hex: "#1A2A44"))
            }
            .navigationTitle("セグメント編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .foregroundColor(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(selectedMode)
                        presentationMode.wrappedValue.dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
            .toolbarBackground(Color(hex: "#1A2A44"), for: .navigationBar)
        }
    }
}

// MARK: - ChartView
struct ChartView: View {
    enum ChartType: String, CaseIterable, Identifiable {
        case daily   = "日別"
        case weekly  = "週別"
        case monthly = "月別"

        var id: Self { self }
        var component: Calendar.Component {
            switch self {
            case .daily:   return .day
            case .weekly:  return .weekOfYear
            case .monthly: return .month
            }
        }
        var xAxisLabel: String {
            switch self {
            case .daily:   return "日付（1日単位）"
            case .weekly:  return "日付（週単位）"
            case .monthly: return "日付（月単位）"
            }
        }
    }

    @State private var chartType: ChartType = .weekly
    @State private var selectedDate: Date?
    @State private var showDetailModal = false
    var segments: [TripSegment]

    private func aggregated(by component: Calendar.Component) -> [Date: Double] {
        var result: [Date: Double] = [:]
        let cal = Calendar.current
        for seg in segments {
            let key: Date
            switch component {
            case .day:
                key = cal.startOfDay(for: seg.start)
            case .weekOfYear:
                var components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: seg.start)
                components.weekday = 1
                key = cal.date(from: components) ?? seg.start
            case .month:
                key = cal.date(from: cal.dateComponents([.year, .month], from: seg.start)) ?? seg.start
            default:
                key = cal.startOfDay(for: seg.start)
            }
            result[key, default: 0] += seg.emissions
        }
        return result
    }

    private func segmentsForDate(_ date: Date) -> [TripSegment] {
        let cal = Calendar.current
        return segments.filter { cal.isDate($0.start, inSameDayAs: date) }
    }

    private func handleTap(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Bool {
        if let date = proxy.value(atX: location.x, as: Date.self) {
            let cal = Calendar.current
            let startOfDay = cal.startOfDay(for: date)
            selectedDate = startOfDay
            showDetailModal = true
            return true
        }
        return false
    }

    var body: some View {
        VStack {
            Picker("集計期間", selection: $chartType) {
                ForEach(ChartType.allCases) { t in
                    Text(t.rawValue).tag(t)
                        .foregroundColor(.white)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            let data = aggregated(by: chartType.component)
            let sortedDates = Array(data.keys.sorted())
            
            let chartData: [(date: Date, value: Double)] = sortedDates.compactMap { date in
                if let value = data[date] {
                    return (date, value)
                }
                return nil
            }

            Chart {
                ForEach(chartData, id: \.date) { entry in
                    BarMark(
                        x: .value("日付", entry.date, unit: chartType.component),
                        y: .value("CO₂（kg）", entry.value)
                    )
                    .foregroundStyle(Color(hex: "#2ECC71"))
                    .annotation(position: .top) {
                        Image("pixel_kun")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    _ = handleTap(at: value.location, proxy: proxy, geometry: geometry)
                                }
                        )
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { value in
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            if chartType == .daily {
                                Text(date, format: .dateTime.month(.twoDigits).day(.twoDigits))
                                    .foregroundColor(.white)
                            } else if chartType == .weekly {
                                Text(date, format: .dateTime.month(.twoDigits).day(.twoDigits))
                                    .foregroundColor(.white)
                            } else {
                                Text(date, format: .dateTime.month(.twoDigits))
                                    .foregroundColor(.white)
                            }
                        }
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.5))
                        AxisTick().foregroundStyle(Color.white)
                    }
                }
            }
            .chartXAxisLabel(chartType.xAxisLabel)
            .chartYAxisLabel {
                Text("kg CO₂")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .padding(4)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(4)
            }
            .foregroundColor(.white)
            .frame(height: 220)
            .background(Color(hex: "#1A2A44").opacity(0.7))
            .cornerRadius(12)
            .sheet(isPresented: $showDetailModal) {
                if let selectedDate = selectedDate {
                    SegmentDetailModal(
                        date: selectedDate,
                        segments: segmentsForDate(selectedDate),
                        onDismiss: { showDetailModal = false }
                    )
                }
            }
        }
    }
}

// MARK: - ModeDistributionChart
struct ModeDistributionChart: View {
    var segments: [TripSegment]

    struct ModeData: Identifiable {
        let id: EmissionFactor
        let distance: Double
        var color: Color { id.color }
    }

    private var modeData: [ModeData] {
        let grouped = Dictionary(grouping: segments, by: \.mode)
        return grouped.map { (mode, segs) in
            ModeData(id: mode, distance: segs.reduce(0) { $0 + $1.distance })
        }.sorted { $0.distance > $1.distance }
    }

    var body: some View {
        Chart {
            ForEach(modeData) { data in
                BarMark(
                    x: .value("距離（km）", data.distance / 1000),
                    y: .value("モード", data.id.label)
                )
                .foregroundStyle(data.color)
                .annotation(position: .trailing) {
                    Text("\(String(format: "%.1f", data.distance / 1000))km")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(2)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(4)
                }
            }
        }
        .chartXAxisLabel("距離（km）")
        .chartYAxisLabel("移動手段")
        .foregroundColor(.white)
        .frame(height: 200)
        .background(Color(hex: "#1A2A44").opacity(0.7))
        .cornerRadius(12)
    }
}

// MARK: - TimeOfDayChart
struct TimeOfDayChart: View {
    var segments: [TripSegment]

    enum TimeOfDay: String, CaseIterable, Identifiable {
        case morning = "朝 (6-12時)"
        case afternoon = "昼 (12-18時)"
        case evening = "夜 (18-6時)"

        var id: Self { self }

        static func from(date: Date) -> TimeOfDay {
            let hour = Calendar.current.component(.hour, from: date)
            if (6..<12).contains(hour) { return .morning }
            else if (12..<18).contains(hour) { return .afternoon }
            else { return .evening }
        }
    }

    struct TimeData: Identifiable {
        let id: TimeOfDay
        let emissions: Double
    }

    private var timeData: [TimeData] {
        let grouped = Dictionary(grouping: segments, by: { TimeOfDay.from(date: $0.start) })
        return grouped.map { (time, segs) in
            TimeData(id: time, emissions: segs.reduce(0) { $0 + $1.emissions })
        }.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    var body: some View {
        Chart(timeData) { data in
            BarMark(
                x: .value("時間帯", data.id.rawValue),
                y: .value("CO₂（kg）", data.emissions)
            )
            .foregroundStyle(Color(hex: "#2ECC71"))
        }
        .chartXAxisLabel("時間帯")
        .chartYAxisLabel("kg CO₂")
        .foregroundColor(.white)
        .frame(height: 200)
        .background(Color(hex: "#1A2A44").opacity(0.7))
        .cornerRadius(12)
    }
}

// MARK: - SegmentDetailModal
struct SegmentDetailModal: View {
    let date: Date
    var segments: [TripSegment]
    let onDismiss: () -> Void
    
    var body: some View {
        NavigationStack {
            ZStack {
                PixelWorldBackground()
                VStack {
                    TripTimelineView(segments: segments.merged(), onUpdate: { _ in })
                }
            }
            .navigationTitle("詳細: \(date, format: .dateTime.month(.twoDigits).day(.twoDigits))")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

// MARK: - Sponsor and SponsorBannerView
struct Sponsor: Identifiable, Codable {
    var id: UUID
    let name: String
    let imageURL: String
    let mainLink: String
    let detailLink: String

    init(id: UUID = UUID(), name: String, imageURL: String, mainLink: String, detailLink: String) {
        self.id = id
        self.name = name
        self.imageURL = imageURL
        self.mainLink = mainLink
        self.detailLink = detailLink
    }
}

struct SponsorBannerView: View {
    let sponsors: [Sponsor]
    @State private var currentIndex: Int = 0
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if !sponsors.isEmpty {
                let currentSponsor = sponsors[currentIndex]
                Image(currentSponsor.imageURL)
                    .resizable()
                    .scaledToFit()
                    .transition(.slide)
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .cornerRadius(10)
                    .onTapGesture {
                        if let url = URL(string: currentSponsor.mainLink) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .id(currentSponsor.id)
            } else {
                Text("スポンサーがありません")
                    .foregroundColor(.white)
                    .frame(height: 100)
                    .padding(.horizontal, 16)
            }
        }
        .frame(height: 100)
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.5)) {
                print("スポンサー切り替え: \(currentIndex) -> \((currentIndex + 1) % sponsors.count)")
                guard sponsors.count > 0 else { return }
                currentIndex = (currentIndex + 1) % sponsors.count
            }
        }
        .onAppear {
            print("SponsorBannerView 表示: スポンサー数 \(sponsors.count)")
            currentIndex = 0
        }
    }
}

// MARK: - StarPosition
struct StarPosition: Identifiable, Hashable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
    
    init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }
}

// MARK: - OffsetView
struct OffsetView: View {
    let totalCO2: Double
    let onOffset: () -> Void
    @State private var stars: [StarPosition] = []
    
    var body: some View {
        ZStack {
            Color(hex: "#1A2A44")
            ForEach(stars) { star in
                Circle()
                    .fill(Color.white)
                    .frame(width: 5, height: 5)
                    .position(x: star.x, y: star.y)
            }
            
            VStack {
                Text("総排出量: \(String(format: "%.2f", totalCO2)) kg CO₂")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                Button(action: {
                    onOffset()
                    addStar()
                    playSound(name: "star_collect", volume: 1.0)
                }) {
                    Text("このCO₂をオフセットする")
                        .padding()
                        .background(Color(hex: "#2ECC71"))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
        }
        .frame(height: 150)
        .cornerRadius(12)
        .padding()
    }
    
    private func addStar() {
        let newStar = StarPosition(
            x: CGFloat.random(in: 0...UIScreen.main.bounds.width),
            y: CGFloat.random(in: 0...150)
        )
        stars.append(newStar)
    }
}

// MARK: - Today's Adventure View
struct TodayAdventureView: View {
    let todaySegmentsByMode: [(mode: EmissionFactor, segments: [TripSegment])]
    let totalCO2: Double

    var body: some View {
        ForEach(todaySegmentsByMode, id: \.mode) { group in
            HStack {
                Image(group.mode.pixelIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                Text(group.mode.label)
                    .foregroundColor(.white)
                    .font(.custom("PixelMplus12-Regular", size: 16, relativeTo: .body))
                Spacer()
                Text(String(format: "%.1f km", group.segments.reduce(0) { $0 + $1.distance } / 1000))
                    .foregroundColor(.white)
                    .font(.custom("PixelMplus12-Regular", size: 14, relativeTo: .caption))
            }
            .padding(.vertical, 4)
        }
        HStack {
            Text("合計CO₂")
                .foregroundColor(.white)
                .font(.custom("PixelMplus12-Regular", size: 16, relativeTo: .body))
            Spacer()
            Text(String(format: "%.2f kg", totalCO2))
                .foregroundColor(.white)
                .font(.custom("PixelMplus12-Regular", size: 14, relativeTo: .caption))
        }
    }
}

// MARK: - ReportView
struct ReportView: View {
    @EnvironmentObject var navigationManager: NavigationManager
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @StateObject private var tripManager = TripManager.shared
    @State private var selectedDate = Date()
    @State private var timelineSegments: [TripSegment] = []
    @State private var todaySegments: [TripSegment] = []
    @State private var totalKM: Double = 0
    @State private var totalCO2: Double = 0
    @State private var showOfflineAlert = false
    
    private var todaySegmentsByMode: [(mode: EmissionFactor, segments: [TripSegment])] {
        Dictionary(grouping: todaySegments, by: \.mode)
            .sorted(by: { $0.key.rawValue < $1.key.rawValue })
            .map { (mode: $0.key, segments: $0.value) }
    }

    private let sponsors = [
        Sponsor(
            id: UUID(),
            name: "よつ葉乳業",
            imageURL: "yotsuba",
            mainLink: "https://www.yotsuba.co.jp/",
            detailLink: "https://www.yotsuba.co.jp/company/"
        ),
        Sponsor(
            id: UUID(),
            name: "Traicy",
            imageURL: "traicy",
            mainLink: "https://www.traicy.com/",
            detailLink: "https://www.traicy.com/about"
        ),
        Sponsor(
            id: UUID(),
            name: "植村建設",
            imageURL: "uemura",
            mainLink: "https://www.uemurakk.co.jp/",
            detailLink: "https://www.uemurakk.co.jp/company/"
        )
    ]

    init() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Color(hex: "#1A2A44"))
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                PixelWorldBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        PixelKunView(co2Saved: totalCO2)

                        if !networkMonitor.isConnected {
                            Text("オフラインです。データはローカルに保存されます。")
                                .foregroundColor(.white)
                                .padding()
                                .background(Color.red.opacity(0.8))
                                .cornerRadius(10)
                                .padding(.horizontal)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("サスティナブルスポンサー")
                                .foregroundColor(.white)
                                .font(.custom("PixelMplus12-Regular", size: 12))
                                .padding(.horizontal)

                            SponsorBannerView(sponsors: sponsors)
                                .background(Color.white)
                                .cornerRadius(12)
                                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                        }

                        SectionView(title: "今日の冒険") {
                            TodayAdventureView(todaySegmentsByMode: todaySegmentsByMode, totalCO2: totalCO2)
                        }

                        SectionView(title: "星を守ろう！") {
                            OffsetView(totalCO2: totalCO2) {
                                if let url = URL(string: "https://offset-partner.com") {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }

                        SectionView(title: "冒険の記録") {
                            ChartView(segments: todaySegments)
                                .background(Color(hex: "#1A2A44").opacity(0.7))
                                .cornerRadius(12)
                        }

                        SectionView(title: "詳細分析") {
                            VStack(spacing: 16) {
                                Text("移動手段の割合")
                                    .foregroundColor(.white)
                                    .font(.custom("PixelMplus12-Regular", size: 16))
                                ModeDistributionChart(segments: todaySegments)
                                Text("時間帯別のCO₂排出量")
                                    .foregroundColor(.white)
                                    .font(.custom("PixelMplus12-Regular", size: 16))
                                TimeOfDayChart(segments: todaySegments)
                            }
                        }

                        SectionView(title: "ピクセルくんの軌跡") {
                            DatePicker("日付", selection: $selectedDate, displayedComponents: [.date])
                                .datePickerStyle(.compact)
                                .foregroundColor(.white)
                                .tint(.white)
                            TripTimelineView(segments: timelineSegments.merged(), onUpdate: updateSegment)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("NAOMETER")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        navigationManager.showMenu.toggle()
                    }) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.white)
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    ShareLink(item: "ピクセルくんとCO2削減！\(String(format: "%.2f", totalCO2))kg #NAOMETER", preview: SharePreview("CO2削減", image: Image("pixel_kun"))) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(.white)
                    }
                    Button(action: { tripManager.exportCSV() }) {
                        Image(systemName: "tablecells")
                            .foregroundColor(.white)
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .onAppear {
                loadToday()
                loadTimeline(for: selectedDate)
            }
            .onChange(of: tripManager.segments) { oldValue, newValue in // 修正: 2パラメータを使用
                loadToday()
                loadTimeline(for: selectedDate)
            }
            .onChange(of: networkMonitor.isConnected) { oldValue, newValue in // 修正: 2パラメータを使用
                if newValue {
                    print("オンラインに戻りました。データを同期します。")
                    tripManager.sendPendingSegments()
                } else {
                    print("オフラインになりました。")
                    showOfflineAlert = true
                }
            }
        }
    }
    
    struct SectionView<Content: View>: View {
        let title: String
        let content: Content
        init(title: String, @ViewBuilder content: () -> Content) {
            self.title = title
            self.content = content()
        }
        var body: some View {
            VStack(alignment: .leading) {
                Text(title)
                    .font(.custom("PixelMplus12-Regular", size: 20, relativeTo: .title3))
                    .foregroundColor(.white)
                    .padding(.horizontal)
                content
                    .padding()
                    .background(Color(hex: "#8B5A2B").opacity(0.5))
                    .cornerRadius(12)
                    .padding(.horizontal)
            }
        }
    }

    private func loadToday() {
        let segs = tripManager.segments.filter { Calendar.current.isDateInToday($0.start) }
        todaySegments = segs.sorted(by: { $0.start < $1.start })
        totalKM = todaySegments.reduce(0) { $0 + $1.distance } / 1000
        totalCO2 = todaySegments.reduce(0) { $0 + $1.emissions }
        print("今日のデータ: \(todaySegments.count)件, 距離: \(totalKM)km, CO2: \(totalCO2)kg")
    }

    private func loadTimeline(for date: Date) {
        let cal = Calendar.current
        let segs = tripManager.segments.filter { cal.isDate($0.start, inSameDayAs: date) }
        timelineSegments = segs.sorted(by: { $0.start < $1.start })
        print("タイムラインデータ: \(timelineSegments.count)件")
    }

    private func updateSegment(_ updated: TripSegment) {
        let start = updated.start
        let end = updated.end

        for idx in tripManager.segments.indices {
            let seg = tripManager.segments[idx]
            if seg.start >= start && seg.end <= end {
                tripManager.segments[idx].mode = updated.mode
            }
        }

        tripManager.saveSegments()
        loadToday()
        loadTimeline(for: selectedDate)
    }
}

// MARK: - Color Extension
extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex.replacingOccurrences(of: "#", with: ""))
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Sound Playback
func setupAudioSession() {
    do {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
    } catch {
        print("オーディオセッション設定エラー: \(error)")
    }
}

func playSound(name: String, volume: Float = 1.0) {
    guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else {
        print("効果音ファイルが見つかりません: \(name).mp3")
        return
    }
    do {
        let player = try AVAudioPlayer(contentsOf: url)
        player.volume = volume
        player.play()
        print("効果音再生: \(name).mp3, ボリューム: \(volume)")
    } catch {
        print("効果音エラー: \(error)")
    }
}

// MARK: - UIApplication Extension
extension UIApplication {
    var topMost: UIViewController? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?.rootViewController
    }
}
