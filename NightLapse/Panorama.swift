import SwiftUI
import AVFoundation
import CoreMotion
import Photos
import SceneKit
import UIKit

// MARK: - Хранилище панорам

enum PanoStore {
    static func root() -> URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Панорамы", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Полноразмерные кадры лежат в кеше: iOS может его очистить, итоговые панорамы остаются в «Файлах»
    static func cacheRoot() -> URL {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pano", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func newName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Pano_" + f.string(from: Date())
    }

    /// В отчёт: позы, журнал, малые копии кадров и превью последних двух панорам, результат самопроверки
    static func addToReport(into tmp: URL) {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: root(), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(2)
        for d in dirs {
            let td = tmp.appendingPathComponent(d.lastPathComponent, isDirectory: true)
            try? fm.createDirectory(at: td, withIntermediateDirectories: true)
            for f in ["poses.json", "log.txt", "preview_A.jpg", "preview_B.jpg"] {
                let u = d.appendingPathComponent(f)
                if fm.fileExists(atPath: u.path) { try? fm.copyItem(at: u, to: td.appendingPathComponent(f)) }
            }
            let small = d.appendingPathComponent("small", isDirectory: true)
            if fm.fileExists(atPath: small.path) { try? fm.copyItem(at: small, to: td.appendingPathComponent("small")) }
        }
        let st = root().appendingPathComponent("selftest.txt")
        if fm.fileExists(atPath: st.path) { try? fm.copyItem(at: st, to: tmp.appendingPathComponent("pano_selftest.txt")) }
    }
}

// MARK: - Датчики движения

final class PanoMotion {
    private let mm = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var ring: [(t: Double, R: [Double])] = []
    private var latest: [Double]?
    private var rate = 0.0
    private var err0 = 0.0, err1 = 0.0
    private var seen = 0

    init() { queue.maxConcurrentOperationCount = 1 }

    /// Как понимать матрицу: 0 - мир->устройство, 1 - обратная. Определяется по силе тяжести: она известна независимо
    var conv: Int {
        lock.lock(); defer { lock.unlock() }
        return err1 < err0 ? 1 : 0
    }

    var available: Bool { mm.isDeviceMotionAvailable }

    func start() {
        guard mm.isDeviceMotionAvailable else { return }
        mm.deviceMotionUpdateInterval = 1.0 / 50.0
        mm.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: queue) { [weak self] m, _ in
            guard let self = self, let m = m else { return }
            let r = m.attitude.rotationMatrix
            let R = [r.m11, r.m12, r.m13, r.m21, r.m22, r.m23, r.m31, r.m32, r.m33]
            let g = m.gravity
            let e0 = abs(g.x + R[2]) + abs(g.y + R[5]) + abs(g.z + R[8])
            let e1 = abs(g.x + R[6]) + abs(g.y + R[7]) + abs(g.z + R[8])
            let w = m.rotationRate
            self.lock.lock()
            self.err0 += e0
            self.err1 += e1
            self.seen += 1
            self.latest = R
            self.rate = sqrt(w.x * w.x + w.y * w.y + w.z * w.z)
            self.ring.append((m.timestamp, R))
            if self.ring.count > 200 { self.ring.removeFirst(self.ring.count - 200) }
            self.lock.unlock()
        }
    }

    func stop() { mm.stopDeviceMotionUpdates() }

    func current() -> (R: [Double], rate: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let l = latest else { return nil }
        return (l, rate)
    }

    /// Поза в момент времени t (часы устройства); если нет близкой - последняя
    func pose(at t: Double) -> [Double]? {
        lock.lock(); defer { lock.unlock() }
        var best: (Double, [Double])?
        for s in ring {
            let d = abs(s.t - t)
            if best == nil || d < best!.0 { best = (d, s.R) }
        }
        if let b = best, b.0 < 0.4 { return b.1 }
        return latest
    }
}

// MARK: - Сеанс съёмки панорамы

final class PanoSession: ObservableObject {
    enum Stage { case intro, shooting, stitching, result }

    @Published var stage: Stage = .intro
    @Published var ready = false
    @Published var done: Set<Int> = []
    @Published var current: Int?
    @Published var M: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1] // мир->устройство
    @Published var message = ""
    @Published var progress = 0.0
    @Published var progressText = ""
    @Published var result: PanoStitcher.Result?
    @Published var resultURLs: (a: URL?, b: URL?) = (nil, nil)
    @Published var fovDeg = 0.0

    var targets: [(yaw: Double, pitch: Double)] = []
    private var heading0 = 0.0
    private let motion = PanoMotion()
    private weak var engine: LapseEngine?
    private var timer: Timer?
    private var busy = false
    private var stableSince: Date?
    private var poses: [PanoPose] = []
    private var shotTargets: [Int] = []
    private var name = ""
    private var dir = URL(fileURLWithPath: "/")
    private var cacheDir = URL(fileURLWithPath: "/")
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    func attach(_ e: LapseEngine) {
        engine = e
        UIApplication.shared.isIdleTimerDisabled = true
        motion.start()
        e.panoPrepare { [weak self] fov, ok in
            guard let self = self else { return }
            self.fovDeg = fov
            self.ready = ok && self.motion.available
            if !self.motion.available { self.message = "Нет датчиков движения" }
            if !ok { self.message = "Камера недоступна" }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        motion.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        engine?.panoEnd()
        engine?.panoActive = false
    }

    private var convNow: Int { motion.conv }

    private func worldM(_ R: [Double]) -> [Double] { PanoMath.world2dev(R, conv: convNow) }

    func start() {
        guard ready, let cur = motion.current() else { return }
        let m = worldM(cur.R)
        let f = PanoMath.forward(m)
        // Курс начала: куда смотрит камера, а если вверх или вниз - куда смотрит верх телефона
        if hypot(f[0], f[1]) > 0.5 {
            heading0 = atan2(f[0], f[1])
        } else {
            heading0 = atan2(m[3], m[4])
        }
        targets = PanoMath.targets(fovLong: fovDeg * Double.pi / 180)
        done = []
        poses = []
        shotTargets = []
        name = PanoStore.newName()
        dir = PanoStore.root().appendingPathComponent(name, isDirectory: true)
        cacheDir = PanoStore.cacheRoot().appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir.appendingPathComponent("small"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        stage = .shooting
        message = ""
        Haptic.heavy()
    }

    private func dirOf(_ t: (yaw: Double, pitch: Double)) -> [Double] {
        let y = t.yaw + heading0
        return [cos(t.pitch) * sin(y), cos(t.pitch) * cos(y), sin(t.pitch)]
    }

    /// Что искать на экране: направление цели в осях устройства
    func targetVector(_ i: Int) -> [Double] {
        let d = dirOf(targets[i])
        return [M[0] * d[0] + M[1] * d[1] + M[2] * d[2],
                M[3] * d[0] + M[4] * d[1] + M[5] * d[2],
                M[6] * d[0] + M[7] * d[1] + M[8] * d[2]]
    }

    var forwardWorld: [Double] { PanoMath.forward(M) }
    var headingRel: Double { atan2(forwardWorld[0], forwardWorld[1]) - heading0 }
    func targetYawPitch(_ i: Int) -> (Double, Double) { (targets[i].yaw, targets[i].pitch) }

    private func tick() {
        guard let cur = motion.current() else { return }
        M = worldM(cur.R)
        guard stage == .shooting, !busy, !targets.isEmpty else { return }
        let f = PanoMath.forward(M)
        // Ближайшая нетронутая цель
        var best: (Int, Double)?
        for i in 0..<targets.count where !done.contains(i) {
            let a = PanoMath.angle(f, dirOf(targets[i]))
            if best == nil || a < best!.1 { best = (i, a) }
        }
        guard let b = best else { return }
        current = b.0
        let tol = 4.0 * Double.pi / 180
        var rollOK = true
        if abs(targets[b.0].pitch) < 1.3 {
            // Верх телефона смотрит вверх
            let up = [M[3], M[4], M[5]]
            let z = [0.0, 0.0, 1.0]
            let dot = f[0] * z[0] + f[1] * z[1] + f[2] * z[2]
            var e = [z[0] - dot * f[0], z[1] - dot * f[1], z[2] - dot * f[2]]
            let n = sqrt(e[0] * e[0] + e[1] * e[1] + e[2] * e[2])
            if n > 0.2 {
                e = e.map { $0 / n }
                rollOK = PanoMath.angle(up, e) < 12 * Double.pi / 180
            }
        }
        if b.1 < tol && cur.rate < 0.3 && rollOK {
            if stableSince == nil { stableSince = Date() }
            if Date().timeIntervalSince(stableSince!) > 0.3 { shoot(b.0) }
        } else {
            stableSince = nil
        }
    }

    func shootNow() {
        guard stage == .shooting, !busy, let c = current else { return }
        shoot(c)
    }

    private func shoot(_ idx: Int) {
        guard let e = engine, !busy else { return }
        busy = true
        stableSince = nil
        e.panoCapture { [weak self] data, t in
            guard let self = self else { return }
            guard let data = data else {
                self.busy = false
                self.message = "Кадр не вышел, держу дальше"
                return
            }
            let R = self.motion.pose(at: t) ?? self.motion.current()?.R ?? [1, 0, 0, 0, 1, 0, 0, 0, 1]
            let n = self.poses.count
            let url = self.cacheDir.appendingPathComponent(String(format: "shot_%02d.jpg", n))
            let smallURL = self.dir.appendingPathComponent("small").appendingPathComponent(String(format: "shot_%02d.jpg", n))
            try? data.write(to: url)
            if let cg = ShootStore.thumb(url, maxPixel: 1000), let d = ShootStore.jpeg(cg) { try? d.write(to: smallURL) }
            self.poses.append(PanoPose(file: url, R: R))
            self.shotTargets.append(idx)
            self.done.insert(idx)
            self.message = ""
            Haptic.tap()
            self.busy = false
            if self.done.count >= self.targets.count { self.finish() }
        }
    }

    func finish() {
        guard stage == .shooting, poses.count >= 3 else {
            message = "Нужно хотя бы 3 кадра"
            return
        }
        stage = .stitching
        progress = 0
        progressText = "Начинаю склейку"
        timer?.invalidate()
        timer = nil
        motion.stop()
        engine?.panoEnd()
        let conv = motion.conv
        let fov = fovDeg
        let ps = poses
        let tg = shotTargets
        let d = dir
        let nm = name
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "PanoStitch") { [weak self] in
            if let t = self?.bgTask { UIApplication.shared.endBackgroundTask(t) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // Позы и параметры - сначала на диск: если склейку прервут, данные для разбора останутся
            self.writePoses(ps, targets: tg, dir: d, conv: conv, fov: fov)
            let st = PanoStitcher(poses: ps, fovLongDegrees: fov)
            st.liveConv = conv
            st.progress = { text, p in
                DispatchQueue.main.async { self.progressText = text; self.progress = p }
            }
            let res = st.runAll()
            var urlA: URL?, urlB: URL?
            if let a = res.jpegA {
                let u = d.appendingPathComponent("pano_A_\(nm).jpg")
                try? a.write(to: u)
                urlA = u
            }
            if let b = res.jpegB {
                let u = d.appendingPathComponent("pano_B_\(nm).jpg")
                try? b.write(to: u)
                urlB = u
            }
            if let p = res.previewA { try? p.write(to: d.appendingPathComponent("preview_A.jpg")) }
            if let p = res.previewB { try? p.write(to: d.appendingPathComponent("preview_B.jpg")) }
            try? res.log.write(to: d.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
            Diag.event("Панорама \(nm): \(ps.count) кадров. " + res.log.replacingOccurrences(of: "\n", with: " | "))
            for u in [urlA, urlB].compactMap({ $0 }) {
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: u)
                }, completionHandler: { _, _ in })
            }
            DispatchQueue.main.async {
                self.result = res
                self.resultURLs = (urlA, urlB)
                self.stage = .result
                Haptic.success()
                UIApplication.shared.isIdleTimerDisabled = false
                if self.bgTask != .invalid { UIApplication.shared.endBackgroundTask(self.bgTask); self.bgTask = .invalid }
            }
        }
    }

    private func writePoses(_ ps: [PanoPose], targets tg: [Int], dir d: URL, conv: Int, fov: Double) {
        var shots: [[String: Any]] = []
        for (k, p) in ps.enumerated() {
            shots.append(["file": p.file.lastPathComponent, "R": p.R, "target": tg[k],
                          "yaw": self.targets[tg[k]].yaw, "pitch": self.targets[tg[k]].pitch])
        }
        let info: [String: Any] = ["fovLongDeg": fov, "liveConv": conv, "heading0": heading0, "shots": shots,
                                   "count": ps.count, "targets": targets.count,
                                   "memoryGB": Double(ProcessInfo.processInfo.physicalMemory) / 1e9]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]) {
            try? data.write(to: d.appendingPathComponent("poses.json"))
        }
    }
}

// MARK: - Экран панорамы

struct PanoOverlay: View {
    @ObservedObject var e: LapseEngine
    @StateObject private var s = PanoSession()
    @State private var viewing: URL?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear.contentShape(Rectangle()).onTapGesture {}
                switch s.stage {
                case .intro: intro
                case .shooting: shooting(geo.size)
                case .stitching: stitching
                case .result: resultView
                }
            }
        }
        .onAppear { s.attach(e) }
        .fullScreenCover(item: Binding(get: { viewing.map { PanoURL(url: $0) } }, set: { viewing = $0?.url })) { item in
            PanoViewerScreen(url: item.url) { viewing = nil }
        }
    }

    private var intro: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "pano")
                .font(.system(size: 44, weight: .light))
            Text("Панорама 360°")
                .font(.title2.weight(.semibold))
            Text("Держи телефон вертикально и вращайся на месте, лучше вокруг камеры телефона. Ориентируйся по кружку: он показывает, куда повернуть. Снимок делается сам, когда кружок в центре и ты держишь ровно. Свет и баланс белого фиксируются, пока идёт съёмка. Лучше 1x или 0.5x.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
            if !s.message.isEmpty { Text(s.message).foregroundStyle(.orange) }
            Button {
                s.start()
            } label: {
                Text(s.ready ? "Начать" : "Готовлю камеру...")
                    .font(.headline)
                    .frame(maxWidth: 260)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(s.ready ? Color.white : Color.gray.opacity(0.4)))
                    .foregroundStyle(.black)
            }
            .disabled(!s.ready)
            Button("Отмена") { s.close() }
                .foregroundStyle(.secondary)
            Spacer()
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.78))
    }

    private func shooting(_ size: CGSize) -> some View {
        ZStack {
            // Прицел в центре
            Circle().stroke(Color.white.opacity(0.9), lineWidth: 2).frame(width: 34, height: 34)
            Circle().fill(Color.white).frame(width: 4, height: 4)
            // Цель
            if let c = s.current, c < s.targets.count {
                marker(for: c, size: size)
            }
            VStack {
                HStack {
                    Button { s.close() } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                            .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    Text("\(s.done.count) из \(s.targets.count)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 12).frame(height: 34)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
                if !s.message.isEmpty { Text(s.message).font(.footnote).padding(8).background(.ultraThinMaterial, in: Capsule()) }
                minimap
                    .frame(width: 240, height: 120)
                    .padding(.bottom, 8)
                HStack(spacing: 14) {
                    Button { s.shootNow() } label: {
                        Text("Снять сейчас").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18).frame(height: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Button { s.finish() } label: {
                        Text("Готово").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 22).frame(height: 44)
                            .background(Capsule().fill(s.done.count >= 3 ? Color.white : Color.gray.opacity(0.4)))
                            .foregroundStyle(.black)
                    }
                    .disabled(s.done.count < 3)
                }
                .padding(.bottom, 24)
            }
        }
        .foregroundStyle(.white)
    }

    /// Маркер цели: на месте, если цель в кадре, иначе у края со стрелкой в её сторону
    private func marker(for i: Int, size: CGSize) -> some View {
        let v = s.targetVector(i)
        let f = -v[2]
        let fovL = max(s.fovDeg, 30) * Double.pi / 180
        let scale = (size.height / 2) / CGFloat(tan(fovL / 2))
        let cx = size.width / 2, cy = size.height / 2
        var p = CGPoint(x: cx, y: cy)
        var inView = false
        if f > 0.05 {
            let x = cx + CGFloat(v[0] / f) * scale
            let y = cy - CGFloat(v[1] / f) * scale
            if x > 24 && x < size.width - 24 && y > 90 && y < size.height - 200 {
                p = CGPoint(x: x, y: y)
                inView = true
            }
        }
        let ang = atan2(-v[1], v[0]) // экранный угол: вправо 0, вниз положительный
        if !inView {
            let r = min(size.width, size.height) * 0.38
            p = CGPoint(x: cx + CGFloat(cos(ang)) * r, y: cy + CGFloat(sin(ang)) * r)
        }
        return ZStack {
            Circle().stroke(Color.orange, lineWidth: 3).frame(width: inView ? 54 : 40, height: inView ? 54 : 40)
            if !inView {
                Image(systemName: "arrow.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.orange)
                    .rotationEffect(.radians(ang))
            }
        }
        .position(p)
    }

    private var minimap: some View {
        Canvas { ctx, size in
            ctx.stroke(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.6)), lineWidth: 1)
            func pt(_ yaw: Double, _ pitch: Double) -> CGPoint {
                var y = yaw.truncatingRemainder(dividingBy: 2 * Double.pi)
                if y < 0 { y += 2 * Double.pi }
                return CGPoint(x: y / (2 * Double.pi) * size.width, y: (0.5 - pitch / Double.pi) * size.height)
            }
            for (i, t) in s.targets.enumerated() {
                let c = pt(t.yaw, t.pitch)
                let col: Color = s.done.contains(i) ? .green : (i == s.current ? .orange : .white.opacity(0.5))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(col))
            }
            let f = s.forwardWorld
            let c = pt(s.headingRel, asin(max(-1, min(1, f[2]))))
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)), with: .color(.white), lineWidth: 2)
        }
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    private var stitching: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView(value: s.progress).frame(width: 240)
            Text(s.progressText).font(.callout.monospacedDigit())
            Text("Идёт склейка двух вариантов. Не закрывай приложение.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.88))
    }

    private var resultView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Готово").font(.title3.weight(.semibold)).padding(.top, 40)
                if let r = s.result {
                    card("A - быстрый набросок", String(format: "%.0f с", r.secondsA), r.previewA, s.resultURLs.a)
                    card("B - чистовая склейка", String(format: "%.0f с", r.secondsB), r.previewB, s.resultURLs.b)
                    Text("Оба файла сохранены в Фото и в Файлы → NightLapse → Панорамы. Посмотри 360° и скажи, какой вариант чище.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
                    DisclosureGroup("Подробности склейки") {
                        Text(r.log).font(.caption2.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                }
                Button { s.close() } label: {
                    Text("Закрыть").font(.headline).frame(maxWidth: 260).padding(.vertical, 14)
                        .background(Capsule().fill(Color.white)).foregroundStyle(.black)
                }
                .padding(.bottom, 40)
            }
        }
        .foregroundStyle(.white)
        .background(Color.black)
    }

    private func card(_ title: String, _ time: String, _ preview: Data?, _ url: URL?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let p = preview, let img = UIImage(data: p) {
                Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 12) {
                if let u = url {
                    Button { viewing = u } label: {
                        Label("Смотреть 360°", systemImage: "view.3d").font(.footnote.weight(.semibold))
                    }
                    ShareLink(item: u) { Label("Отправить", systemImage: "square.and.arrow.up").font(.footnote.weight(.semibold)) }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }
}

struct PanoURL: Identifiable {
    let url: URL
    var id: String { url.path }
}

// MARK: - Просмотр сферы

struct PanoSphereView: UIViewRepresentable {
    let url: URL

    final class Coordinator: NSObject {
        var yaw: Float = 0
        var pitch: Float = 0
        var fov: CGFloat = 80
        weak var cam: SCNNode?
        weak var view: SCNView?
        @objc func pan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            let k = Float(fov) / 600
            yaw += Float(t.x) * k * Float.pi / 180
            pitch = max(-1.5, min(1.5, pitch + Float(t.y) * k * Float.pi / 180))
            apply()
        }
        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            fov = max(30, min(110, fov / g.scale))
            g.scale = 1
            cam?.camera?.fieldOfView = fov
        }
        func apply() { cam?.eulerAngles = SCNVector3(pitch, yaw, 0) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor = .black
        let scene = SCNScene()
        let sphere = SCNSphere(radius: 10)
        let m = SCNMaterial()
        if let d = try? Data(contentsOf: url), let img = UIImage(data: d) { m.diffuse.contents = img }
        m.isDoubleSided = true
        m.cullMode = .front
        // Смотрим на сферу изнутри: картинку отражаем по горизонтали, чтобы она не оказалась зеркальной
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(-1, 1, 1)
        m.diffuse.wrapS = .repeat
        sphere.materials = [m]
        let node = SCNNode(geometry: sphere)
        scene.rootNode.addChildNode(node)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 80
        cam.camera?.zNear = 0.1
        scene.rootNode.addChildNode(cam)
        v.scene = scene
        v.pointOfView = cam
        context.coordinator.cam = cam
        context.coordinator.view = v
        v.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:))))
        v.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:))))
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

struct PanoViewerScreen: View {
    let url: URL
    let close: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            PanoSphereView(url: url).ignoresSafeArea()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
            }
            .foregroundStyle(.white)
            .padding(16)
        }
    }
}

// MARK: - Самопроверка склейки без камеры

enum PanoSelfTest {
    private struct Rng {
        var s: UInt64
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double((s >> 33) & 0xFFFFFF) / Double(0x1000000)
        }
        mutating func gauss() -> Double {
            let u = max(next(), 1e-9), v = next()
            return sqrt(-2 * log(u)) * cos(2 * Double.pi * v)
        }
    }

    /// Туман из случайных сеток разного масштаба: что-то среднее между небом, землёй и мелкими деталями
    private static func texture(_ W: Int, _ H: Int, _ rng: inout Rng) -> [Float] {
        var out = [Float](repeating: 0, count: W * H * 3)
        for (cell, amp) in [(256, 70.0), (64, 45.0), (16, 25.0), (8, 12.0)] {
            let gw = W / cell + 2, gh = H / cell + 2
            var grid = [Float](repeating: 0, count: gw * gh * 3)
            for i in 0..<grid.count { grid[i] = Float(rng.next() * amp) }
            for y in 0..<H {
                let fy = Float(y) / Float(cell)
                let y0 = Int(fy), ty = fy - Float(y0)
                for x in 0..<W {
                    let fx = Float(x) / Float(cell)
                    let x0 = Int(fx), tx = fx - Float(x0)
                    for ch in 0..<3 {
                        let a = grid[(y0 * gw + x0) * 3 + ch], b = grid[(y0 * gw + x0 + 1) * 3 + ch]
                        let c = grid[((y0 + 1) * gw + x0) * 3 + ch], d = grid[((y0 + 1) * gw + x0 + 1) * 3 + ch]
                        out[(y * W + x) * 3 + ch] += (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
                    }
                }
            }
        }
        let mx = max(out.max() ?? 1, 1)
        for i in 0..<out.count { out[i] = out[i] / mx * 255 }
        return out
    }

    private static func lookR(yaw: Double, pitch: Double, roll: Double) -> [Double] {
        let f = [cos(pitch) * sin(yaw), cos(pitch) * cos(yaw), sin(pitch)]
        var r = [f[1] * 1 - f[2] * 0, f[2] * 0 - f[0] * 1, 0.0] // f x up(0,0,1)
        let n = sqrt(r[0] * r[0] + r[1] * r[1])
        if n < 1e-6 { r = [cos(yaw), -sin(yaw), 0] } else { r = [r[0] / n, r[1] / n, 0] }
        // u = r x f
        let u = [r[1] * f[2] - r[2] * f[1], r[2] * f[0] - r[0] * f[2], r[0] * f[1] - r[1] * f[0]]
        let c = cos(roll), s = sin(roll)
        let r2 = [c * r[0] + s * u[0], c * r[1] + s * u[1], c * r[2] + s * u[2]]
        let u2 = [-s * r[0] + c * u[0], -s * r[1] + c * u[1], -s * r[2] + c * u[2]]
        return [r2[0], r2[1], r2[2], u2[0], u2[1], u2[2], -f[0], -f[1], -f[2]]
    }

    static func run(progress: @escaping (String) -> Void) -> String {
        var rng = Rng(s: 12345)
        let GW = 2048, GH = 1024
        progress("Рисую тестовую сцену")
        let gt = texture(GW, GH, &rng)
        let nominal = 69.0
        let trueScale = 1.03
        let fovTrue = nominal * trueScale * Double.pi / 180
        let fw = 480, fh = 640
        var report = "Самопроверка склейки панорамы\n"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pano_selftest", isDirectory: true)
        for transposed in [false, true] {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            progress("Снимаю виртуальные кадры (\(transposed ? "обратная поза" : "прямая поза"))")
            let targets = PanoMath.targets(fovLong: nominal * Double.pi / 180)
            var poses: [PanoPose] = []
            let fpix = (Double(fh) / 2) / tan(fovTrue / 2)
            for (k, t) in targets.enumerated() {
                let Rt = lookR(yaw: t.yaw + rng.gauss() * 0.001, pitch: t.pitch, roll: rng.gauss() * 0.0005)
                var px = [UInt8](repeating: 255, count: fw * fh * 4)
                for y in 0..<fh {
                    for x in 0..<fw {
                        let vx = (Double(x) + 0.5 - Double(fw) / 2) / fpix
                        let vy = -(Double(y) + 0.5 - Double(fh) / 2) / fpix
                        let vz = -1.0
                        // d = R^T v
                        var d = [Rt[0] * vx + Rt[3] * vy + Rt[6] * vz,
                                 Rt[1] * vx + Rt[4] * vy + Rt[7] * vz,
                                 Rt[2] * vx + Rt[5] * vy + Rt[8] * vz]
                        let n = sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
                        d = d.map { $0 / n }
                        let lam = atan2(d[0], d[1]), phi = asin(max(-1, min(1, d[2])))
                        var gx = (lam + Double.pi) / (2 * Double.pi) * Double(GW) - 0.5
                        let gy = (Double.pi / 2 - phi) / Double.pi * Double(GH) - 0.5
                        if gx < 0 { gx += Double(GW) }
                        let x0 = Int(gx) % GW, x1 = (x0 + 1) % GW
                        let y0 = min(max(Int(gy), 0), GH - 1), y1 = min(y0 + 1, GH - 1)
                        let tx = Float(gx - floor(gx)), ty = Float(max(0, gy) - floor(max(0, gy)))
                        for ch in 0..<3 {
                            let a = gt[(y0 * GW + x0) * 3 + ch], b = gt[(y0 * GW + x1) * 3 + ch]
                            let c = gt[(y1 * GW + x0) * 3 + ch], dd = gt[(y1 * GW + x1) * 3 + ch]
                            let v = (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + dd * tx) * ty
                            px[(y * fw + x) * 4 + ch] = UInt8(max(0, min(255, v + 0.5)))
                        }
                    }
                }
                let url = tmp.appendingPathComponent(String(format: "s_%02d.jpg", k))
                if let cg = PanoIO.cgImage(rgba: px, w: fw, h: fh), let jd = PanoIO.jpeg(cg, quality: 0.92) { try? jd.write(to: url) }
                // Ошибка датчиков: курс плывёт на ~0.5 градуса, наклон чуть шумит
                let a = rng.gauss() * 0.5 * Double.pi / 180
                let Rz = PanoMath.rotZ(a)
                var Rm = PanoMath.mul(Rt, Rz)
                if transposed { Rm = PanoMath.transpose(Rm) }
                poses.append(PanoPose(file: url, R: Rm))
            }
            progress("Склеиваю")
            let st = PanoStitcher(poses: poses, fovLongDegrees: nominal)
            st.outputWidth = 2048
            st.progress = { text, _ in progress(text) }
            let t0 = Date()
            guard st.prepare() else { report += "Не удалось прочитать кадры\n"; continue }
            let tPrep = Date().timeIntervalSince(t0)
            let tA0 = Date()
            let a = st.runA()
            let tA = Date().timeIntervalSince(tA0)
            let tB0 = Date()
            let b = st.runB()
            let tB = Date().timeIntervalSince(tB0)
            func rmse(_ img: (rgba: [UInt8], w: Int, h: Int)?) -> Double {
                guard let img = img, img.w == GW, img.h == GH else { return -1 }
                // Курс первого кадра сдвигает панораму по горизонтали
                let s0 = Int((-st.yaw0 / (2 * Double.pi) * Double(GW)).rounded())
                var best = Double.greatestFiniteMagnitude
                for sh in (s0 - 3)...(s0 + 3) {
                    var sum = 0.0
                    var c = 0
                    for y in stride(from: GH * 15 / 100, to: GH * 85 / 100, by: 2) {
                        for x in stride(from: 0, to: GW, by: 2) {
                            var gx = x - sh
                            gx = ((gx % GW) + GW) % GW
                            for ch in 0..<3 {
                                let d = Double(img.rgba[(y * GW + x) * 4 + ch]) - Double(gt[(y * GW + gx) * 3 + ch])
                                sum += d * d
                                c += 1
                            }
                        }
                    }
                    best = min(best, sqrt(sum / Double(c)))
                }
                return best
            }
            let ra = rmse(a), rb = rmse(b)
            report += String(format: "\nПоза в тесте: %@. Выбрано: поза %d (ожидалась %d), масштаб %.3f (ожидался %.3f)\n",
                             transposed ? "обратная" : "прямая", st.conv, transposed ? 1 : 0, st.scale, trueScale)
            report += String(format: "Подготовка %.1f с, A: %.1f с, ошибка %.2f, B: %.1f с, ошибка %.2f (меньше - лучше)\n", tPrep, tA, ra, tB, rb)
            report += st.log
        }
        try? FileManager.default.removeItem(at: tmp)
        return report
    }
}
