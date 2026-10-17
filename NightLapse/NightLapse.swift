// NightLapse 2.1 - найтлапс с длинной выдержкой для iPhone
// Каждый кадр видео = склейка подкадров сенсора (как ночной режим iPhone), выдержка кадра до 120 с.
// 2.1: авто ISO / авто баланс белого / автофокус, продолжение съёмки после звонка.

import SwiftUI
import UIKit
import AVFoundation
import Accelerate
import Photos
import CoreImage
import ImageIO

enum AppMode: String { case night, daily }

@main
struct NightLapseApp: App {
    @State private var mode: AppMode = {
        AppMode(rawValue: UserDefaults.standard.string(forKey: "appMode") ?? "") ?? .night
    }()

    var body: some Scene {
        WindowGroup {
            Group {
                if mode == .night {
                    ContentView(onSwitch: { switchTo(.daily) })
                        .tint(.red)
                } else {
                    RootView(onSwitch: { switchTo(.night) })
                        .tint(.orange)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func switchTo(_ m: AppMode) {
        UserDefaults.standard.set(m.rawValue, forKey: "appMode")
        mode = m
    }
}

// MARK: - Типы

enum LensKind: String, CaseIterable, Identifiable {
    case ultraWide, wide, tele
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ultraWide: return "0.5x"
        case .wide: return "1x"
        case .tele: return "Теле"
        }
    }
    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide: return .builtInWideAngleCamera
        case .tele: return .builtInTelephotoCamera
        }
    }
}

/// Зум как в Камере iPhone: 0.5x, 1x, 2x, 3x, 4x, 8x. Каждый зум = объектив + цифровое увеличение
struct ZoomOption: Identifiable, Hashable {
    let value: Double
    let type: AVCaptureDevice.DeviceType
    let crop: CGFloat
    var id: Double { value }
    var title: String {
        if value < 1 { return String(format: "%.1fx", value) }
        return abs(value - value.rounded()) < 0.01 ? "\(Int(value.rounded()))x" : String(format: "%.1fx", value)
    }

    static func available() -> [ZoomOption] {
        let ds = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .back)
        let has = Set(ds.devices.map { $0.deviceType })
        // Во сколько раз телевик ближе основной камеры (на iPhone 17 Pro Max - 4x)
        var tele = 3.0
        if let tri = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back),
           tri.virtualDeviceSwitchOverVideoZoomFactors.count >= 2 {
            let f = tri.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue }
            tele = f[1] / max(f[0], 0.01)
        } else if let dual = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back),
                  let f = dual.virtualDeviceSwitchOverVideoZoomFactors.first {
            tele = f.doubleValue
        }
        tele = (tele * 2).rounded() / 2
        let hasTele = has.contains(.builtInTelephotoCamera)
        var out: [ZoomOption] = []
        if has.contains(.builtInUltraWideCamera) {
            out.append(ZoomOption(value: 0.5, type: .builtInUltraWideCamera, crop: 1))
        }
        out.append(ZoomOption(value: 1, type: .builtInWideAngleCamera, crop: 1))
        for z in [2.0, 3.0] where !hasTele || z < tele - 0.01 {
            out.append(ZoomOption(value: z, type: .builtInWideAngleCamera, crop: CGFloat(z)))
        }
        if hasTele {
            out.append(ZoomOption(value: tele, type: .builtInTelephotoCamera, crop: 1))
            out.append(ZoomOption(value: tele * 2, type: .builtInTelephotoCamera, crop: 2))
        }
        return out
    }

    static func pick(_ v: Double, in list: [ZoomOption]) -> ZoomOption {
        list.first { abs($0.value - v) < 0.01 } ?? list.first { $0.value == 1 } ?? list[0]
    }
}

/// Цифровое увеличение (queue): не больше, чем умеет формат
func applyCrop(_ crop: CGFloat, to dev: AVCaptureDevice) {
    guard (try? dev.lockForConfiguration()) != nil else { return }
    dev.videoZoomFactor = min(max(crop, 1), dev.activeFormat.videoMaxZoomFactor)
    dev.unlockForConfiguration()
}

enum Phase { case idle, test, waiting, recording, paused, saving }

/// Готовые сценарии: одно нажатие выставляет выдержку, паузу, режим и коррекцию
enum LapseScene: String, CaseIterable, Identifiable {
    case stars, trails, city, clouds
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stars: return "Звёзды"
        case .trails: return "Треки звёзд"
        case .city: return "Город"
        case .clouds: return "Облака"
        }
    }
    var icon: String {
        switch self {
        case .stars: return "sparkles"
        case .trails: return "circle.dashed"
        case .city: return "building.2"
        case .clouds: return "cloud.sun"
        }
    }
    var hint: String {
        switch self {
        case .stars: return "Ночное небо и Млечный путь, звёзды точками. Фокус на бесконечность"
        case .trails: return "Звёзды и огни рисуют длинные линии"
        case .city: return "Шлейфы фар и огни города"
        case .clouds: return "Закат, облака, день. Выдержка сама укоротится, если светло"
        }
    }
    var exposure: Double {
        switch self {
        case .stars: return 20
        case .trails: return 30
        case .city: return 4
        case .clouds: return 2
        }
    }
    var pause: Double {
        switch self {
        case .stars: return 1
        case .trails: return 0
        case .city: return 1
        case .clouds: return 3
        }
    }
    var lighten: Bool { self == .trails || self == .city }
    var ev: Double {
        switch self {
        case .stars: return -1
        case .trails: return -1
        case .city: return -1
        case .clouds: return -0.5
        }
    }
}

/// 1/8 с, 0.5 с, 17 с
func expText(_ v: Double) -> String {
    if v >= 1 { return abs(v - v.rounded()) < 0.05 ? "\(Int(v.rounded())) с" : String(format: "%.1f с", v) }
    let d = (1 / v).rounded()
    if abs(1 / d - v) < 0.0005 { return "1/\(Int(d)) с" }
    return String(format: "%.2f с", v)
}

struct LapseConfig {
    var subNeeded = 30
    var exposure = 1.0
    var pause = 2.0
    var lighten = false
    var gain: Float = 1
    var fps: Int32 = 25
    var vertical = false
    var saveVideo = true
    var saveFrames = false
    var name = "NightLapse"
    var warmup = 2
    var isoAuto = false
    var ev: Float = -2
    var iso: Float = 800
}

struct CamSettings {
    var dur: Double
    var ev: Float
    var iso: Float
    var temp: Float
    var focus: Float
    var wbAuto: Bool
    var focusAuto: Bool
}

private enum Mode { case off, test, record }

private extension UserDefaults {
    func dbl(_ k: String, _ d: Double) -> Double { (object(forKey: k) as? NSNumber)?.doubleValue ?? d }
    func flag(_ k: String, _ d: Bool) -> Bool { (object(forKey: k) as? NSNumber)?.boolValue ?? d }
    func num(_ k: String, _ d: Int) -> Int { (object(forKey: k) as? NSNumber)?.intValue ?? d }
}

func hms(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

// MARK: - Движок съёмки

final class LapseEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "nightlapse.queue", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let ci = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: true])
    private let ud = UserDefaults.standard
    private var device: AVCaptureDevice?

    // Выдержка не запоминается: при каждом запуске стоит значение по умолчанию
    static let defaultExposure: Double = 1
    /// Шаги выдержки: доли секунды, потом целые секунды
    static let exposureSteps: [Double] = {
        let fractions: [Double] = [1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000, 1.0 / 500, 1.0 / 250,
                                   1.0 / 125, 1.0 / 60, 0.0333333, 0.0666667, 0.125, 0.25, 0.5]
        let whole: [Double] = (1...120).map { (i: Int) -> Double in Double(i) }
        return fractions + whole
    }()
    @Published var exposureSeconds: Double

    // Остальные настройки запоминаются между запусками
    @Published var pauseSeconds: Double { didSet { ud.set(pauseSeconds, forKey: "pause") } }
    @Published var iso: Float { didSet { ud.set(iso, forKey: "iso") } }
    /// Цифровое усиление в авто ISO, когда сенсор уже на максимуме
    @Published var autoGainShown: Float = 1
    @Published var wbTemp: Float { didSet { ud.set(wbTemp, forKey: "wb") } }
    @Published var focus: Float { didSet { ud.set(focus, forKey: "focus") } }
    @Published var gain: Float { didSet { ud.set(gain, forKey: "gain") } }
    @Published var lighten: Bool { didSet { ud.set(lighten, forKey: "lighten") } }
    @Published var fps: Int { didSet { ud.set(fps, forKey: "fps") } }
    @Published var vertical: Bool { didSet { ud.set(vertical, forKey: "vertical") } }
    @Published var saveVideo: Bool { didSet { ud.set(saveVideo, forKey: "saveVideo") } }
    @Published var saveFrames: Bool { didSet { ud.set(saveFrames, forKey: "saveFrames") } }
    @Published var zoom: Double { didSet { ud.set(zoom, forKey: "zoom") } }
    @Published var uhd: Bool { didSet { ud.set(uhd, forKey: "uhd") } }
    @Published var startDelayMin: Int { didSet { ud.set(startDelayMin, forKey: "delay") } }
    @Published var autoStopMin: Int { didSet { ud.set(autoStopMin, forKey: "autostop") } }
    /// Пауза для охлаждения, если телефон сильно нагрелся
    @Published var coolBreaks: Bool { didSet { ud.set(coolBreaks, forKey: "coolBreaks") } }
    @Published var cooling = false
    @Published var coolCount = 0
    /// Сколько секунд сейчас добавлено к паузе из-за нагрева
    @Published var coolExtra: Double = 0
    @Published var isoAuto: Bool { didSet { ud.set(isoAuto, forKey: "isoAuto") } }
    @Published var wbAuto: Bool { didSet { ud.set(wbAuto, forKey: "wbAuto") } }
    @Published var focusAuto: Bool { didSet { ud.set(focusAuto, forKey: "focusAuto") } }
    @Published var evComp: Double { didSet { ud.set(evComp, forKey: "ev") } }
    @Published var scene: String { didSet { ud.set(scene, forKey: "scene") } }
    /// Как будет записано видео: горизонтально или вертикально (по тому, как держишь телефон)
    @Published var captureLandscape = true

    // Возможности камеры
    @Published var zoomOptions: [ZoomOption] = []
    @Published var minISO: Float = 50
    @Published var maxISO: Float = 3200
    @Published var subExposure: Double = 1   // максимальная выдержка сенсора
    @Published var minSensorExposure: Double = 0.0001

    /// Реальная выдержка одного подкадра: короче максимума сенсора, если выдержка кадра меньше
    var sensorExposure: Double { min(max(exposureSeconds, minSensorExposure), max(subExposure, 0.0001)) }

    // Состояние
    @Published var phase: Phase = .idle
    @Published var status = "Готово"
    @Published var framesDone = 0
    @Published var subDone = 0
    @Published var subTotal = 1
    @Published var elapsed: TimeInterval = 0
    @Published var countdown: TimeInterval = 0
    @Published var battery = -1
    @Published var freeGB: Double = 0
    @Published var hot = false
    @Published var lastImage: UIImage?
    @Published var testCount = 0
    @Published var pauses = 0

    var subFramesPerFrame: Int { max(1, Int((exposureSeconds / max(sensorExposure, 0.0001)).rounded())) }

    func exposureUp() {
        if let n = Self.exposureSteps.first(where: { $0 > exposureSeconds + 0.0001 }) { exposureSeconds = n }
        applyCamera()
    }

    func exposureDown() {
        if let n = Self.exposureSteps.last(where: { $0 < exposureSeconds - 0.0001 }) { exposureSeconds = n }
        applyCamera()
    }

    // Только main
    private var configured = false
    private var ticker: Timer?
    private var tickCount = 0
    private var startAt: Date?
    private var recStart: Date?
    private var autoStopAt: Date?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var inBackground = false

    // Только queue
    private var mode: Mode = .off
    private var suspended = false
    private var cfg = LapseConfig()
    private var curISO: Float = 800
    private var curDur: CMTime = CMTime(seconds: 1, preferredTimescale: 1_000_000)
    private var warmupLeft = 0
    private var calibLeft = 0
    private var calibSkip = 0
    private var appliedFocusAuto: Bool?
    private var appliedFocusValue: Float = -1
    private var acc: [Float] = []
    private var tmp: [Float] = []
    private var width = 0, height = 0
    private var subCount = 0
    private var accStart: CMTime = .invalid
    private var inPause = false
    private var extraPause: Double = 0
    /// Авто ISO: если даже максимального ISO мало, кадр (уже очищенный от шума сложением) осветляется цифрово
    private var autoGain: Float = 1
    private let maxAutoGain: Float = 16
    private var phaseStart: CMTime = .invalid
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var videoURL: URL?
    private var framesDir: URL?
    private var videoIndex: Int64 = 0
    private var outIndex = 0

    override init() {
        let d = UserDefaults.standard
        exposureSeconds = LapseEngine.defaultExposure
        pauseSeconds = d.dbl("pause", 2)
        iso = Float(d.dbl("iso", 800))
        wbTemp = Float(d.dbl("wb", 4500))
        focus = Float(d.dbl("focus", 1))
        gain = Float(d.dbl("gain", 1))
        lighten = d.flag("lighten", false)
        fps = d.num("fps", 25)
        vertical = d.flag("vertical", false)
        saveVideo = d.flag("saveVideo", true)
        saveFrames = d.flag("saveFrames", false)
        zoom = d.dbl("zoom", 1)
        uhd = d.flag("uhd", true)
        startDelayMin = d.num("delay", 0)
        autoStopMin = d.num("autostop", 0)
        coolBreaks = d.flag("coolBreaks", true)
        isoAuto = d.flag("isoAuto", true)
        wbAuto = d.flag("wbAuto", false)
        focusAuto = d.flag("focusAuto", false)
        evComp = d.dbl("ev", -2)
        scene = d.string(forKey: "scene") ?? ""
        super.init()

        zoomOptions = ZoomOption.available()
        zoom = ZoomOption.pick(zoom, in: zoomOptions).value

        UIDevice.current.isBatteryMonitoringEnabled = true

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appDidEnterBackground()
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appDidBecomeActive()
        }
        nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            self?.camWasInterrupted()
        }
        nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            self?.camInterruptionEnded()
        }
        nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
            self?.camRuntimeError()
        }

        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    // MARK: Управление (main)

    private var closed = false

    /// Выключить камеру при переходе в режим «Кадр дня»
    func shutdown() {
        closed = true
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func configure() {
        guard !configured else { return }
        configured = true
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                if ok { self.changeCamera() } else { self.status = "Нет доступа к камере: Настройки → NightLapse" }
            }
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }

    private func currentSettings() -> CamSettings {
        CamSettings(dur: exposureSeconds, ev: Float(evComp), iso: iso, temp: wbTemp, focus: focus, wbAuto: wbAuto, focusAuto: focusAuto)
    }

    func changeCamera() {
        guard phase == .idle else { return }
        let z = ZoomOption.pick(zoom, in: zoomOptions), u = uhd, s = currentSettings()
        queue.async { self.reconfigure(zoom: z, uhd: u, settings: s) }
    }

    func applyCamera(forceFocus: Bool = false) {
        let s = currentSettings()
        queue.async { self.applyOnQueue(s, forceFocus: forceFocus) }
    }

    /// Переключение авто / ручной фокус: при переходе на ручной берём текущее положение линзы
    func focusModeChanged() {
        if !focusAuto {
            if infinityPending {
                focus = 1
                infinityPending = false
            } else if let dev = device {
                focus = min(max(dev.lensPosition, 0), 1)
            }
        }
        applyCamera()
    }

    private var infinityPending = false

    func applyScene(_ sc: LapseScene) {
        guard phase == .idle else { return }
        scene = sc.rawValue
        exposureSeconds = sc.exposure
        pauseSeconds = sc.pause
        lighten = sc.lighten
        evComp = sc.ev
        isoAuto = true
        if focusAuto {
            infinityPending = true
            focusAuto = false
        } else {
            focus = 1
        }
        applyCamera(forceFocus: true)
    }

    // MARK: Поворот (main): превью всегда ровно по горизонту, видео пишется так, как держишь телефон

    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var rotObs: [NSKeyValueObservation] = []
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        rebuildCoordinator()
    }

    private func rebuildCoordinator() {
        guard let dev = device, let layer = previewLayer else { return }
        let c = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: layer)
        coordinator = c
        applyRotation()
        rotObs = [
            c.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyRotation() }
            },
            c.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyRotation() }
            }
        ]
    }

    private func applyRotation() {
        guard let c = coordinator else { return }
        if let conn = previewLayer?.connection {
            let a = c.videoRotationAngleForHorizonLevelPreview
            if conn.isVideoRotationAngleSupported(a) { conn.videoRotationAngle = a }
        }
        if phase == .idle {
            let land = Int(c.videoRotationAngleForHorizonLevelCapture.rounded()) % 180 == 0
            if land != captureLandscape { captureLandscape = land }
        }
    }

    private func captureAngle() -> CGFloat {
        coordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
    }

    /// queue: кадры с сенсора поворачиваются так, как держишь телефон в момент старта
    private func setOutputAngle(_ a: CGFloat) {
        if let conn = output.connection(with: .video), conn.isVideoRotationAngleSupported(a) {
            conn.videoRotationAngle = a
        }
    }

    /// Фокус по касанию картинки (только в автофокусе и до старта)
    /// Касание кадра, как в Камере iPhone: фокус и замер яркости в этой точке.
    /// Если автофокус выключен, после наводки фокус фиксируется на найденном расстоянии
    func focusAt(_ p: CGPoint) {
        guard phase == .idle else { return }
        let fa = focusAuto
        queue.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            defer { dev.unlockForConfiguration() }
            if dev.isFocusPointOfInterestSupported { dev.focusPointOfInterest = p }
            if dev.isFocusModeSupported(.autoFocus) { dev.focusMode = .autoFocus }
            if dev.isExposurePointOfInterestSupported { dev.exposurePointOfInterest = p }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            // Чтобы смена яркости сразу после касания не сбила наводку
            self.appliedFocusAuto = fa
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard self.phase == .idle, !self.focusAuto, let dev = self.device else { return }
            self.focus = min(max(dev.lensPosition, 0), 1)
            self.scene = ""
            self.applyCamera(forceFocus: true)
        }
    }

    /// Яркость, как ползунок-солнце в Камере: сдвиг в EV
    func nudgeBrightness(_ delta: Double) {
        guard phase == .idle else { return }
        let v = min(max(evComp + delta, -4), 2)
        evComp = (v * 10).rounded() / 10
    }

    private func warmupFrames() -> Int {
        guard focusAuto else { return 2 }
        return min(12, max(3, Int((3.0 / max(sensorExposure, 0.05)).rounded(.up))))
    }

    func testFrame() {
        guard phase == .idle else { return }
        let c = makeConfig(name: "test")
        phase = .test
        subTotal = c.subNeeded
        subDone = 0
        status = c.isoAuto ? "Подбор ISO..." : "Тестовый кадр..."
        UIApplication.shared.isIdleTimerDisabled = true
        let s = currentSettings()
        let ff = focusAuto
        let angle = captureAngle()
        queue.async {
            self.setOutputAngle(angle)
            self.cfg = c
            self.subCount = 0
            self.inPause = false
            self.suspended = false
            self.warmupLeft = c.warmup
            self.calibLeft = c.isoAuto ? 4 : 0
            self.calibSkip = 0
            self.setAutoGain(1)
            self.mode = .test
            self.beginCaptureExposure(s, forceFocus: ff)
        }
    }

    func start() {
        guard phase == .idle else { return }
        guard saveVideo || saveFrames else { status = "Включи сохранение видео или кадров"; return }
        UIApplication.shared.isIdleTimerDisabled = true
        if startDelayMin > 0 {
            startAt = Date().addingTimeInterval(Double(startDelayMin) * 60)
            countdown = Double(startDelayMin) * 60
            phase = .waiting
            status = "Ожидание старта"
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let c = makeConfig(name: "NightLapse_" + f.string(from: Date()))
        framesDone = 0
        subDone = 0
        subTotal = c.subNeeded
        elapsed = 0
        pauses = 0
        coolCount = 0
        cooling = false
        setExtra(0)
        let now = Date()
        recStart = now
        autoStopAt = autoStopMin > 0 ? now.addingTimeInterval(Double(autoStopMin) * 60) : nil
        phase = .recording
        status = c.isoAuto ? "Подбор ISO..." : "Съёмка"
        UIApplication.shared.isIdleTimerDisabled = true
        let s = currentSettings()
        let ff = focusAuto
        let angle = captureAngle()
        queue.async {
            self.setOutputAngle(angle)
            self.cfg = c
            self.subCount = 0
            self.inPause = false
            self.suspended = false
            self.warmupLeft = c.warmup
            self.calibLeft = c.isoAuto ? 4 : 0
            self.calibSkip = 0
            self.setAutoGain(1)
            self.writer = nil
            self.framesDir = nil
            self.videoIndex = 0
            self.outIndex = 0
            self.mode = .record
            self.beginCaptureExposure(s, forceFocus: ff)
        }
    }

    func stop() {
        guard phase == .recording || phase == .paused else { return }
        if cooling {
            cooling = false
            setExtra(0)
        }
        phase = .saving
        status = "Сохраняю..."
        UIApplication.shared.isIdleTimerDisabled = false
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "NightLapseSave") { [weak self] in self?.endBG() }
        queue.async { self.finishOnQueue() }
    }

    func cancel() {
        switch phase {
        case .waiting:
            startAt = nil
            finished("Отменено")
        case .test:
            let s = currentSettings()
            queue.async {
                self.mode = .off
                self.applyOnQueue(s)
            }
            subDone = 0
            finished("Отменено")
        default:
            break
        }
    }

    // MARK: Звонки, сворачивание, прерывания камеры (main)

    private func appDidEnterBackground() {
        inBackground = true
        switch phase {
        case .recording: pauseRecording("Пауза: приложение свёрнуто")
        case .test: cancel()
        default: break
        }
    }

    private func appDidBecomeActive() {
        inBackground = false
        tryResume()
    }

    private func camWasInterrupted() {
        switch phase {
        case .recording: pauseRecording("Пауза: камера занята (звонок)")
        case .test: cancel()
        default: break
        }
    }

    private func camInterruptionEnded() {
        tryResume()
    }

    private func camRuntimeError() {
        guard !closed else { return }
        queue.async {
            if !self.session.isRunning { self.session.startRunning() }
        }
        applyCamera()
        tryResume()
    }

    private func pauseRecording(_ why: String) {
        guard phase == .recording else { return }
        phase = .paused
        status = why
        pauses += 1
        subDone = 0
        queue.async {
            self.suspended = true
            self.subCount = 0
            self.inPause = false
        }
    }

    /// Съёмка продолжается сама, когда приложение снова на экране и камера свободна
    private func tryResume() {
        guard phase == .paused, !inBackground, !session.isInterrupted else { return }
        phase = .recording
        status = isoAuto ? "Продолжаю: подбор ISO..." : "Съёмка продолжена"
        subDone = 0
        let s = currentSettings()
        let warm = warmupFrames()
        queue.async {
            if !self.session.isRunning { self.session.startRunning() }
            self.applyOnQueue(s, forceFocus: s.focusAuto)
            self.subCount = 0
            self.inPause = false
            self.warmupLeft = warm
            self.calibLeft = self.cfg.isoAuto ? 2 : 0
            self.calibSkip = 0
            self.suspended = false
        }
    }

    private func finished(_ msg: String) {
        phase = .idle
        status = msg
        recStart = nil
        autoStopAt = nil
        startAt = nil
        UIApplication.shared.isIdleTimerDisabled = false
        endBG()
    }

    private func endBG() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    private func makeConfig(name: String) -> LapseConfig {
        LapseConfig(subNeeded: subFramesPerFrame, exposure: exposureSeconds, pause: pauseSeconds, lighten: lighten,
                    gain: isoAuto ? 1 : gain, fps: Int32(fps), vertical: false,
                    saveVideo: saveVideo, saveFrames: saveFrames, name: name,
                    warmup: warmupFrames(), isoAuto: isoAuto, ev: Float(evComp), iso: iso)
    }

    private func tick() {
        let now = Date()
        if phase == .waiting, let s = startAt {
            countdown = max(0, s.timeIntervalSince(now))
            if now >= s {
                startAt = nil
                beginRecording()
            }
        }
        if phase == .recording || phase == .paused, let r = recStart {
            elapsed = now.timeIntervalSince(r)
            if let a = autoStopAt, now >= a { stop() }
        }
        let b = UIDevice.current.batteryLevel
        let bat = b < 0 ? -1 : Int((b * 100).rounded())
        if bat != battery { battery = bat }
        let state = ProcessInfo.processInfo.thermalState
        let isHot = state == .serious || state == .critical
        if isHot != hot { hot = isHot }
        checkCooling(state, now)
        if tickCount % 10 == 0 { updateFree() }
        tickCount += 1
    }

    // MARK: Охлаждение (main)

    /// Сильный нагрев: к паузе между кадрами добавляется время, пока телефон не остынет.
    /// Камера при этом не выключается, кадры просто не обрабатываются. Остыл - пауза снова твоя
    private func checkCooling(_ state: ProcessInfo.ThermalState, _ now: Date) {
        guard coolBreaks, phase == .recording || phase == .paused else {
            if cooling {
                cooling = false
                setExtra(0)
            }
            return
        }
        let isHot = state == .serious || state == .critical
        if isHot {
            // Добавка = ещё один интервал (не меньше 5 с), при критическом нагреве - втрое больше
            let base = max(exposureSeconds + pauseSeconds, 5).rounded()
            let x = state == .critical ? base * 3 : base
            if !cooling {
                cooling = true
                coolCount += 1
            }
            if x != coolExtra {
                setExtra(x)
                if phase == .recording { status = "Телефон нагрелся: пауза +\(Int(x)) с, пока не остынет" }
            }
        } else if cooling {
            cooling = false
            setExtra(0)
            if phase == .recording { status = "Остыл, пауза снова \(Int(pauseSeconds)) с" }
        }
    }

    private func setExtra(_ x: Double) {
        coolExtra = x
        queue.async { self.extraPause = x }
    }

    private func updateFree() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            freeGB = Double(v) / 1_000_000_000
        }
    }

    private static func docs() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: Камера (queue)

    private func reconfigure(zoom: ZoomOption, uhd: Bool, settings: CamSettings) {
        guard let dev = AVCaptureDevice.default(zoom.type, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev) else {
            DispatchQueue.main.async { self.status = "Камера недоступна" }
            return
        }
        session.beginConfiguration()
        for old in session.inputs { session.removeInput(old) }
        if session.canAddInput(input) { session.addInput(input) }
        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        session.commitConfiguration()
        device = dev

        // Формат: нужное разрешение 16:9 с самой длинной выдержкой сенсора
        let tw: Int32 = uhd ? 3840 : 1920
        let th: Int32 = uhd ? 2160 : 1080
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        }
        func score(_ f: AVCaptureDevice.Format) -> Double {
            var s = CMTimeGetSeconds(f.maxExposureDuration) * 1000
            if CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
                s += 1
            }
            return s
        }
        var cands = dev.formats.filter { dims($0).width == tw && dims($0).height == th }
        if cands.isEmpty { cands = dev.formats.filter { dims($0).width <= 3840 } }
        if let best = cands.max(by: { score($0) < score($1) }), (try? dev.lockForConfiguration()) != nil {
            dev.activeFormat = best
            dev.unlockForConfiguration()
        }

        applyCrop(zoom.crop, to: dev)
        let fmt = dev.activeFormat
        let sub = CMTimeGetSeconds(fmt.maxExposureDuration)
        let subMin = CMTimeGetSeconds(fmt.minExposureDuration)
        let lo = fmt.minISO, hi = fmt.maxISO
        appliedFocusAuto = nil
        applyOnQueue(settings, forceFocus: true)
        if !session.isRunning { session.startRunning() }
        DispatchQueue.main.async {
            self.minISO = lo
            self.maxISO = hi
            if self.iso < lo || self.iso > hi { self.iso = min(max(self.iso, lo), hi) }
            self.subExposure = sub
            self.minSensorExposure = subMin
            self.rebuildCoordinator()
        }
    }

    /// Ручная выдержка (максимум сенсора), ISO, фокус и баланс белого (ручной или авто)
    private func applyOnQueue(_ s: CamSettings, forceFocus: Bool = false) {
        guard let dev = device, (try? dev.lockForConfiguration()) != nil else { return }
        defer { dev.unlockForConfiguration() }
        let fmt = dev.activeFormat

        if mode == .off {
            // До старта превью с автоэкспозицией, чтобы было видно, что в кадре. Коррекция EV видна сразу
            if dev.isExposureModeSupported(.continuousAutoExposure) {
                dev.exposureMode = .continuousAutoExposure
            }
            dev.setExposureTargetBias(min(max(s.ev, dev.minExposureTargetBias), dev.maxExposureTargetBias),
                                      completionHandler: nil)
        } else if dev.isExposureModeSupported(.custom) {
            // Во время съёмки: ручная выдержка сенсора. В авто ISO выдержку и ISO ведёт подстройка
            if !cfg.isoAuto {
                let lo = CMTimeGetSeconds(fmt.minExposureDuration)
                let hi = CMTimeGetSeconds(fmt.maxExposureDuration)
                curDur = CMTime(seconds: min(max(s.dur, lo), hi), preferredTimescale: 1_000_000)
                curISO = min(max(s.iso, fmt.minISO), fmt.maxISO)
            }
            dev.setExposureTargetBias(0, completionHandler: nil)
            dev.setExposureModeCustom(duration: curDur, iso: curISO, completionHandler: nil)
        }

        // Фокус трогаем только при изменении, иначе автофокус будет сканировать при каждом движении ползунка
        let changed = forceFocus
            || appliedFocusAuto != s.focusAuto
            || (!s.focusAuto && abs(appliedFocusValue - s.focus) > 0.001)
        if changed {
            if s.focusAuto {
                if dev.isFocusModeSupported(.autoFocus) { dev.focusMode = .autoFocus }
            } else if dev.isLockingFocusWithCustomLensPositionSupported {
                dev.setFocusModeLocked(lensPosition: min(max(s.focus, 0), 1), completionHandler: nil)
            } else if dev.isFocusModeSupported(.locked) {
                dev.focusMode = .locked
            }
            appliedFocusAuto = s.focusAuto
            appliedFocusValue = s.focus
        }

        if s.wbAuto {
            if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                dev.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        } else if dev.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
            let tv = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: s.temp, tint: 0)
            var g = dev.deviceWhiteBalanceGains(for: tv)
            let m = dev.maxWhiteBalanceGain
            g.redGain = min(max(g.redGain, 1), m)
            g.greenGain = min(max(g.greenGain, 1), m)
            g.blueGain = min(max(g.blueGain, 1), m)
            dev.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
        }
    }

    /// Переход от превью к съёмке. В авто ISO стартуем с яркости, которую уже подобрала автоэкспозиция превью
    private func beginCaptureExposure(_ s: CamSettings, forceFocus: Bool) {
        if cfg.isoAuto, let dev = device {
            let light = Double(dev.iso) * max(CMTimeGetSeconds(dev.exposureDuration), 0.00001)
            setExposure(light: light)
        }
        applyOnQueue(s, forceFocus: forceFocus)
    }

    // MARK: Авто ISO (queue)

    private func meanLuma(_ pb: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return 0 }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let rb = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        var cnt = 0.0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let o = y * rb + x * 4
                sum += 0.114 * Double(p[o]) + 0.587 * Double(p[o + 1]) + 0.299 * Double(p[o + 2])
                cnt += 1
                x += 8
            }
            y += 16
        }
        return cnt > 0 ? Float(sum / cnt) : 0
    }

    /// Сколько света нужно добавить или убрать. Целевая яркость: 118 (средне-серый) со сдвигом на коррекцию в EV.
    /// Считаем в линейном свете (гамма 2.2)
    private func lightFactor(mean: Float, limit: Double) -> Double {
        let target = 118.0 * pow(pow(2.0, Double(cfg.ev)), 1.0 / 2.2)
        let f = pow(target / max(Double(mean), 1.0), 2.2)
        return min(max(f, 1.0 / limit), limit)
    }

    /// Свет = ISO × выдержка. Сначала самая длинная выдержка (до выдержки кадра) и самое низкое ISO.
    /// Если даже на минимальном ISO слишком светло, выдержка сенсора укорачивается.
    /// Возвращает, во сколько раз реально изменился свет
    @discardableResult
    private func setExposure(light: Double) -> Double {
        guard let dev = device else { return 1 }
        let fmt = dev.activeFormat
        let lo = CMTimeGetSeconds(fmt.minExposureDuration)
        let hi = min(CMTimeGetSeconds(fmt.maxExposureDuration), max(cfg.exposure, lo))
        let old = Double(curISO) * CMTimeGetSeconds(curDur)
        let d = min(hi, max(lo, light / Double(fmt.minISO)))
        let i = min(max(Float(light / d), fmt.minISO), fmt.maxISO)
        curDur = CMTime(seconds: d, preferredTimescale: 1_000_000)
        curISO = i
        if (try? dev.lockForConfiguration()) != nil {
            if dev.isExposureModeSupported(.custom) {
                dev.setExposureModeCustom(duration: curDur, iso: i, completionHandler: nil)
            }
            dev.unlockForConfiguration()
        }
        DispatchQueue.main.async { self.iso = i }
        return old > 0 ? (Double(i) * d) / old : 1
    }

    private func currentLight() -> Double {
        Double(curISO) * CMTimeGetSeconds(curDur)
    }

    /// Быстрая подстройка в начале: меряем яркость сырого подкадра и подбираем ISO за несколько шагов
    private func calibrate(_ pb: CVPixelBuffer) {
        if calibSkip > 0 {
            calibSkip -= 1
            return
        }
        let f = lightFactor(mean: meanLuma(pb), limit: 64)
        calibLeft -= 1
        if abs(f - 1) < 0.08 {
            calibLeft = 0
        } else {
            let r = setExposure(light: currentLight() * min(f, 16))
            if abs(r - 1) < 0.02 || calibLeft == 0 {
                calibLeft = 0
                // Сенсор на пределе: недостающий свет добавит цифровое усиление
                let rest = f / max(r, 0.0001)
                setAutoGain(rest > 1.08 ? Float(pow(rest, 1 / 2.2)) : 1)
            } else {
                calibSkip = 2
            }
        }
        if calibLeft == 0 {
            let isTest = mode == .test
            DispatchQueue.main.async {
                if self.phase == .recording { self.status = "Съёмка" }
                else if isTest { self.status = "Тестовый кадр..." }
            }
        }
    }

    /// После каждого кадра: плавная подстройка, не больше 1/3 EV за кадр, чтобы не было скачков яркости
    private func autoISOStep(mean: Float) {
        let f = lightFactor(mean: mean, limit: 1.26)
        guard abs(f - 1) > 0.02 else { return }
        if f < 1 && autoGain > 1 {
            // Слишком светло: сначала убираем цифровое усиление
            setAutoGain(autoGain * Float(pow(f, 1 / 2.2)))
            return
        }
        let r = setExposure(light: currentLight() * f)
        if abs(r - 1) > 0.005 { warmupLeft = max(warmupLeft, 1) }
        let rest = f / max(r, 0.0001)
        if rest > 1.02 { setAutoGain(autoGain * Float(pow(rest, 1 / 2.2))) }
    }

    private func setAutoGain(_ g: Float) {
        autoGain = min(max(g, 1), maxAutoGain)
        let v = autoGain
        DispatchQueue.main.async { self.autoGainShown = v }
    }

    // MARK: Обработка кадров (queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard mode != .off, !suspended, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if warmupLeft > 0 {
            warmupLeft -= 1
            return
        }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if inPause {
            if CMTimeGetSeconds(t - phaseStart) < cfg.pause + extraPause { return }
            inPause = false
        }
        if cfg.isoAuto && calibLeft > 0 {
            calibrate(pb)
            return
        }
        if subCount == 0 { accStart = t }
        accumulate(pb)
        subCount += 1
        // Кадр готов, когда набрана выдержка кадра (подкадры могут быть короче, если днём выдержка укорочена)
        let sub = CMTimeGetSeconds(curDur)
        let got = CMTimeGetSeconds(t - accStart) + sub
        let total = cfg.subNeeded
        let done = min(total, Int((got / max(cfg.exposure, 0.001) * Double(total)).rounded(.down)))
        DispatchQueue.main.async { self.subDone = done }
        guard got >= cfg.exposure - sub * 0.5 else { return }

        let n = subCount
        subCount = 0
        phaseStart = t
        let frame = renderFrame(count: n)
        var mean: Float = 0
        if cfg.isoAuto, let f = frame { mean = meanLuma(f) }

        if mode == .test {
            mode = .off
            DispatchQueue.main.async { self.applyCamera() }
            let img = frame.flatMap { makeThumb($0, maxSide: 2000) }
            let note = cfg.isoAuto ? "Тест готов. ISO подобран: \(Int(curISO))" : "Тест готов: проверь яркость и резкость"
            DispatchQueue.main.async {
                self.lastImage = img
                self.subDone = 0
                self.testCount += 1
                self.finished(note)
            }
            return
        }

        inPause = cfg.pause + extraPause > 0
        if let f = frame {
            writeFrame(f)
            if cfg.isoAuto { autoISOStep(mean: mean) }
        }
    }

    private func accumulate(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        let n = w * 4
        if w != width || h != height || acc.count != n * h {
            width = w
            height = h
            acc = [Float](repeating: 0, count: n * h)
            tmp = acc
            subCount = 0
        }
        let src = base.assumingMemoryBound(to: UInt8.self)
        tmp.withUnsafeMutableBufferPointer { t in
            guard let tp = t.baseAddress else { return }
            for y in 0..<h {
                vDSP_vfltu8(src + y * rb, 1, tp + y * n, 1, vDSP_Length(n))
            }
        }
        if subCount == 0 {
            acc = tmp
            return
        }
        let lighten = cfg.lighten
        acc.withUnsafeMutableBufferPointer { a in
            tmp.withUnsafeBufferPointer { t in
                guard let ap = a.baseAddress, let tp = t.baseAddress else { return }
                if lighten {
                    vDSP_vmax(ap, 1, tp, 1, ap, 1, vDSP_Length(a.count))
                } else {
                    vDSP_vadd(ap, 1, tp, 1, ap, 1, vDSP_Length(a.count))
                }
            }
        }
    }

    private func renderFrame(count n: Int) -> CVPixelBuffer? {
        guard width > 0, height > 0 else { return nil }
        var pbOut: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pbOut)
        guard let out = pbOut else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        guard let base = CVPixelBufferGetBaseAddress(out) else { return nil }
        let orb = CVPixelBufferGetBytesPerRow(out)
        let dst = base.assumingMemoryBound(to: UInt8.self)
        let rowN = width * 4
        let h = height
        let g = cfg.isoAuto ? autoGain : cfg.gain
        var s: Float = cfg.lighten ? g : g / Float(max(n, 1))
        var lo: Float = 0
        var hi: Float = 255
        acc.withUnsafeMutableBufferPointer { a in
            guard let p = a.baseAddress else { return }
            vDSP_vsmul(p, 1, &s, p, 1, vDSP_Length(a.count))
            vDSP_vclip(p, 1, &lo, &hi, p, 1, vDSP_Length(a.count))
            for y in 0..<h {
                vDSP_vfixru8(p + y * rowN, 1, dst + y * orb, 1, vDSP_Length(rowN))
            }
        }
        return out
    }

    private func writeFrame(_ out: CVPixelBuffer) {
        if cfg.saveVideo {
            if writer == nil { setupWriter() }
            if let input = writerInput, let ad = adaptor {
                var tries = 0
                while !input.isReadyForMoreMediaData && tries < 300 {
                    usleep(10_000)
                    tries += 1
                }
                if input.isReadyForMoreMediaData {
                    ad.append(out, withPresentationTime: CMTime(value: videoIndex, timescale: cfg.fps))
                    videoIndex += 1
                }
            }
        }

        if cfg.saveFrames {
            if framesDir == nil {
                let dir = Self.docs().appendingPathComponent(cfg.name + "_frames", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                framesDir = dir
            }
            if let dir = framesDir, let cs = CGColorSpace(name: CGColorSpace.sRGB) {
                var img = CIImage(cvPixelBuffer: out)
                if cfg.vertical { img = img.oriented(.right) }
                let url = dir.appendingPathComponent(String(format: "frame_%05d.jpg", outIndex + 1))
                let q = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                try? ci.writeJPEGRepresentation(of: img, to: url, colorSpace: cs, options: [q: 0.95])
            }
        }

        outIndex += 1
        let c = outIndex
        let thumb = makeThumb(out, maxSide: 900)
        DispatchQueue.main.async {
            self.framesDone = c
            if let t = thumb { self.lastImage = t }
        }
    }

    private func makeThumb(_ pb: CVPixelBuffer, maxSide: CGFloat) -> UIImage? {
        var img = CIImage(cvPixelBuffer: pb)
        let s = maxSide / max(img.extent.width, img.extent.height)
        if s < 1 { img = img.transformed(by: CGAffineTransform(scaleX: s, y: s)) }
        if cfg.vertical { img = img.oriented(.right) }
        guard let cg = ci.createCGImage(img, from: img.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func setupWriter() {
        let url = Self.docs().appendingPathComponent(cfg.name + ".mov")
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        // Видео пишется кусками: если приложение вылетит, снятое не пропадёт целиком
        w.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 6]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        if cfg.vertical { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        guard w.canAdd(input) else { return }
        w.add(input)
        guard w.startWriting() else { return }
        w.startSession(atSourceTime: .zero)
        writer = w
        writerInput = input
        adaptor = ad
        videoURL = url
    }

    private func finishOnQueue() {
        mode = .off
        DispatchQueue.main.async { self.applyCamera() }
        suspended = false
        let frames = outIndex
        let framesSaved = framesDir != nil
        guard let w = writer, let url = videoURL, videoIndex > 0 else {
            writer = nil
            DispatchQueue.main.async {
                if frames == 0 { self.finished("Ни одного кадра не снято") }
                else { self.finished(framesSaved ? "Кадры сохранены: Файлы → На iPhone → NightLapse" : "Готово") }
            }
            return
        }
        writerInput?.markAsFinished()
        writer = nil
        writerInput = nil
        adaptor = nil
        w.finishWriting {
            guard w.status == .completed else {
                DispatchQueue.main.async { self.finished("Ошибка записи видео. Проверь Файлы → NightLapse") }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, _ in
                if ok { try? FileManager.default.removeItem(at: url) }
                DispatchQueue.main.async {
                    self.finished(ok ? "Видео сохранено в Фото" : "Нет доступа к Фото. Видео лежит в Файлы → NightLapse")
                }
            }
        }
    }
}


// MARK: - Превью камеры

struct CameraPreview: UIViewRepresentable {
    let engine: LapseEngine
    /// Точка для камеры и точка на экране
    let onTap: (CGPoint, CGPoint) -> Void
    /// Вертикальный сдвиг пальца (в точках) с прошлого вызова
    let onPan: (CGFloat) -> Void

    final class PView: UIView {
        var onTap: ((CGPoint, CGPoint) -> Void)?
        var onPan: ((CGFloat) -> Void)?
        private var lastY: CGFloat = 0
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var pl: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.maximumNumberOfTouches = 1
            addGestureRecognizer(pan)
        }

        @objc func panned(_ g: UIPanGestureRecognizer) {
            let y = g.translation(in: self).y
            switch g.state {
            case .began: lastY = y
            case .changed:
                onPan?(y - lastY)
                lastY = y
            default: break
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            let v = g.location(in: self)
            onTap?(pl.captureDevicePointConverted(fromLayerPoint: v), v)
        }
    }

    func makeUIView(context: Context) -> PView {
        let v = PView()
        v.pl.session = engine.session
        v.pl.videoGravity = .resizeAspect
        v.backgroundColor = .black
        v.onTap = onTap
        v.onPan = onPan
        let e = engine
        DispatchQueue.main.async { e.attachPreview(v.pl) }
        return v
    }

    func updateUIView(_ uiView: PView, context: Context) {
        uiView.onTap = onTap
        uiView.onPan = onPan
    }
}

// MARK: - Главный экран

struct ContentView: View {
    var onSwitch: () -> Void = {}
    @StateObject private var e = LapseEngine()
    @State private var dark = false
    @State private var showTest = false
    @State private var showSettings = false
    @State private var focusMark: CGPoint?
    @State private var markTick = 0

    private var idle: Bool { e.phase == .idle }
    private var shooting: Bool {
        e.phase == .recording || e.phase == .paused || e.phase == .saving || e.phase == .waiting
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if landscape {
                    HStack(spacing: 12) {
                        previewBox(height: nil)
                        VStack(spacing: 10) {
                            header
                            ScrollView { controls }
                            buttons
                        }
                        .frame(width: min(400, geo.size.width * 0.45))
                    }
                    .padding(8)
                } else {
                    VStack(spacing: 10) {
                        header
                        previewBox(height: e.captureLandscape ? 230 : 380)
                        ScrollView { controls }
                        buttons
                    }
                    .padding(.horizontal, 12)
                }
                if dark { darkOverlay }
            }
        }
        .onAppear { e.configure() }
        .onDisappear { e.shutdown() }
        .onChange(of: e.testCount) { showTest = true }
        .onChange(of: e.zoom) { e.changeCamera() }
        .onChange(of: e.uhd) { e.changeCamera() }
        .onChange(of: e.focusAuto) { e.focusModeChanged() }
        .onChange(of: e.wbAuto) { e.applyCamera() }
        .onChange(of: e.evComp) { e.applyCamera() }
        .sheet(isPresented: $showTest) { testSheet }
    }

    // MARK: Верх

    private var header: some View {
        HStack {
            Text("Найтлапс").font(.title2.bold())
            Spacer()
            Button { onSwitch() } label: {
                Label("Кадр дня", systemImage: "photo.on.rectangle.angled")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(Color.orange)
            }
            .disabled(!idle)
        }
        .padding(.top, 4)
    }

    // MARK: Картинка

    private func previewBox(height: CGFloat?) -> some View {
        ZStack {
            CameraPreview(engine: e,
                          onTap: { dp, vp in
                              guard idle else { return }
                              e.focusAt(dp)
                              focusMark = vp
                              keepMark()
                          },
                          onPan: { dy in
                              guard idle else { return }
                              e.nudgeBrightness(Double(-dy) / 120)
                              keepMark()
                          })
            if let m = focusMark { focusIndicator(at: m) }
            VStack {
                HStack {
                    infoChip
                    Spacer()
                    orientationChip
                }
                Spacer()
                HStack(alignment: .bottom) {
                    if shooting { recordingInfo }
                    Spacer()
                    thumb
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(height: height)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// Жёлтая рамка фокуса и солнце яркости, как в Камере iPhone
    private func focusIndicator(at m: CGPoint) -> some View {
        GeometryReader { _ in
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.yellow, lineWidth: 1.5)
                    .frame(width: 72, height: 72)
                    .position(m)
                VStack(spacing: 2) {
                    Image(systemName: "sun.max.fill")
                    Text(String(format: "%+.1f", e.evComp)).font(.caption2.monospacedDigit())
                }
                .foregroundStyle(Color.yellow)
                .position(x: m.x + 58, y: m.y)
            }
        }
        .allowsHitTesting(false)
    }

    /// Рамка видна 3 с после последнего касания или движения пальцем
    private func keepMark() {
        markTick += 1
        let t = markTick
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if markTick == t { focusMark = nil }
        }
    }

    private var infoChip: some View {
        HStack(spacing: 8) {
            Label(e.battery >= 0 ? "\(e.battery)%" : "-", systemImage: "battery.100")
            Label(String(format: "%.0f ГБ", e.freeGB), systemImage: "internaldrive")
            if e.hot {
                Image(systemName: "thermometer.high").foregroundStyle(Color.orange)
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55), in: Capsule())
    }

    private var orientationChip: some View {
        Label(e.captureLandscape ? "Горизонтально" : "Вертикально",
              systemImage: e.captureLandscape ? "rectangle" : "rectangle.portrait")
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.55), in: Capsule())
    }

    private var recordingInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(e.framesDone) кадров").font(.headline.monospacedDigit())
            Text("\(hms(e.elapsed)) · видео \(String(format: "%.1f", Double(e.framesDone) / Double(max(e.fps, 1)))) с")
                .font(.caption.monospacedDigit())
        }
        .padding(8)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var thumb: some View {
        if let img = e.lastImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 90, maxHeight: 90)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.4)))
                .onTapGesture { showTest = true }
        }
    }

    // MARK: Управление

    private var controls: some View {
        VStack(spacing: 12) {
            statusView
            if shooting {
                card("Идёт съёмка") {
                    Text("Не двигай телефон. Чтобы экран не светил, нажми луну внизу. Остановить можно кнопкой «Стоп»")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                sceneCard
                mainCard
                if showSettings { SettingsPanel(e: e) }
            }
        }
        .padding(.bottom, 8)
    }

    private var statusView: some View {
        VStack(spacing: 6) {
            if e.phase == .recording || e.phase == .test {
                ProgressView(value: Double(min(e.subDone, e.subTotal)), total: Double(max(e.subTotal, 1)))
            }
            Text(statusLine)
                .font(.footnote)
                .foregroundStyle(e.hot ? Color.orange : Color.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var statusLine: String {
        var s = e.phase == .waiting ? "Старт через \(hms(e.countdown))" : e.status
        if e.pauses > 0 && (e.phase == .recording || e.phase == .paused) { s += " · пауз: \(e.pauses)" }
        if e.cooling && (e.phase == .recording || e.phase == .paused) { s += " · пауза +\(Int(e.coolExtra)) с от нагрева" }
        if e.hot { s += " · телефон перегрет" }
        return s
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 14))
    }

    private var sceneCard: some View {
        card("Что снимаем") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(LapseScene.allCases) { sc in
                    Button { e.applyScene(sc) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: sc.icon).frame(width: 22)
                            Text(sc.title).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .background(e.scene == sc.rawValue ? Color.red.opacity(0.4) : Color.white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(LapseScene(rawValue: e.scene)?.hint ?? "Выбери, что снимаешь, и настройки выставятся сами. Потом их можно подправить ниже")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var mainCard: some View {
        card("Основное") {
            Picker("Зум", selection: $e.zoom) {
                ForEach(e.zoomOptions) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.segmented)
            Stepper(onIncrement: { e.exposureUp() }, onDecrement: { e.exposureDown() }) {
                row("Выдержка кадра", expText(e.exposureSeconds))
            }
            Stepper(value: $e.pauseSeconds, in: 0...60, step: 1) {
                row("Пауза", "\(Int(e.pauseSeconds)) с")
            }
            HStack {
                Text("Длительность")
                Spacer()
                Picker("Длительность", selection: $e.autoStopMin) {
                    Text("Пока не остановлю").tag(0)
                    Text("30 мин").tag(30)
                    Text("1 ч").tag(60)
                    Text("2 ч").tag(120)
                    Text("4 ч").tag(240)
                    Text("8 ч").tag(480)
                }
                .pickerStyle(.menu)
            }
            Text(planLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Коснись кадра, чтобы навести фокус и яркость. Веди пальцем вверх или вниз - ярче или темнее")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button { withAnimation { showSettings.toggle() } } label: {
                HStack {
                    Label("Все настройки", systemImage: "slider.horizontal.3")
                    Spacer()
                    Image(systemName: showSettings ? "chevron.up" : "chevron.down")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var planLine: String {
        let interval = max(e.exposureSeconds + e.pauseSeconds, 0.01)
        let fps = Double(max(e.fps, 1))
        let framesPerHour = 3600 / interval
        let videoPerHour = framesPerHour / fps
        // Сколько снимать ради 10 секунд видео
        let shootFor10 = 10 * fps * interval
        var s = "Снимок каждые \(expText(interval)), \(Int(framesPerHour.rounded())) кадров в час\n"
        s += "1 час съёмки = \(String(format: "%.1f", videoPerHour)) с видео\n"
        s += "10 с видео = \(durText(shootFor10)) съёмки"
        if e.autoStopMin > 0 {
            let total = videoPerHour * Double(e.autoStopMin) / 60
            s += "\nЗа \(durText(Double(e.autoStopMin) * 60)) получится \(String(format: "%.1f", total)) с видео"
        }
        return s
    }

    /// 45 мин, 3 ч 28 мин
    private func durText(_ sec: Double) -> String {
        let m = Int((sec / 60).rounded())
        if m < 1 { return "\(Int(sec.rounded())) с" }
        if m < 60 { return "\(m) мин" }
        return m % 60 == 0 ? "\(m / 60) ч" : "\(m / 60) ч \(m % 60) мин"
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            switch e.phase {
            case .idle:
                Button { e.testFrame() } label: {
                    Label("Тест", systemImage: "camera.aperture").lineLimit(1).fixedSize()
                }
                .buttonStyle(.bordered)
                Button { e.start() } label: {
                    Label("Старт", systemImage: "record.circle").lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .test, .waiting:
                Button { e.cancel() } label: {
                    Text("Отмена").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            case .recording, .paused:
                Button { e.stop() } label: {
                    Label("Стоп", systemImage: "stop.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .saving:
                ProgressView().frame(maxWidth: .infinity)
            }
            Button { dark = true } label: {
                Image(systemName: "moon.fill")
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .padding(.bottom, 8)
    }

    // MARK: Затемнение и тест

    private var darkOverlay: some View {
        Color.black
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 6) {
                    Text("\(e.framesDone) кадров · \(hms(e.elapsed))")
                    Text(e.status)
                    Text("Коснись, чтобы вернуться")
                }
                .font(.footnote)
                .foregroundStyle(Color.red.opacity(0.35))
            }
            .onTapGesture { dark = false }
    }

    private var testSheet: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let img = e.lastImage {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                Text("Пока нет кадра").foregroundStyle(.secondary)
            }
        }
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Все настройки (раскрываются под основными, кадр остаётся на экране)

struct SettingsPanel: View {
    @ObservedObject var e: LapseEngine

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 14))
    }

    private func note(_ t: String) -> some View {
        Text(t).font(.caption).foregroundStyle(.secondary)
    }

    var body: some View {
        VStack(spacing: 12) {
            card("Камера") {
                Toggle("4K (выкл. = 1080p)", isOn: $e.uhd)
                Toggle("Автофокус", isOn: $e.focusAuto)
                if e.focusAuto {
                    note("Камера сама держит фокус. В темноте автофокус часто промахивается")
                } else {
                    VStack(alignment: .leading) {
                        Text(e.focus >= 0.99 ? "Фокус: бесконечность" : String(format: "Фокус: %.0f%%", e.focus * 100))
                        Slider(value: $e.focus, in: 0...1, onEditingChanged: { editing in if !editing { e.applyCamera() } })
                    }
                }
                note("Видео будет горизонтальным или вертикальным - так, как держишь телефон в момент старта")
            }

            card("Яркость и цвет") {
                Toggle("Авто ISO", isOn: $e.isoAuto)
                if e.isoAuto {
                    VStack(alignment: .leading) {
                        Text("Яркость: \(String(format: "%+.1f", e.evComp)) EV")
                        Slider(value: $e.evComp, in: -4...2, step: 0.1)
                    }
                    note("Минус - темнее и меньше шума. ISO сейчас: \(Int(e.iso))" + (e.autoGainShown > 1.05 ? String(format: ", + усиление x%.1f", e.autoGainShown) : ""))
                } else {
                    VStack(alignment: .leading) {
                        Text("ISO: \(Int(e.iso))")
                        Slider(value: $e.iso, in: e.minISO...max(e.maxISO, e.minISO + 1),
                               onEditingChanged: { editing in if !editing { e.applyCamera() } })
                    }
                    VStack(alignment: .leading) {
                        Text("Усиление: x\(String(format: "%.2g", e.gain))")
                        Slider(value: $e.gain, in: 0.25...8, step: 0.25)
                    }
                }
                Toggle("Авто баланс белого", isOn: $e.wbAuto)
                if !e.wbAuto {
                    VStack(alignment: .leading) {
                        Text("Баланс белого: \(Int(e.wbTemp)) K")
                        Slider(value: $e.wbTemp, in: 2500...7500, step: 100,
                               onEditingChanged: { editing in if !editing { e.applyCamera() } })
                    }
                }
                Picker("Склейка", selection: $e.lighten) {
                    Text("Среднее").tag(false)
                    Text("Треки").tag(true)
                }
                .pickerStyle(.segmented)
                note(e.lighten ? "Шлейфы огней и звёзд" : "Меньше шума, мягкие облака и вода")
            }

            card("Старт и сохранение") {
                HStack {
                    Text("Задержка старта")
                    Spacer()
                    Picker("Задержка старта", selection: $e.startDelayMin) {
                        Text("Нет").tag(0)
                        Text("1 мин").tag(1)
                        Text("5 мин").tag(5)
                        Text("15 мин").tag(15)
                        Text("30 мин").tag(30)
                        Text("1 ч").tag(60)
                    }
                    .pickerStyle(.menu)
                }
                Toggle("Видео в Фото", isOn: $e.saveVideo)
                HStack {
                    Text("Кадров в секунду")
                    Spacer()
                    Picker("Кадров в секунду", selection: $e.fps) {
                        Text("24").tag(24)
                        Text("25").tag(25)
                        Text("30").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                Toggle("Кадры JPEG в Файлы", isOn: $e.saveFrames)
                Toggle("Длиннее пауза при перегреве", isOn: $e.coolBreaks)
                note("Если телефон сильно нагреется, к паузе между кадрами добавится время, пока не остынет. Потом пауза снова станет твоей. Съёмка не прерывается")
            }
        }
    }
}
