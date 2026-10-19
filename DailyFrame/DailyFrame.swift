// DailyFrame (Кадр дня) - один и тот же вид каждый день.
// На экране виден прозрачный прошлый кадр (призрак или контур), датчики показывают совпадение положения телефона,
// при сборке видео кадры выравниваются автоматически.

import SwiftUI
import UIKit
import AVFoundation
import CoreMotion
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Photos
import Vision
import UserNotifications
import PhotosUI


// MARK: - Типы

enum Lens: String, CaseIterable, Identifiable {
    case ultraWide, wide, tele
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ultraWide: return "0.5x"
        case .wide: return "1x"
        case .tele: return "Теле"
        }
    }
    var type: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide: return .builtInWideAngleCamera
        case .tele: return .builtInTelephotoCamera
        }
    }
}

enum OverlayMode: String, CaseIterable, Identifiable {
    case off, ghost, edges
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Выкл"
        case .ghost: return "Призрак"
        case .edges: return "Контур"
        }
    }
}

enum TargetMode: String, CaseIterable, Identifiable {
    case previous, first, gallery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .previous: return "Предыдущий"
        case .first: return "Эталон"
        case .gallery: return "Из галереи"
        }
    }
}

/// Положение телефона в момент съёмки
struct Shot: Codable {
    var q: [Double]
    var g: [Double]
    var lens: String
}

struct ProjectMeta: Codable {
    var ref: String?
    var shots: [String: Shot] = [:]
}

struct Photo: Identifiable, Hashable {
    let name: String
    let url: URL
    var id: String { name }
    var date: Date? { Photo.parse(name) }

    static let nameFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    static func parse(_ n: String) -> Date? {
        nameFmt.date(from: (n as NSString).deletingPathExtension)
    }
}

// MARK: - Математика совпадения положения

/// Полный угол между двумя ориентациями телефона (кватернионы), в градусах
func qAngle(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == 4, b.count == 4 else { return 0 }
    let d = abs(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3])
    return 2 * acos(min(1, d)) * 180 / .pi
}

/// Угол между направлениями силы тяжести (то есть наклон), в градусах
func gAngle(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == 3, b.count == 3 else { return 0 }
    let d = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    let n = sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]) * sqrt(b[0] * b[0] + b[1] * b[1] + b[2] * b[2])
    return acos(min(1, max(-1, d / max(n, 1e-9)))) * 180 / .pi
}

// MARK: - Миниатюры и накладки

enum Thumb {
    static func make(_ url: URL, maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

enum OverlayMaker {
    static let ci = CIContext()

    static func ghost(_ url: URL) -> UIImage? {
        Thumb.make(url, maxPixel: 1600)
    }

    /// Красные линии контуров на прозрачном фоне
    static func edges(_ url: URL) -> UIImage? {
        guard let base = Thumb.make(url, maxPixel: 1400), let cg = base.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input
        blur.radius = 1.5
        let edge = CIFilter.edges()
        edge.inputImage = blur.outputImage?.cropped(to: input.extent)
        edge.intensity = 6
        let cm = CIFilter.colorMatrix()
        cm.inputImage = edge.outputImage
        cm.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        cm.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        cm.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        cm.aVector = CIVector(x: 0.7, y: 0.7, z: 0.7, w: 0)
        cm.biasVector = CIVector(x: 1, y: 0.25, z: 0.1, w: 0)
        guard let out = cm.outputImage, let res = ci.createCGImage(out, from: input.extent) else { return nil }
        return UIImage(cgImage: res)
    }
}

// MARK: - Хранилище проектов и кадров

final class Store: ObservableObject {
    @Published var projects: [String] = []
    @Published var current: String {
        didSet {
            UserDefaults.standard.set(current, forKey: "project")
            reload()
        }
    }
    @Published var photos: [Photo] = []
    @Published var meta = ProjectMeta()
    /// Меняется, когда выбрано новое фото-призрак из галереи
    @Published var ghostVersion = 0

    private let root: URL

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DailyFrame", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        current = UserDefaults.standard.string(forKey: "project") ?? "Мой кадр"
        refreshProjects()
        if !projects.contains(current) { createProject(current) }
        reload()
    }

    var dir: URL { root.appendingPathComponent(current, isDirectory: true) }

    var refPhoto: Photo? { photos.first { $0.name == meta.ref } ?? photos.first }

    /// Фото из галереи, которое показывается призраком (своё у каждого проекта)
    var ghostURL: URL { dir.appendingPathComponent("ghost.img") }
    var hasGhost: Bool { FileManager.default.fileExists(atPath: ghostURL.path) }

    /// Фото из галереи сохраняется уже повёрнутым правильно (по метке ориентации), до 2400 px
    func setGhost(_ data: Data) -> Bool {
        guard let img = UIImage(data: data), let out = Store.upright(img, maxSide: 2400, turns: 0),
              let jpg = out.jpegData(compressionQuality: 0.9) else { return false }
        do { try jpg.write(to: ghostURL) } catch { return false }
        ghostVersion += 1
        return true
    }

    /// Повернуть фото-призрак на 90° по часовой
    func rotateGhost() {
        guard let img = UIImage(contentsOfFile: ghostURL.path), let out = Store.upright(img, maxSide: 2400, turns: 1),
              let jpg = out.jpegData(compressionQuality: 0.9) else { return }
        try? jpg.write(to: ghostURL)
        ghostVersion += 1
    }

    static func upright(_ img: UIImage, maxSide: CGFloat, turns: Int) -> UIImage? {
        let w = img.size.width, h = img.size.height
        guard w > 0, h > 0 else { return nil }
        let k = min(1, maxSide / max(w, h))
        let sw = (w * k).rounded(), sh = (h * k).rounded()
        let odd = turns % 2 == 1
        let size = odd ? CGSize(width: sh, height: sw) : CGSize(width: sw, height: sh)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: size.width / 2, y: size.height / 2)
            c.rotate(by: CGFloat(turns) * .pi / 2)
            img.draw(in: CGRect(x: -sw / 2, y: -sh / 2, width: sw, height: sh))
        }
    }

    func removeGhost() {
        try? FileManager.default.removeItem(at: ghostURL)
        ghostVersion += 1
    }

    func target(_ mode: TargetMode) -> Photo? {
        mode == .previous ? photos.last : refPhoto
    }

    func refreshProjects() {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        projects = items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .sorted()
    }

    func createProject(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { return }
        try? FileManager.default.createDirectory(at: root.appendingPathComponent(clean, isDirectory: true),
                                                 withIntermediateDirectories: true)
        refreshProjects()
        current = clean
    }

    func reload() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        photos = files
            .filter { ["heic", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .map { Photo(name: $0.lastPathComponent, url: $0) }
            .sorted { $0.name < $1.name }
        if let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
           let m = try? JSONDecoder().decode(ProjectMeta.self, from: d) {
            meta = m
        } else {
            meta = ProjectMeta()
        }
    }

    private func saveMeta() {
        if let d = try? JSONEncoder().encode(meta) {
            try? d.write(to: dir.appendingPathComponent("meta.json"))
        }
    }

    func addPhoto(data: Data, ext: String, shot: Shot, date: Date = Date()) -> Photo? {
        // Имя файла - дата снимка; если такая секунда уже занята, сдвигаем на секунду
        var d = date
        var name = Photo.nameFmt.string(from: d) + "." + ext
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            d = d.addingTimeInterval(1)
            name = Photo.nameFmt.string(from: d) + "." + ext
        }
        let url = dir.appendingPathComponent(name)
        do { try data.write(to: url) } catch { return nil }
        meta.shots[name] = shot
        if meta.ref == nil { meta.ref = name }
        saveMeta()
        reload()
        return Photo(name: name, url: url)
    }

    /// Добавить снимки из галереи: дата берётся из самого снимка (EXIF), чтобы порядок кадров был верным
    func importImages(_ items: [(Data, String)]) -> Int {
        var n = 0
        for (data, ext) in items {
            var date = Date()
            if let src = CGImageSourceCreateWithData(data as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let str = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy:MM:dd HH:mm:ss"
                if let d = f.date(from: str) { date = d }
            }
            if addPhoto(data: data, ext: ext, shot: Shot(q: [], g: [], lens: "import"), date: date) != nil { n += 1 }
        }
        return n
    }

    func delete(_ p: Photo) {
        try? FileManager.default.removeItem(at: p.url)
        meta.shots[p.name] = nil
        if meta.ref == p.name { meta.ref = nil }
        saveMeta()
        reload()
        if meta.ref == nil, let first = photos.first {
            meta.ref = first.name
            saveMeta()
        }
    }

    func setRef(_ p: Photo) {
        meta.ref = p.name
        saveMeta()
    }
}

// MARK: - Камера

final class DailyCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let q = DispatchQueue(label: "dailyframe.camera")
    private var device: AVCaptureDevice?
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var rotObs: NSKeyValueObservation?
    private var capObs: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var ext = "heic"

    // Зум и фокус запоминаются между запусками
    @Published var zoom: Double = (UserDefaults.standard.object(forKey: "dfZoom") as? NSNumber)?.doubleValue ?? 1
    @Published var available: [ZoomOption] = []
    /// Превью стоит вертикально (телефон держишь вертикально)
    @Published var previewPortrait = true
    /// Где именно на экране лежит картинка камеры (в координатах окна просмотра)
    @Published var videoRect: CGRect = .zero
    @Published var infinityFocus = UserDefaults.standard.bool(forKey: "dfInfinity")
    @Published var busy = false

    var onPhoto: ((Data, String) -> Void)?

    func shutdown() {
        q.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func start() {
        available = ZoomOption.available()
        zoom = ZoomOption.pick(zoom, in: available).value
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { return }
            DispatchQueue.main.async { self.select(self.zoom) }
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }

    func select(_ v: Double) {
        let l = ZoomOption.pick(v, in: available)
        zoom = l.value
        UserDefaults.standard.set(l.value, forKey: "dfZoom")
        let inf = infinityFocus
        q.async {
            guard let dev = AVCaptureDevice.default(l.type, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: dev) else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            for old in self.session.inputs { self.session.removeInput(old) }
            if self.session.canAddInput(input) { self.session.addInput(input) }
            if !self.session.outputs.contains(self.photoOutput), self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }
            self.session.commitConfiguration()
            self.photoOutput.maxPhotoQualityPrioritization = .quality
            self.device = dev
            applyCrop(l.crop, to: dev)
            self.applyFocus(inf)
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.rebuildCoordinator() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.updateVideoRect() }
        }
    }

    /// Яркость, как солнце в Камере iPhone (EV, сбрасывается при запуске)
    @Published var bias: Float = 0

    /// Касание кадра: фокус и замер яркости в этой точке
    func focusTap(_ p: CGPoint) {
        if infinityFocus {
            infinityFocus = false
            UserDefaults.standard.set(false, forKey: "dfInfinity")
        }
        q.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            defer { dev.unlockForConfiguration() }
            if dev.isFocusPointOfInterestSupported { dev.focusPointOfInterest = p }
            if dev.isFocusModeSupported(.autoFocus) { dev.focusMode = .autoFocus }
            if dev.isExposurePointOfInterestSupported { dev.exposurePointOfInterest = p }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
        }
    }

    func nudgeBias(_ delta: Float) {
        bias = ((min(max(bias + delta, -2), 2)) * 10).rounded() / 10
        let b = bias
        q.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            defer { dev.unlockForConfiguration() }
            dev.setExposureTargetBias(min(max(b, dev.minExposureTargetBias), dev.maxExposureTargetBias), completionHandler: nil)
        }
    }

    func setInfinity(_ on: Bool) {
        infinityFocus = on
        UserDefaults.standard.set(on, forKey: "dfInfinity")
        q.async { self.applyFocus(on) }
    }

    private func applyFocus(_ infinity: Bool) {
        guard let dev = device, (try? dev.lockForConfiguration()) != nil else { return }
        defer { dev.unlockForConfiguration() }
        if infinity, dev.isLockingFocusWithCustomLensPositionSupported {
            dev.setFocusModeLocked(lensPosition: 1.0, completionHandler: nil)
        } else if dev.isFocusModeSupported(.continuousAutoFocus) {
            dev.focusMode = .continuousAutoFocus
        }
    }

    // Поворот картинки: превью и снимок всегда ровные по горизонту, как бы ни стоял телефон
    func attach(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        rebuildCoordinator()
    }

    private func rebuildCoordinator() {
        guard let dev = device, let layer = previewLayer else { return }
        let c = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: layer)
        coordinator = c
        applyPreviewAngle()
        rotObs = c.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyPreviewAngle() }
        }
        capObs = c.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyPreviewAngle() }
        }
    }

    private func applyPreviewAngle() {
        guard let c = coordinator, let conn = previewLayer?.connection else { return }
        let a = c.videoRotationAngleForHorizonLevelPreview
        if conn.isVideoRotationAngleSupported(a) { conn.videoRotationAngle = a }
        updateVideoRect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.updateVideoRect() }
    }

    /// Точный прямоугольник картинки камеры: по нему кладётся призрак, и по нему видно, вертикально ли держишь телефон
    func updateVideoRect() {
        guard let layer = previewLayer, layer.bounds.width > 0 else { return }
        let r = layer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1)).standardized
        guard r.width > 1, r.height > 1, r.width.isFinite, r.height.isFinite else { return }
        if abs(r.minX - videoRect.minX) > 0.5 || abs(r.minY - videoRect.minY) > 0.5
            || abs(r.width - videoRect.width) > 0.5 || abs(r.height - videoRect.height) > 0.5 {
            videoRect = r
        }
        let portrait = r.height > r.width
        if portrait != previewPortrait { previewPortrait = portrait }
    }

    func capture() {
        guard !busy else { return }
        busy = true
        let angle = coordinator?.videoRotationAngleForHorizonLevelCapture
        q.async {
            if let a = angle, let conn = self.photoOutput.connection(with: .video), conn.isVideoRotationAngleSupported(a) {
                conn.videoRotationAngle = a
            }
            let hevc = self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
            let s = hevc ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                         : AVCapturePhotoSettings()
            s.photoQualityPrioritization = .quality
            self.ext = hevc ? "heic" : "jpg"
            self.photoOutput.capturePhoto(with: s, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        let e = ext
        DispatchQueue.main.async {
            self.busy = false
            if error == nil, let d = data { self.onPhoto?(d, e) }
        }
    }
}

// MARK: - Датчики положения

final class Motion: ObservableObject {
    private let mm = CMMotionManager()
    @Published var q: [Double] = [0, 0, 0, 1]
    @Published var g: [Double] = [0, -1, 0]
    @Published var ok = false

    func stop() { mm.stopDeviceMotionUpdates() }

    func start() {
        guard mm.isDeviceMotionAvailable else { return }
        mm.deviceMotionUpdateInterval = 0.1
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame = frames.contains(.xMagneticNorthZVertical) ? .xMagneticNorthZVertical : .xArbitraryZVertical
        mm.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] m, _ in
            guard let self = self, let m = m else { return }
            let a = m.attitude.quaternion
            self.q = [a.x, a.y, a.z, a.w]
            self.g = [m.gravity.x, m.gravity.y, m.gravity.z]
            self.ok = true
        }
    }
}

// MARK: - Превью камеры

struct DFPreview: UIViewRepresentable {
    let cam: DailyCamera

    var onTap: (CGPoint, CGPoint) -> Void = { _, _ in }
    var onPan: (CGFloat) -> Void = { _ in }
    var onSwipe: (Int) -> Void = { _ in }

    final class PView: UIView {
        weak var cam: DailyCamera?
        var onTap: ((CGPoint, CGPoint) -> Void)?
        var onPan: ((CGFloat) -> Void)?
        var onSwipe: ((Int) -> Void)?
        private var lastY: CGFloat = 0
        private var axis = 0
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var pl: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.maximumNumberOfTouches = 1
            addGestureRecognizer(pan)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            let v = g.location(in: self)
            onTap?(pl.captureDevicePointConverted(fromLayerPoint: v), v)
        }

        @objc func panned(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: self)
            switch g.state {
            case .began:
                lastY = t.y
                axis = 0
            case .changed:
                // Направление решается по первым миллиметрам: вбок - смена режима, вверх-вниз - яркость
                if axis == 0 && hypot(t.x, t.y) > 14 { axis = abs(t.x) > abs(t.y) ? 2 : 1 }
                if axis == 1 { onPan?(t.y - lastY) }
                lastY = t.y
            case .ended:
                if axis == 2 && abs(t.x) > 50 { onSwipe?(t.x < 0 ? 1 : -1) }
                axis = 0
            default:
                axis = 0
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            DispatchQueue.main.async { [weak self] in self?.cam?.updateVideoRect() }
        }
    }

    func makeUIView(context: Context) -> PView {
        let v = PView()
        v.cam = cam
        v.onTap = onTap
        v.onPan = onPan
        v.onSwipe = onSwipe
        v.pl.session = cam.session
        v.pl.videoGravity = .resizeAspect
        v.backgroundColor = .black
        DispatchQueue.main.async { cam.attach(v.pl) }
        return v
    }

    func updateUIView(_ uiView: PView, context: Context) {
        uiView.onTap = onTap
        uiView.onPan = onPan
        uiView.onSwipe = onSwipe
    }
}

struct GridLines: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3
            let y = r.minY + r.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: r.minY))
            p.addLine(to: CGPoint(x: x, y: r.maxY))
            p.move(to: CGPoint(x: r.minX, y: y))
            p.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        return p
    }
}

// MARK: - Корневой экран

struct RootView: View {
    var onSwitch: () -> Void = {}
    /// Переход в найтлапс сразу на нужный режим
    var onScene: (LapseScene) -> Void = { _ in }
    @StateObject private var store = Store()
    @StateObject private var cam = DailyCamera()
    @StateObject private var motion = Motion()

    var body: some View {
        CameraView(cam: cam, motion: motion, onScene: onScene)
            .environmentObject(store)
            .onAppear {
                cam.start()
                motion.start()
            }
            .onDisappear {
                cam.shutdown()
                motion.stop()
            }
    }
}

// MARK: - Съёмка (тот же вид, что у найтлапса)

struct CameraView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var cam: DailyCamera
    @ObservedObject var motion: Motion
    var onScene: (LapseScene) -> Void = { _ in }

    @AppStorage("ovMode") private var mode: OverlayMode = .ghost
    @AppStorage("ovTarget") private var target: TargetMode = .previous
    @AppStorage("ovOpacity") private var opacity = 0.45
    @AppStorage("grid") private var grid = false
    @AppStorage("copyToPhotos") private var copyToPhotos = true
    @State private var overlayImage: UIImage?
    @State private var toast: String?
    @State private var pending: Shot?
    @State private var newProject = false
    @State private var newName = ""
    @State private var pickedItem: PhotosPickerItem?
    @State private var focusMark: CGPoint?
    @State private var markTick = 0
    @State private var ghostOpen = false
    @State private var showArchive = false
    @State private var lastThumb: UIImage?

    private var overlayKey: String {
        "\(store.current)|\(mode.rawValue)|\(target.rawValue)|\(store.photos.count)|\(store.meta.ref ?? "")|\(store.ghostVersion)"
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                // Видоискатель не пересоздаётся при повороте (см. CameraLayout)
                CameraLayout(landscape: landscape) {
                    topBar
                        .padding(.horizontal, landscape ? 8 : 16)
                        .padding(.bottom, landscape ? 0 : 6)
                    viewfinder
                    bottomControls
                        .padding(.top, landscape ? 0 : 8)
                        .padding(.horizontal, landscape ? 8 : 0)
                        .clipped()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            cam.onPhoto = { data, ext in handle(data, ext) }
        }
        .task(id: overlayKey) { await refreshOverlay() }
        .task(id: "\(store.current)|\(store.photos.count)") { await loadLastThumb() }
        .onChange(of: pickedItem) { loadPicked() }
        .sheet(isPresented: $showArchive) {
            ArchiveView().environmentObject(store)
        }
        .alert("Новый проект", isPresented: $newProject) {
            TextField("Название", text: $newName)
            Button("Создать") {
                store.createProject(newName)
                newName = ""
            }
            Button("Отмена", role: .cancel) { newName = "" }
        } message: {
            Text("Например: Вид из окна")
        }
    }

    // MARK: Верхняя полоса

    private var topBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(store.projects, id: \.self) { p in
                    Button(p) { store.current = p }
                }
                Divider()
                Button("Новый проект...") { newProject = true }
            } label: {
                Label(store.current, systemImage: "folder")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 0)
            roundToggle("grid", on: grid) { grid.toggle() }
            Button { cam.setInfinity(!cam.infinityFocus) } label: {
                Text("∞")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(cam.infinityFocus ? Color.yellow : Color.white)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
        }
        .padding(.top, 4)
    }

    private func roundToggle(_ icon: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 36)
                .foregroundStyle(on ? Color.yellow : Color.white)
                .background(Color.white.opacity(0.12), in: Circle())
        }
    }

    // MARK: Видоискатель

    private var viewfinder: some View {
        ZStack {
            DFPreview(cam: cam,
                      onTap: { dp, vp in
                          cam.focusTap(dp)
                          focusMark = vp
                          keepMark()
                      },
                      onPan: { dy in
                          cam.nudgeBias(Float(-dy) / 120)
                          keepMark()
                      },
                      onSwipe: { d in
                          // Кадр дня - первый режим: свайп влево ведёт в «Найтлапс»
                          if d > 0, let first = LapseScene.allCases.first { onScene(first) }
                      })
            // Призрак и сетка ложатся ровно на картинку камеры (кадр 4:3), фото другой формы обрезается по центру
            overlayLayer
            focusLayer
            VStack(spacing: 6) {
                hudView
                if mode != .off, let img = overlayImage,
                   (img.size.width > img.size.height) == cam.previewPortrait {
                    Text(img.size.width > img.size.height
                         ? "Прошлый кадр горизонтальный - поверни телефон"
                         : "Прошлый кадр вертикальный - поверни телефон")
                        .font(.footnote.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.85), in: Capsule())
                }
                if let t = toast {
                    Text(t)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.7), in: Capsule())
                }
                Spacer()
                zoomRow
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipped()
    }

    /// Кнопки зума, как в Камере
    private var zoomRow: some View {
        HStack(spacing: 6) {
            ForEach(cam.available) { z in
                let sel = abs(z.value - cam.zoom) < 0.01
                Button { cam.select(z.value) } label: {
                    Text(sel ? z.title : z.title.replacingOccurrences(of: "x", with: ""))
                        .font(.system(size: sel ? 13 : 12, weight: .bold))
                        .foregroundStyle(sel ? Color.yellow : Color.white)
                        .frame(width: sel ? 40 : 32, height: sel ? 40 : 32)
                        .background(Color.black.opacity(0.55), in: Circle())
                }
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.08), in: Capsule())
    }

    /// Жёлтая рамка фокуса и солнце яркости
    @ViewBuilder private var focusLayer: some View {
        if let m = focusMark {
            GeometryReader { _ in
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: 72, height: 72)
                        .position(m)
                    VStack(spacing: 2) {
                        Image(systemName: "sun.max.fill")
                        Text(String(format: "%+.1f", cam.bias)).font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(Color.yellow)
                    .position(x: m.x + 58, y: m.y)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func keepMark() {
        markTick += 1
        let t = markTick
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if markTick == t { focusMark = nil }
        }
    }

    /// Призрак и сетка ровно на месте картинки камеры
    private var overlayLayer: some View {
        GeometryReader { geo in
            let r = cam.videoRect.width > 1 ? cam.videoRect : fallbackRect(geo.size)
            ZStack {
                if mode != .off, let img = overlayImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: r.width, height: r.height)
                        .opacity(opacity)
                }
                if grid {
                    GridLines().stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                }
            }
            .frame(width: r.width, height: r.height)
            .clipped()
            .position(x: r.midX, y: r.midY)
        }
        .allowsHitTesting(false)
    }

    private func fallbackRect(_ size: CGSize) -> CGRect {
        let a: CGFloat = cam.previewPortrait ? 3.0 / 4.0 : 4.0 / 3.0
        var w = size.width, h = size.width / a
        if h > size.height { h = size.height; w = h * a }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Насколько положение телефона отличается от того, при котором снят выбранный кадр
    private var hud: (tilt: Double, head: Double)? {
        guard motion.ok, target != .gallery, let p = store.target(target), let s = store.meta.shots[p.name] else { return nil }
        let t = qAngle(motion.q, s.q)
        let g = gAngle(motion.g, s.g)
        return (g, sqrt(max(t * t - g * g, 0)))
    }

    @ViewBuilder private var hudView: some View {
        if let h = hud {
            HStack(spacing: 14) {
                Text("Наклон Δ \(String(format: "%.1f", h.tilt))°")
                    .foregroundStyle(hudColor(h.tilt, 0.5, 2))
                Text("Курс Δ \(String(format: "%.1f", h.head))°")
                    .foregroundStyle(hudColor(h.head, 1.5, 5))
            }
            .font(.footnote.monospacedDigit().weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.55), in: Capsule())
        }
    }

    private func hudColor(_ v: Double, _ good: Double, _ warn: Double) -> Color {
        v < good ? .green : (v < warn ? .yellow : .red)
    }

    // MARK: Низ: призрак, режимы, кнопка спуска

    private var bottomControls: some View {
        VStack(spacing: 10) {
            if ghostOpen { ghostEditor }
            HStack(spacing: 8) {
                chip(icon: "square.on.square.dashed", text: ghostTitle, on: ghostOpen) {
                    withAnimation(.easeOut(duration: 0.15)) { ghostOpen.toggle() }
                }
                Text("Кадров: \(store.photos.count)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            if store.photos.isEmpty {
                Text("Первый кадр станет эталоном. Потом на экране будет виден прошлый кадр - подгоняй телефон под него")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            ModeCarousel(selected: 0) { i in
                let all = LapseScene.allCases
                if i >= 1 && i - 1 < all.count { onScene(all[i - 1]) }
            }
            HStack {
                Button { showArchive = true } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1))
                        if let img = lastThumb {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            Image(systemName: "square.grid.3x3").foregroundStyle(Color.white)
                        }
                    }
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.4)))
                }
                Spacer()
                shutter
                Spacer()
                Button {
                    mode = mode == .off ? .ghost : .off
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: mode == .off ? "eye.slash" : "eye")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Призрак").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(mode == .off ? Color.white : Color.yellow)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.14), in: Circle())
                }
            }
            .padding(.horizontal, 28)
        }
        .padding(.bottom, 8)
    }

    private var ghostTitle: String {
        switch mode {
        case .off: return "Призрак выкл."
        case .edges: return "Контур \(Int(opacity * 100))%"
        default: return "Призрак \(Int(opacity * 100))%"
        }
    }

    private func chip(icon: String, text: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(text).monospacedDigit().lineLimit(1)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(on ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(on ? Color.yellow : Color.white.opacity(0.14), in: Capsule())
        }
    }

    private var ghostEditor: some View {
        VStack(spacing: 8) {
            Picker("Накладка", selection: $mode) {
                ForEach(OverlayMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if mode != .off {
                HStack {
                    Image(systemName: "circle.lefthalf.filled")
                    Slider(value: $opacity, in: 0.1...0.9).tint(.yellow)
                }
                Picker("Откуда", selection: $target) {
                    ForEach(TargetMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if target == .gallery {
                    HStack {
                        PhotosPicker(selection: $pickedItem, matching: .images) {
                            Label(store.hasGhost ? "Другое фото" : "Выбрать фото", systemImage: "photo.on.rectangle")
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        if store.hasGhost {
                            Button { store.rotateGhost() } label: {
                                Image(systemName: "rotate.right")
                            }
                            .buttonStyle(.bordered)
                            Button(role: .destructive) { store.removeGhost() } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .font(.footnote)
                    .id(store.ghostVersion)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// Белая кнопка, как фото в Камере
    private var shutter: some View {
        Button {
            pending = Shot(q: motion.q, g: motion.g, lens: "\(cam.zoom)")
            cam.capture()
        } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                Circle().fill(Color.white.opacity(cam.busy ? 0.4 : 1)).frame(width: 64, height: 64)
            }
        }
        .disabled(cam.busy)
    }

    // MARK: Логика

    @MainActor private func loadLastThumb() async {
        guard let u = store.photos.last?.url else {
            lastThumb = nil
            return
        }
        lastThumb = await Task.detached { Thumb.make(u, maxPixel: 200) }.value
    }

    @MainActor private func refreshOverlay() async {
        let source: URL?
        if target == .gallery {
            source = store.hasGhost ? store.ghostURL : nil
        } else {
            source = store.target(target)?.url
        }
        guard mode != .off, let url = source else {
            overlayImage = nil
            return
        }
        let m = mode
        let img = await Task.detached(priority: .userInitiated) {
            m == .edges ? OverlayMaker.edges(url) : OverlayMaker.ghost(url)
        }.value
        overlayImage = img
    }

    /// Фото из галереи становится призраком текущего проекта
    private func loadPicked() {
        guard let item = pickedItem else { return }
        Task { @MainActor in
            let data = try? await item.loadTransferable(type: Data.self)
            pickedItem = nil
            if let d = data, UIImage(data: d) != nil, store.setGhost(d) {
                flash("Призрак из галереи готов")
            } else {
                flash("Не удалось открыть фото")
            }
        }
    }

    private func handle(_ data: Data, _ ext: String) {
        let shot = pending ?? Shot(q: motion.q, g: motion.g, lens: "\(cam.zoom)")
        pending = nil
        if store.addPhoto(data: data, ext: ext, shot: shot) != nil {
            if copyToPhotos { saveToPhotos(data) }
            flash("Снято: кадр №\(store.photos.count)")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            flash("Не удалось сохранить кадр")
        }
    }

    private func saveToPhotos(_ data: Data) {
        PHPhotoLibrary.shared().performChanges({
            let r = PHAssetCreationRequest.forAsset()
            r.addResource(with: .photo, data: data, options: nil)
        }) { _, _ in }
    }

    private func flash(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if toast == text { toast = nil }
        }
    }
}

// MARK: - Сборка видео

struct ExportError: Error {
    let text: String
}

final class Exporter: ObservableObject {
    @Published var running = false
    @Published var progress = 0.0
    @Published var status = ""

    func run(photos: [Photo], ref: Photo?, fps: Int, align: Bool, stamp: Bool, uhd: Bool) {
        guard !running else { return }
        guard photos.count >= 2 else {
            status = "Нужно минимум 2 кадра"
            return
        }
        running = true
        progress = 0
        status = "Собираю видео. Не закрывай приложение"
        UIApplication.shared.isIdleTimerDisabled = true
        let reference = ref ?? photos[0]
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Exporter.render(photos: photos, ref: reference, fps: fps, align: align,
                                         stamp: stamp, uhd: uhd) { p in
                DispatchQueue.main.async { self.progress = p }
            }
            switch result {
            case .failure(let e):
                DispatchQueue.main.async { self.finish(e.text) }
            case .success(let url):
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { ok, _ in
                    if ok { try? FileManager.default.removeItem(at: url) }
                    DispatchQueue.main.async {
                        self.finish(ok ? "Готово: видео в Фото" : "Нет доступа к Фото. Разреши в Настройках")
                    }
                }
            }
        }
    }

    private func finish(_ text: String) {
        running = false
        status = text
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private static let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    /// Картинка с датой (белый текст с тенью), уже сдвинутая в левый нижний угол
    private static func stampImage(_ text: String, th: Int) -> CIImage? {
        let fs = CGFloat(th) * 0.04
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = fs * 0.12
        shadow.shadowOffset = CGSize(width: 0, height: -fs * 0.04)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fs, weight: .semibold),
            .foregroundColor: UIColor.white,
            .shadow: shadow
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let pad = fs * 0.5
        let imgSize = CGSize(width: ceil(size.width + pad * 2), height: ceil(size.height + pad * 2))
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let ui = UIGraphicsImageRenderer(size: imgSize, format: fmt).image { _ in
            str.draw(at: CGPoint(x: pad, y: pad))
        }
        guard let ci = CIImage(image: ui) else { return nil }
        return ci.transformed(by: CGAffineTransform(translationX: fs, y: fs))
    }

    static func render(photos: [Photo], ref: Photo, fps: Int, align: Bool, stamp: Bool, uhd: Bool,
                       progress: (Double) -> Void) -> Result<URL, ExportError> {
        let ci = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: true])
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return .failure(ExportError(text: "Нет цветового профиля")) }

        func load(_ u: URL) -> CIImage? {
            CIImage(contentsOf: u, options: [.applyOrientationProperty: true])
        }

        guard let refImg = load(ref.url) else { return .failure(ExportError(text: "Не удалось открыть эталон")) }
        let rw = refImg.extent.width
        let rh = refImg.extent.height
        let longSide: CGFloat = uhd ? 3840 : 1920
        let k = longSide / max(rw, rh)
        let tw = max(2, Int((rw * k / 2).rounded()) * 2)
        let th = max(2, Int((rh * k / 2).rounded()) * 2)

        // Эталон в уменьшенном виде для поиска сдвига
        let sk = 1000 / max(rw, rh)
        let refSmall = refImg.transformed(by: CGAffineTransform(scaleX: sk, y: sk))
        let handler = VNImageRequestHandler(ciImage: refSmall, options: [:])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyFrame-\(Int(Date().timeIntervalSince1970)).mov")
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            return .failure(ExportError(text: "Не удалось создать файл видео"))
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: tw,
            AVVideoHeightKey: th,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: tw * th * 5]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: tw,
            kCVPixelBufferHeightKey as String: th
        ])
        guard w.canAdd(input) else { return .failure(ExportError(text: "Не удалось настроить видео")) }
        w.add(input)
        guard w.startWriting() else { return .failure(ExportError(text: "Не удалось начать запись")) }
        w.startSession(atSourceTime: .zero)

        var written = 0
        for (i, p) in photos.enumerated() {
            autoreleasepool {
                guard var img = load(p.url) else { return }
                let fw = img.extent.width
                let fh = img.extent.height

                // Автовыравнивание: ищем сдвиг относительно эталона
                var tx: CGFloat = 0
                var ty: CGFloat = 0
                if align && p.name != ref.name {
                    let sf = 1000 / max(fw, fh)
                    let small = img.transformed(by: CGAffineTransform(scaleX: sf, y: sf))
                    let req = VNTranslationalImageRegistrationRequest(targetedCIImage: small, options: [:])
                    if (try? handler.perform([req])) != nil,
                       let obs = req.results?.first as? VNImageTranslationAlignmentObservation {
                        let t = obs.alignmentTransform
                        let limit: CGFloat = 60
                        if abs(t.tx) < limit && abs(t.ty) < limit {
                            tx = t.tx / sf
                            ty = t.ty / sf
                        }
                    }
                }

                // Масштаб по размеру видео. Небольшой запас, чтобы скрыть края после сдвига
                let margin: CGFloat = align ? 1.04 : 1.0
                let s = max(CGFloat(tw) / fw, CGFloat(th) / fh) * margin
                let ox = CGFloat(tw) / 2 - s * fw / 2
                let oy = CGFloat(th) / 2 - s * fh / 2
                let tr = CGAffineTransform(translationX: tx, y: ty)
                    .concatenating(CGAffineTransform(scaleX: s, y: s))
                    .concatenating(CGAffineTransform(translationX: ox, y: oy))
                img = img.transformed(by: tr)

                if stamp, let d = p.date, let st = stampImage(stampFmt.string(from: d), th: th) {
                    img = st.composited(over: img)
                }

                var pbOut: CVPixelBuffer?
                if let pool = ad.pixelBufferPool {
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
                }
                guard let pb = pbOut else { return }
                ci.render(img, to: pb, bounds: CGRect(x: 0, y: 0, width: tw, height: th), colorSpace: cs)
                var tries = 0
                while !input.isReadyForMoreMediaData && tries < 500 {
                    usleep(10_000)
                    tries += 1
                }
                if input.isReadyForMoreMediaData {
                    ad.append(pb, withPresentationTime: CMTime(value: Int64(written), timescale: Int32(fps)))
                    written += 1
                }
            }
            progress(Double(i + 1) / Double(photos.count))
        }

        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        w.finishWriting { sem.signal() }
        sem.wait()
        guard w.status == .completed, written > 0 else {
            return .failure(ExportError(text: "Ошибка записи видео"))
        }
        return .success(url)
    }
}

// MARK: - Архив

struct ThumbCell: View {
    let photo: Photo
    let isRef: Bool
    @State private var img: UIImage?

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yy"
        return f
    }()

    var body: some View {
        Color(white: 0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let img {
                    Image(uiImage: img).resizable().scaledToFill()
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(photo.date.map { ThumbCell.fmt.string(from: $0) } ?? "")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(3)
                    .background(Color.black.opacity(0.55))
            }
            .overlay(alignment: .topTrailing) {
                if isRef {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.orange)
                        .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: photo.name) {
                let u = photo.url
                img = await Task.detached { Thumb.make(u, maxPixel: 300) }.value
            }
    }
}

struct PhotoViewer: View {
    let photo: Photo
    @Environment(\.dismiss) private var dismiss
    @State private var img: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let img {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                ProgressView()
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(Color.white.opacity(0.8))
            }
            .padding()
        }
        .task {
            let u = photo.url
            img = await Task.detached { Thumb.make(u, maxPixel: 2600) }.value
        }
    }
}

struct ArchiveView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var exporter = Exporter()
    @AppStorage("fps") private var fps = 8
    @AppStorage("align") private var align = true
    @AppStorage("stamp") private var stamp = true
    @AppStorage("res4k") private var res4k = true
    @AppStorage("remind") private var remind = false
    @AppStorage("remindMin") private var remindMin = 20 * 60
    @AppStorage("copyToPhotos") private var copyToPhotos = true
    @State private var viewing: Photo?
    @State private var picked: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var importNote = ""
    @State private var confirmDelete: Photo?

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: remindMin / 60, minute: remindMin % 60, second: 0, of: Date()) ?? Date()
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                remindMin = (c.hour ?? 20) * 60 + (c.minute ?? 0)
            }
        )
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.11))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    exportCard
                    settingsCard
                    gridCard
                }
                .padding()
            }
            .navigationTitle("Архив: \(store.current)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .fullScreenCover(item: $viewing) { p in PhotoViewer(photo: p) }
        .confirmationDialog("Удалить кадр?", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let p = confirmDelete { store.delete(p) }
                confirmDelete = nil
            }
        }
        .onChange(of: remind) { schedule() }
        .onChange(of: remindMin) { schedule() }
    }

    private var exportCard: some View {
        card {
            Text("Видео").font(.headline)
            Stepper("Скорость: \(fps) кадров в секунду", value: $fps, in: 2...30)
            Text("\(store.photos.count) кадров дадут \(String(format: "%.1f", Double(store.photos.count) / Double(max(fps, 1)))) с видео")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Выровнять кадры автоматически", isOn: $align)
            Toggle("Дата в углу", isOn: $stamp)
            Picker("Размер", selection: $res4k) {
                Text("1080p").tag(false)
                Text("4K").tag(true)
            }
            .pickerStyle(.segmented)
            Button {
                exporter.run(photos: store.photos, ref: store.refPhoto, fps: fps, align: align, stamp: stamp, uhd: res4k)
            } label: {
                Label(exporter.running ? "Собираю..." : "Собрать видео", systemImage: "film")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(exporter.running || store.photos.count < 2)
            if exporter.running {
                ProgressView(value: exporter.progress)
            }
            if !exporter.status.isEmpty {
                Text(exporter.status).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var settingsCard: some View {
        card {
            Text("Напоминание и копии").font(.headline)
            Toggle("Напоминать каждый день", isOn: $remind)
            if remind {
                DatePicker("Время", selection: timeBinding, displayedComponents: .hourAndMinute)
            }
            Toggle("Копия каждого кадра в Фото", isOn: $copyToPhotos)
            Text("Кадры хранятся в приложении (Файлы → На iPhone → Кадр дня). Если удалить приложение, они пропадут, поэтому копия в Фото включена по умолчанию")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var gridCard: some View {
        card {
            Text("Кадры: \(store.photos.count)").font(.headline)
            PhotosPicker(selection: $picked, maxSelectionCount: 0, matching: .images) {
                Label(importing ? "Добавляю..." : "Добавить из галереи телефона", systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(importing)
            .onChange(of: picked) { importPicked() }
            if !importNote.isEmpty {
                Text(importNote).font(.footnote).foregroundStyle(.secondary)
            }
            if store.photos.isEmpty {
                Text("Пока пусто. Сними первый кадр белой кнопкой или добавь снимки из галереи")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Нажми, чтобы открыть. Удерживай, чтобы сделать эталоном или удалить. Звёздочка - эталон")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], spacing: 6) {
                    ForEach(store.photos.reversed()) { p in
                        ThumbCell(photo: p, isRef: p.name == store.refPhoto?.name)
                            .onTapGesture { viewing = p }
                            .contextMenu {
                                Button("Сделать эталоном") { store.setRef(p) }
                                Button("Удалить", role: .destructive) { confirmDelete = p }
                            }
                    }
                }
            }
        }
    }

    private func importPicked() {
        let items = picked
        guard !items.isEmpty else { return }
        importing = true
        importNote = ""
        Task {
            var got: [(Data, String)] = []
            for it in items {
                if let d = try? await it.loadTransferable(type: Data.self) {
                    let ext = (it.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg").lowercased()
                    if ["heic", "jpg", "jpeg"].contains(ext) {
                        got.append((d, ext == "jpeg" ? "jpg" : ext))
                    } else if let j = UIImage(data: d)?.jpegData(compressionQuality: 0.95) {
                        got.append((j, "jpg"))   // PNG и прочее - в JPEG, как остальные кадры
                    }
                }
            }
            let n = store.importImages(got)
            importing = false
            picked = []
            importNote = n > 0 ? "Добавлено снимков: \(n). Они встали по дате съёмки" : "Не удалось добавить снимки"
        }
    }

    private func schedule() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["daily"])
        guard remind else { return }
        let h = remindMin / 60
        let m = remindMin % 60
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = "Кадр дня"
            content.body = "Пора снять сегодняшний кадр"
            content.sound = .default
            var comps = DateComponents()
            comps.hour = h
            comps.minute = m
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            center.add(UNNotificationRequest(identifier: "daily", content: content, trigger: trigger))
        }
    }
}
