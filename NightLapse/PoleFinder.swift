import SwiftUI
import CoreMotion
import CoreLocation

/// Подсказка, куда навести телефон, чтобы небесный полюс (рядом Полярная звезда) был в центре кадра.
/// Тогда на фото «Следы» звёзды рисуют круги вокруг одной точки.
/// Высота полюса над горизонтом = широта места, направление - точно на север (в южном полушарии - на юг)
final class PoleFinder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var text = ""
    /// Куда повернуть: x - вправо, y - вверх, в градусах
    @Published var arrow = CGVector(dx: 0, dy: 0)
    @Published var centered = false
    @Published private(set) var on = false

    private let motion = CMMotionManager()
    private let loc = CLLocationManager()
    private var lat: Double?
    private var magnetic = false

    override init() {
        super.init()
        loc.delegate = self
        loc.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func toggle() { on ? stop() : start() }

    func start() {
        on = true
        text = "Ищу север..."
        switch loc.authorizationStatus {
        case .notDetermined: loc.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: loc.requestLocation()
        default: break
        }
        guard motion.isDeviceMotionAvailable else {
            text = "Нет компаса на этом устройстве"
            return
        }
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let ref: CMAttitudeReferenceFrame = frames.contains(.xTrueNorthZVertical) ? .xTrueNorthZVertical : .xMagneticNorthZVertical
        magnetic = ref == .xMagneticNorthZVertical
        motion.deviceMotionUpdateInterval = 1.0 / 10
        motion.startDeviceMotionUpdates(using: ref, to: .main) { [weak self] m, _ in
            guard let self, let m else { return }
            self.update(m.attitude.rotationMatrix)
        }
    }

    func stop() {
        on = false
        motion.stopDeviceMotionUpdates()
    }

    private func update(_ r: CMRotationMatrix) {
        // Куда смотрит задняя камера: ось -Z телефона в осях «X - север, Y - запад, Z - вверх»
        let cx = -r.m31, cy = -r.m32, cz = -r.m33
        let camAlt = asin(max(-1, min(1, cz))) * 180 / .pi
        let camAz = atan2(-cy, cx) * 180 / .pi   // от севера по часовой: восток +90
        let south = (lat ?? 45) < 0
        let poleAz: Double = south ? 180 : 0
        let poleAlt = lat.map { abs($0) }
        var daz = poleAz - camAz
        while daz > 180 { daz -= 360 }
        while daz < -180 { daz += 360 }
        let name = south ? "Южный полюс мира" : "Полярная звезда"
        guard let pa = poleAlt else {
            // Широты нет - ведём только по стороне света
            centered = false
            arrow = CGVector(dx: daz, dy: 0)
            text = abs(daz) < 4
                ? "Север в центре. Подними телефон на столько градусов, какая у тебя широта"
                : "\(name): \(side(daz)). Дай доступ к геопозиции, чтобы знать высоту"
            return
        }
        let dalt = pa - camAlt
        // Угол между осью камеры и полюсом
        let pr = pa * .pi / 180, pz = poleAz * .pi / 180
        let px = cos(pr) * cos(pz), py = -cos(pr) * sin(pz), pzz = sin(pr)
        let dot = max(-1, min(1, px * cx + py * cy + pzz * cz))
        let off = acos(dot) * 180 / .pi
        arrow = CGVector(dx: daz, dy: dalt)
        centered = off < 4
        if centered {
            text = "Полюс в центре: следы будут кругами"
        } else {
            var parts: [String] = []
            if abs(daz) >= 2 { parts.append(side(daz)) }
            if abs(dalt) >= 2 { parts.append(dalt > 0 ? "выше \(Int(dalt.rounded()))°" : "ниже \(Int((-dalt).rounded()))°") }
            text = "\(name): " + parts.joined(separator: ", ")
        }
        if magnetic { text += " (по компасу, ±5°)" }
    }

    private func side(_ d: Double) -> String {
        d > 0 ? "правее \(Int(d.rounded()))°" : "левее \(Int((-d).rounded()))°"
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if on, m.authorizationStatus == .authorizedWhenInUse || m.authorizationStatus == .authorizedAlways {
            m.requestLocation()
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        if let c = l.last?.coordinate.latitude { lat = c }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}

/// Плашка на превью: «Где Полярная звезда?» → стрелка и подсказка
struct PolePill: View {
    @ObservedObject var p: PoleFinder
    var pal = Pal(night: false)

    var body: some View {
        Button {
            p.toggle()
        } label: {
            HStack(spacing: 6) {
                if p.on {
                    Image(systemName: p.centered ? "checkmark.circle.fill" : "arrow.up")
                        .rotationEffect(p.centered ? .zero : .radians(atan2(p.arrow.dx, p.arrow.dy)))
                        .foregroundStyle(p.centered ? (pal.night ? pal.accent : Color(red: 0.45, green: 0.80, blue: 0.50)) : pal.accent)
                    Text(p.text)
                    Image(systemName: "xmark").font(.caption2).opacity(0.6)
                } else {
                    Image(systemName: "location.north.circle")
                    Text("Где Полярная звезда?")
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(pal.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.55), in: Capsule())
        }
        .buttonStyle(.plain)
        .onDisappear { p.stop() }
    }
}
