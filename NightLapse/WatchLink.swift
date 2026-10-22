import UIKit
import CoreImage
import WatchConnectivity

/// Связь с часами, как «Пульт Камеры»: часы видят кадр и состояние, оттуда можно начать, остановить и сделать тест.
/// Работает, пока приложение на часах открыто (тогда часы «рядом» для iPhone)
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()
    weak var engine: LapseEngine?
    private var timer: Timer?
    /// Часы на связи - только тогда готовим картинку (читается с очереди камеры)
    private var live = false
    private var lastShot: CFTimeInterval = 0
    private var busy = false
    private let q = DispatchQueue(label: "nightlapse.watch", qos: .utility)
    private lazy var ci = CIContext(options: [.useSoftwareRenderer: false])

    func attach(_ e: LapseEngine) {
        engine = e
        guard WCSession.isSupported(), timer == nil else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.push() }
    }

    /// main: раз в секунду - состояние на часы
    private func push() {
        let s = WCSession.default
        live = s.activationState == .activated && s.isReachable
        guard live, let e = engine else { return }
        let phase: String
        switch e.phase {
        case .idle: phase = "idle"
        case .test: phase = "test"
        case .waiting: phase = "waiting"
        case .recording: phase = "rec"
        case .paused: phase = "paused"
        case .saving: phase = "saving"
        }
        let m: [String: Any] = [
            "phase": phase,
            "status": e.status,
            "frames": e.framesDone,
            "elapsed": e.elapsed,
            "battery": e.battery,
            "sub": e.subTotal > 1 ? Double(e.subDone) / Double(e.subTotal) : 0,
        ]
        s.sendMessage(m, replyHandler: nil, errorHandler: nil)
    }

    /// Очередь камеры: каждый кадр с камеры предлагается сюда, не чаще раза в 0.8 с уходит на часы маленькой картинкой
    func offer(_ pb: CVPixelBuffer, portrait: Bool) {
        guard live, !busy else { return }
        let now = CACurrentMediaTime()
        guard now - lastShot > 0.8 else { return }
        lastShot = now
        busy = true
        q.async {
            defer { self.busy = false }
            var img = CIImage(cvPixelBuffer: pb)
            if portrait && img.extent.width > img.extent.height { img = img.oriented(.right) }
            let sc = 320 / max(img.extent.width, img.extent.height)
            img = img.transformed(by: CGAffineTransform(scaleX: sc, y: sc))
            guard let cg = self.ci.createCGImage(img, from: img.extent),
                  let d = UIImage(cgImage: cg).jpegData(compressionQuality: 0.5) else { return }
            WCSession.default.sendMessageData(d, replyHandler: nil, errorHandler: nil)
        }
    }

    // MARK: Команды с часов

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let cmd = message["cmd"] as? String else { return }
        DispatchQueue.main.async {
            guard let e = self.engine else { return }
            Diag.event("Часы: \(cmd)")
            switch cmd {
            case "shutter":
                switch e.phase {
                case .idle: if e.sceneKind == .photo { e.takePhoto() } else { e.start() }
                case .recording, .paused: e.stop()
                case .test, .waiting: e.cancel()
                case .saving: break
                }
            case "test":
                if e.phase == .idle { e.testFrame() }
            default:
                break
            }
            self.push()
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.push() }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
