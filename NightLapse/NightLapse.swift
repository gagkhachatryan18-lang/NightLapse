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

enum Phase { case idle, test, waiting, recording, paused, saving }

struct LapseConfig {
    var subNeeded = 30
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
    static let exposureSteps: [Double] = [1.0 / 30, 1.0 / 15, 1.0 / 8, 1.0 / 4, 1.0 / 2] + (1...120).map { Double($0) }
    @Published var exposureSeconds: Double

    // Остальные настройки запоминаются между запусками
    @Published var pauseSeconds: Double { didSet { ud.set(pauseSeconds, forKey: "pause") } }
    @Published var iso: Float { didSet { ud.set(iso, forKey: "iso") } }
    @Published var wbTemp: Float { didSet { ud.set(wbTemp, forKey: "wb") } }
    @Published var focus: Float { didSet { ud.set(focus, forKey: "focus") } }
    @Published var gain: Float { didSet { ud.set(gain, forKey: "gain") } }
    @Published var lighten: Bool { didSet { ud.set(lighten, forKey: "lighten") } }
    @Published var fps: Int { didSet { ud.set(fps, forKey: "fps") } }
    @Published var vertical: Bool { didSet { ud.set(vertical, forKey: "vertical") } }
    @Published var saveVideo: Bool { didSet { ud.set(saveVideo, forKey: "saveVideo") } }
    @Published var saveFrames: Bool { didSet { ud.set(saveFrames, forKey: "saveFrames") } }
    @Published var lens: LensKind { didSet { ud.set(lens.rawValue, forKey: "lens") } }
    @Published var uhd: Bool { didSet { ud.set(uhd, forKey: "uhd") } }
    @Published var startDelayMin: Int { didSet { ud.set(startDelayMin, forKey: "delay") } }
    @Published var autoStopMin: Int { didSet { ud.set(autoStopMin, forKey: "autostop") } }
    @Published var isoAuto: Bool { didSet { ud.set(isoAuto, forKey: "isoAuto") } }
    @Published var wbAuto: Bool { didSet { ud.set(wbAuto, forKey: "wbAuto") } }
    @Published var focusAuto: Bool { didSet { ud.set(focusAuto, forKey: "focusAuto") } }
    @Published var evComp: Double { didSet { ud.set(evComp, forKey: "ev") } }

    // Возможности камеры
    @Published var availableLenses: [LensKind] = [.wide]
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
    private var inPause = false
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
        lens = LensKind(rawValue: d.string(forKey: "lens") ?? "") ?? .wide
        uhd = d.flag("uhd", true)
        startDelayMin = d.num("delay", 0)
        autoStopMin = d.num("autostop", 0)
        isoAuto = d.flag("isoAuto", true)
        wbAuto = d.flag("wbAuto", false)
        focusAuto = d.flag("focusAuto", false)
        evComp = d.dbl("ev", -2)
        super.init()

        let ds = AVCaptureDevice.DiscoverySession(
            deviceTypes: LensKind.allCases.map { $0.deviceType }, mediaType: .video, position: .back)
        let found = LensKind.allCases.filter { k in ds.devices.contains { $0.deviceType == k.deviceType } }
        availableLenses = found.isEmpty ? [.wide] : found
        if !availableLenses.contains(lens) { lens = .wide }

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
        CamSettings(dur: exposureSeconds, iso: iso, temp: wbTemp, focus: focus, wbAuto: wbAuto, focusAuto: focusAuto)
    }

    func changeCamera() {
        guard phase == .idle else { return }
        let l = lens, u = uhd, s = currentSettings()
        queue.async { self.reconfigure(lens: l, uhd: u, settings: s) }
    }

    func applyCamera(forceFocus: Bool = false) {
        let s = currentSettings()
        queue.async { self.applyOnQueue(s, forceFocus: forceFocus) }
    }

    /// Переключение авто / ручной фокус: при переходе на ручной берём текущее положение линзы
    func focusModeChanged() {
        if !focusAuto, let dev = device {
            focus = min(max(dev.lensPosition, 0), 1)
        }
        applyCamera()
    }

    /// Фокус по касанию картинки (только в автофокусе и до старта)
    func focusAt(_ p: CGPoint) {
        guard focusAuto, phase == .idle else { return }
        queue.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            defer { dev.unlockForConfiguration() }
            if dev.isFocusPointOfInterestSupported { dev.focusPointOfInterest = p }
            if dev.isFocusModeSupported(.autoFocus) { dev.focusMode = .autoFocus }
            self.appliedFocusAuto = true
        }
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
        applyCamera(forceFocus: focusAuto)
        queue.async {
            self.cfg = c
            self.curISO = c.iso
            self.subCount = 0
            self.inPause = false
            self.suspended = false
            self.warmupLeft = c.warmup
            self.calibLeft = c.isoAuto ? 4 : 0
            self.calibSkip = 0
            self.mode = .test
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
        let now = Date()
        recStart = now
        autoStopAt = autoStopMin > 0 ? now.addingTimeInterval(Double(autoStopMin) * 60) : nil
        phase = .recording
        status = c.isoAuto ? "Подбор ISO..." : "Съёмка"
        UIApplication.shared.isIdleTimerDisabled = true
        applyCamera(forceFocus: focusAuto)
        queue.async {
            self.cfg = c
            self.curISO = c.iso
            self.subCount = 0
            self.inPause = false
            self.suspended = false
            self.warmupLeft = c.warmup
            self.calibLeft = c.isoAuto ? 4 : 0
            self.calibSkip = 0
            self.writer = nil
            self.framesDir = nil
            self.videoIndex = 0
            self.outIndex = 0
            self.mode = .record
        }
    }

    func stop() {
        guard phase == .recording || phase == .paused else { return }
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
            queue.async { self.mode = .off }
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
        LapseConfig(subNeeded: subFramesPerFrame, pause: pauseSeconds, lighten: lighten,
                    gain: isoAuto ? 1 : gain, fps: Int32(fps), vertical: vertical,
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
        if tickCount % 10 == 0 { updateFree() }
        tickCount += 1
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

    private func reconfigure(lens: LensKind, uhd: Bool, settings: CamSettings) {
        guard let dev = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back)
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
        }
    }

    /// Ручная выдержка (максимум сенсора), ISO, фокус и баланс белого (ручной или авто)
    private func applyOnQueue(_ s: CamSettings, forceFocus: Bool = false) {
        guard let dev = device, (try? dev.lockForConfiguration()) != nil else { return }
        defer { dev.unlockForConfiguration() }
        let fmt = dev.activeFormat

        // Выдержка сенсора: максимум формата, или короче, если выдержка кадра меньше секунды
        let lo = CMTimeGetSeconds(fmt.minExposureDuration)
        let hi = CMTimeGetSeconds(fmt.maxExposureDuration)
        let dur = CMTime(seconds: min(max(s.dur, lo), hi), preferredTimescale: 1_000_000)
        curDur = dur
        if dev.isExposureModeSupported(.custom) {
            dev.setExposureModeCustom(duration: dur,
                                      iso: min(max(s.iso, fmt.minISO), fmt.maxISO),
                                      completionHandler: nil)
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

    /// Целевая яркость: 118 (средне-серый) со сдвигом на коррекцию в EV. Связь ISO и яркости считаем в линейном свете (гамма 2.2)
    private func nextISO(mean: Float, limit: Double) -> (iso: Float, factor: Double) {
        guard let dev = device else { return (curISO, 1) }
        let target = 118.0 * pow(pow(2.0, Double(cfg.ev)), 1.0 / 2.2)
        var f = pow(target / max(Double(mean), 1.0), 2.2)
        f = min(max(f, 1.0 / limit), limit)
        let fmt = dev.activeFormat
        let cur = max(curISO, 1)
        let n = min(max(Float(Double(cur) * f), fmt.minISO), fmt.maxISO)
        return (n, Double(n / cur))
    }

    private func applyISO(_ v: Float) {
        curISO = v
        if let dev = device, (try? dev.lockForConfiguration()) != nil {
            if dev.isExposureModeSupported(.custom) {
                dev.setExposureModeCustom(duration: curDur, iso: v, completionHandler: nil)
            }
            dev.unlockForConfiguration()
        }
        DispatchQueue.main.async { self.iso = v }
    }

    /// Быстрая подстройка в начале: меряем яркость сырого подкадра и подбираем ISO за несколько шагов
    private func calibrate(_ pb: CVPixelBuffer) {
        if calibSkip > 0 {
            calibSkip -= 1
            return
        }
        let r = nextISO(mean: meanLuma(pb), limit: 16)
        calibLeft -= 1
        if abs(r.factor - 1) < 0.08 {
            calibLeft = 0
        } else {
            applyISO(r.iso)
            calibSkip = 2
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
        let r = nextISO(mean: mean, limit: 1.26)
        if abs(r.factor - 1) > 0.02 {
            applyISO(r.iso)
            warmupLeft = max(warmupLeft, 1)
        }
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
            if CMTimeGetSeconds(t - phaseStart) < cfg.pause { return }
            inPause = false
        }
        if cfg.isoAuto && calibLeft > 0 {
            calibrate(pb)
            return
        }
        accumulate(pb)
        subCount += 1
        let sc = subCount
        DispatchQueue.main.async { self.subDone = sc }
        guard subCount >= cfg.subNeeded else { return }

        let n = subCount
        subCount = 0
        phaseStart = t
        let frame = renderFrame(count: n)
        var mean: Float = 0
        if cfg.isoAuto, let f = frame { mean = meanLuma(f) }

        if mode == .test {
            mode = .off
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

        inPause = cfg.pause > 0
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
        if acc.count != n * h {
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
        var s: Float = cfg.lighten ? cfg.gain : cfg.gain / Float(max(n, 1))
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
    let session: AVCaptureSession
    let vertical: Bool
    let onTap: (CGPoint) -> Void

    final class PView: UIView {
        var onTap: ((CGPoint) -> Void)?
        var angle: CGFloat = 0
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var pl: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            let p = pl.captureDevicePointConverted(fromLayerPoint: g.location(in: self))
            onTap?(p)
        }

        /// Картинка в превью повёрнута так же, как будет записано видео
        func fixRotation() {
            if let c = pl.connection, c.isVideoRotationAngleSupported(angle), c.videoRotationAngle != angle {
                c.videoRotationAngle = angle
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            fixRotation()
        }
    }

    func makeUIView(context: Context) -> PView {
        let v = PView()
        v.pl.session = session
        v.pl.videoGravity = .resizeAspect
        v.backgroundColor = .black
        v.angle = vertical ? 90 : 0
        v.onTap = onTap
        return v
    }

    func updateUIView(_ uiView: PView, context: Context) {
        uiView.onTap = onTap
        uiView.angle = vertical ? 90 : 0
        uiView.fixRotation()
    }
}

// MARK: - Интерфейс

struct ContentView: View {
    var onSwitch: () -> Void = {}
    @StateObject private var e = LapseEngine()
    @State private var dark = false
    @State private var showTest = false

    private var idle: Bool { e.phase == .idle }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                preview
                statusBar
                settings
                buttons
            }
            if dark { darkOverlay }
        }
        .onAppear { e.configure() }
        .onDisappear { e.shutdown() }
        .onChange(of: e.testCount) { showTest = true }
        .onChange(of: e.lens) { e.changeCamera() }
        .onChange(of: e.uhd) { e.changeCamera() }
        .onChange(of: e.focusAuto) { e.focusModeChanged() }
        .onChange(of: e.wbAuto) { e.applyCamera() }
        .sheet(isPresented: $showTest) { testSheet }
    }

    private var preview: some View {
        ZStack(alignment: .bottomTrailing) {
            CameraPreview(session: e.session, vertical: e.vertical, onTap: { e.focusAt($0) })
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if let img = e.lastImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.3)))
                    .padding(6)
                    .onTapGesture { showTest = true }
            }
        }
        .padding(.horizontal)
    }

    private var statusBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Label(hms(e.elapsed), systemImage: "timer")
                Label("\(e.framesDone)", systemImage: "photo.stack")
                Label(String(format: "%.1f с", Double(e.framesDone) / Double(max(e.fps, 1))), systemImage: "film")
                Label(e.battery >= 0 ? "\(e.battery)%" : "-", systemImage: "battery.100")
                Label(String(format: "%.0f ГБ", e.freeGB), systemImage: "internaldrive")
            }
            .font(.caption.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if e.phase == .recording || e.phase == .test {
                ProgressView(value: Double(min(e.subDone, e.subTotal)), total: Double(max(e.subTotal, 1)))
            }
            Text(statusLine)
                .font(.footnote)
                .foregroundStyle(e.hot ? Color.orange : Color.secondary)
        }
        .padding(.horizontal)
    }

    private var statusLine: String {
        var s = e.phase == .waiting ? "Старт через \(hms(e.countdown))" : e.status
        if e.pauses > 0 && (e.phase == .recording || e.phase == .paused) { s += " · пауз: \(e.pauses)" }
        if e.hot { s += " · телефон перегрет" }
        return s
    }

    private var planLine: String {
        let interval = e.exposureSeconds + e.pauseSeconds
        let minutes = Double(e.fps * 10) * interval / 60
        let every = interval < 10 ? String(format: "%.1f с", interval) : "\(Int(interval)) с"
        return "Кадр каждые \(every) · 10 с видео ≈ \(String(format: minutes < 10 ? "%.1f" : "%.0f", minutes)) мин съёмки"
    }

    /// 1/8 с, 0.5 с, 17 с
    private func expText(_ v: Double) -> String {
        if v >= 1 { return v == v.rounded() ? "\(Int(v)) с" : String(format: "%.1f с", v) }
        let d = (1 / v).rounded()
        if abs(1 / d - v) < 0.0005 { return "1/\(Int(d)) с" }
        return String(format: "%.3f с", v)
    }

    private var settings: some View {
        Form {
            Section("Камера") {
                Picker("Объектив", selection: $e.lens) {
                    ForEach(e.availableLenses) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("4K (выкл. = 1080p)", isOn: $e.uhd)
                Toggle("Автофокус", isOn: $e.focusAuto)
                if e.focusAuto {
                    Text("Коснись картинки, чтобы навести фокус. Дальше он фиксируется. В темноте автофокус часто промахивается")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading) {
                        Text(e.focus >= 0.99 ? "Фокус: бесконечность" : String(format: "Фокус: %.0f%%", e.focus * 100))
                        Slider(value: $e.focus, in: 0...1, onEditingChanged: { editing in if !editing { e.applyCamera() } })
                    }
                }
            }

            Section("Экспозиция") {
                Stepper("Выдержка кадра: \(expText(e.exposureSeconds))",
                        onIncrement: { e.exposureUp() }, onDecrement: { e.exposureDown() })
                Text("Сенсор \(expText(e.sensorExposure)) × \(e.subFramesPerFrame) подкадров")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Авто ISO", isOn: $e.isoAuto)
                if e.isoAuto {
                    VStack(alignment: .leading) {
                        Text("Коррекция: \(String(format: "%+.1f", e.evComp)) EV")
                        Slider(value: $e.evComp, in: -4...1, step: 0.5)
                    }
                    Text("ISO сейчас: \(Int(e.iso)). Подбирается сам и меняется плавно")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading) {
                        Text("ISO: \(Int(e.iso))")
                        Slider(value: $e.iso, in: e.minISO...max(e.maxISO, e.minISO + 1),
                               onEditingChanged: { editing in if !editing { e.applyCamera() } })
                    }
                    VStack(alignment: .leading) {
                        Text("Яркость: x\(String(format: "%.2g", e.gain))")
                        Slider(value: $e.gain, in: 0.25...8, step: 0.25)
                    }
                }
                Toggle("Авто баланс белого", isOn: $e.wbAuto)
                if e.wbAuto {
                    Text("В авто цвет может слегка мерцать между кадрами")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading) {
                        Text("Баланс белого: \(Int(e.wbTemp)) K")
                        Slider(value: $e.wbTemp, in: 2500...7500, step: 100,
                               onEditingChanged: { editing in if !editing { e.applyCamera() } })
                    }
                }
                Picker("Режим", selection: $e.lighten) {
                    Text("Среднее").tag(false)
                    Text("Треки").tag(true)
                }
                .pickerStyle(.segmented)
                Text(e.lighten ? "Шлейфы огней и звёзд" : "Меньше шума, мягкие облака и вода")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Интервал") {
                Stepper("Пауза: \(Int(e.pauseSeconds)) с", value: $e.pauseSeconds, in: 0...60, step: 1)
                Picker("Задержка старта", selection: $e.startDelayMin) {
                    Text("Нет").tag(0)
                    Text("1 мин").tag(1)
                    Text("5 мин").tag(5)
                    Text("15 мин").tag(15)
                    Text("30 мин").tag(30)
                    Text("1 ч").tag(60)
                }
                Picker("Автостоп", selection: $e.autoStopMin) {
                    Text("Нет").tag(0)
                    Text("30 мин").tag(30)
                    Text("1 ч").tag(60)
                    Text("2 ч").tag(120)
                    Text("4 ч").tag(240)
                    Text("8 ч").tag(480)
                }
                Text(planLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Сохранение") {
                Toggle("Видео в Фото", isOn: $e.saveVideo)
                Picker("Кадров в секунду", selection: $e.fps) {
                    Text("24").tag(24)
                    Text("25").tag(25)
                    Text("30").tag(30)
                }
                .pickerStyle(.segmented)
                Toggle("Вертикальное видео", isOn: $e.vertical)
                Toggle("Кадры JPEG в Файлы", isOn: $e.saveFrames)
            }
        }
        .scrollContentBackground(.hidden)
        .disabled(!idle)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            switch e.phase {
            case .idle:
                Button { onSwitch() } label: {
                    Label("Кадр дня", systemImage: "photo.on.rectangle.angled")
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                Button { e.testFrame() } label: {
                    Label("Тест", systemImage: "camera.aperture")
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.bordered)
                Button { e.start() } label: {
                    Label("Старт", systemImage: "record.circle")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
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
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

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
