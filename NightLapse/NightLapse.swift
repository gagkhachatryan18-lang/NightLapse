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
                    RootView(onSwitch: { switchTo(.night) }, onScene: { sc in
                        UserDefaults.standard.set(sc.rawValue, forKey: "pendingScene")
                        switchTo(.night)
                    })
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

/// Режимы съёмки, как режимы в Камере iPhone: всё остальное выставляется само
enum LapseScene: String, CaseIterable, Identifiable {
    case stars, trails, city, clouds
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stars: return "Звёзды"
        case .trails: return "Треки"
        case .city: return "Город"
        case .clouds: return "Облака"
        }
    }
    var hint: String {
        switch self {
        case .stars: return "Звёзды точками: выдержка сама подбирается под объектив"
        case .trails: return "Звёзды и огни рисуют длинные линии"
        case .city: return "Шлейфы фар и огни города"
        case .clouds: return "Закат, облака, день. Выдержка сама укоротится, если светло"
        }
    }
    /// Снимок каждые N секунд по умолчанию
    var interval: Double {
        switch self {
        case .stars: return 10
        case .trails: return 30
        case .city: return 5
        case .clouds: return 5
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
    var autoShutter = true
    var ev: Float = -2
    var iso: Float = 800
    var scene = ""
    var interval = 0.0
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

private enum Mode { case off, test, record, focus }

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
    /// Снимок каждые N секунд. Выдержка и пауза считаются из него сами
    @Published var intervalSeconds: Double { didSet { ud.set(intervalSeconds, forKey: "interval") } }
    static let intervalSteps: [Double] = [1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 30, 40, 50, 60, 90, 120]

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
    /// Умная выдержка: светлеет - выдержка кадра сама укорачивается, интервал между снимками тот же
    @Published var autoShutter: Bool { didSet { ud.set(autoShutter, forKey: "autoShutter") } }
    /// Выдержка кадра, которая реально используется сейчас
    @Published var effExposure: Double = 0
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
    /// Папка с кадрами последней законченной съёмки: после «Стоп» открывается редактор
    @Published var lastShoot: URL?

    var subFramesPerFrame: Int { max(1, Int((exposureSeconds / max(sensorExposure, 0.0001)).rounded())) }

    var sceneKind: LapseScene { LapseScene(rawValue: scene) ?? .stars }

    /// Самая длинная выдержка, при которой звёзды ещё точки (небо вращается, на 1x в 4K примерно 7 с)
    var starLimit: Double {
        let t = 7.0 / max(zoom, 0.5) * (uhd ? 1 : 2)
        return max(1, t.rounded())
    }

    /// Выдержка и пауза из интервала и режима
    func syncExposure() {
        let sc = sceneKind
        let cap: Double
        switch sc {
        case .stars: cap = starLimit
        case .clouds: cap = 2
        case .trails, .city: cap = intervalSeconds
        }
        let ex = min(intervalSeconds, cap)
        exposureSeconds = ex
        pauseSeconds = max(0, intervalSeconds - ex)
        lighten = sc.lighten
    }

    func intervalUp() {
        if let n = Self.intervalSteps.first(where: { $0 > intervalSeconds + 0.001 }) { intervalSeconds = n }
        syncExposure()
    }

    func intervalDown() {
        if let n = Self.intervalSteps.last(where: { $0 < intervalSeconds - 0.001 }) { intervalSeconds = n }
        syncExposure()
    }

    /// Фокус обратно на бесконечность
    /// ∞: днём - линза на бесконечность. Ночью положение 1.0 у iPhone даёт размытые звёзды-кружки,
    /// поэтому ночью ∞ сам ищет резкость по звёздам (около 20 секунд)
    func focusInfinity() {
        guard phase == .idle else { return }
        focusAuto = false
        if isDark {
            starFocus()
            return
        }
        focus = 1
        starFocused = false
        applyCamera(forceFocus: true)
    }

    @Published var starFocused = false
    @Published var isDark = false

    // queue: поиск резкости по звёздам
    private var focusPlan: [Float] = []
    private var focusIdx = 0
    private var focusSkip = 0
    private var focusAcc = 0.0
    private var focusN = 0
    private var focusFine = false
    private var focusResults: [(Float, Double)] = []

    func starFocus() {
        guard phase == .idle else { return }
        phase = .test
        status = "Фокус по звёздам..."
        subTotal = 18
        subDone = 0
        UIApplication.shared.isIdleTimerDisabled = true
        queue.async {
            guard let dev = self.device else { return }
            self.focusPlan = stride(from: 0.70, through: 1.0001, by: 0.03).map { Float(min($0, 1)) }
            self.focusFine = false
            self.focusResults = []
            self.focusIdx = 0
            self.appliedFocusAuto = nil
            if (try? dev.lockForConfiguration()) != nil {
                if dev.isExposureModeSupported(.custom) {
                    let d = min(0.25, CMTimeGetSeconds(dev.activeFormat.maxExposureDuration))
                    dev.setExposureModeCustom(duration: CMTime(seconds: d, preferredTimescale: 1_000_000),
                                              iso: dev.activeFormat.maxISO, completionHandler: nil)
                }
                dev.unlockForConfiguration()
            }
            self.setLens(self.focusPlan[0])
            self.mode = .focus
        }
    }

    private func setLens(_ p: Float) {
        guard let dev = device, (try? dev.lockForConfiguration()) != nil else { return }
        if dev.isLockingFocusWithCustomLensPositionSupported {
            dev.setFocusModeLocked(lensPosition: min(max(p, 0), 1), completionHandler: nil)
        }
        dev.unlockForConfiguration()
        focusSkip = 2
        focusAcc = 0
        focusN = 0
    }

    private func focusStep(_ pb: CVPixelBuffer) {
        if focusSkip > 0 {
            focusSkip -= 1
            return
        }
        focusAcc += starMetric(pb)
        focusN += 1
        guard focusN >= 3 else { return }
        focusResults.append((focusPlan[focusIdx], focusAcc / Double(focusN)))
        let done = focusResults.count
        DispatchQueue.main.async { self.subDone = done }
        focusIdx += 1
        if focusIdx < focusPlan.count {
            setLens(focusPlan[focusIdx])
            return
        }
        let best = focusResults.max(by: { $0.1 < $1.1 })?.0 ?? 1
        if !focusFine {
            // Второй проход: точнее вокруг лучшего места
            focusFine = true
            focusPlan = stride(from: Double(best) - 0.03, through: Double(best) + 0.0301, by: 0.01).map { Float(min(max($0, 0), 1)) }
            focusIdx = 0
            setLens(focusPlan[0])
            return
        }
        mode = .off
        Diag.event("Фокус по звёздам: \(String(format: "%.2f", best)); "
            + focusResults.map { String(format: "%.2f=%.0f", $0.0, $0.1) }.joined(separator: " "))
        DispatchQueue.main.async {
            self.focusAuto = false
            self.focus = best
            self.starFocused = true
            self.subDone = 0
            self.applyCamera(forceFocus: true)
            self.finished("Резкость по звёздам найдена")
        }
    }

    /// Резкость звёзд: средняя яркость самых ярких точек в центре кадра (зелёный канал, 2x2).
    /// Звезда в фокусе - маленькая и яркая, не в фокусе - расплывается в тусклый кружок
    private func starMetric(_ pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return 0 }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        let cw = min(1600, w) / 2 * 2, ch = min(1200, h) / 2 * 2
        let x0 = (w - cw) / 2, y0 = (h - ch) / 2
        var hist = [Int](repeating: 0, count: 1021)
        var n = 0
        var y = y0
        while y < y0 + ch {
            var x = x0
            while x < x0 + cw {
                let o = y * rb + x * 4 + 1
                let v = Int(p[o]) + Int(p[o + 4]) + Int(p[o + rb]) + Int(p[o + rb + 4])
                hist[v] += 1
                n += 1
                x += 2
            }
            y += 2
        }
        var need = max(1, n / 1000)
        var sum = 0.0, cnt = 0
        var v = 1020
        while v >= 0 && need > 0 {
            let k = min(hist[v], need)
            sum += Double(k * v)
            cnt += k
            need -= k
            v -= 1
        }
        return cnt > 0 ? sum / Double(cnt) : 0
    }

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
    /// Последние настройки для ночного превью (только queue)
    private var currentSettingsQueue = CamSettings(dur: 1, ev: 0, iso: 100, temp: 4500, focus: 1, wbAuto: true, focusAuto: false)
    private let maxAutoGain: Float = 16
    /// Сколько секунд копить кадр сейчас (при умной выдержке может быть меньше выставленной)
    private var frameTarget: Double = 1
    /// Пауза после текущего кадра: твоя пауза + время, на которое кадр вышел короче
    private var pauseNow: Double = 0
    private var phaseStart: CMTime = .invalid
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var videoURL: URL?
    private var framesDir: URL?
    private var videoIndex: Int64 = 0
    private var outIndex = 0
    /// Starlapse трёх длин и фото со следами собираются прямо во время съёмки
    private struct LiveOut {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        var acc: Frame
        let lut: [UInt8]
    }
    private var live: [LiveOut] = []
    private var trailMax: Frame?
    /// Сколько ночных кадров попало в фото со следами
    private var nightFrames = 0
    private var liveCur: Frame?
    private var liveIndex: Int64 = 0
    /// Время старта съёмки для журнала (queue)
    private var recStartQ: Date?
    private let maxLUT = decayLUT(1)

    override init() {
        let d = UserDefaults.standard
        exposureSeconds = LapseEngine.defaultExposure
        intervalSeconds = d.dbl("interval", 10)
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
        // Яркость всегда авто (один ползунок), умная выдержка всегда включена, фокус - бесконечность или по касанию
        isoAuto = true
        autoShutter = true
        wbAuto = d.flag("wbAuto", false)
        focusAuto = false
        evComp = d.dbl("ev", -1)
        scene = LapseScene(rawValue: d.string(forKey: "scene") ?? "")?.rawValue ?? LapseScene.stars.rawValue
        super.init()

        zoomOptions = ZoomOption.available()
        zoom = ZoomOption.pick(zoom, in: zoomOptions).value
        syncExposure()

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
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            Diag.event("Мало памяти")
        }
        Diag.event("Найтлапс открыт, \(Diag.model())")

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
        intervalSeconds = sc.interval
        evComp = sc.ev
        isoAuto = true
        focusAuto = false
        focus = 1
        syncExposure()
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
        starFocused = false
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
            self.setFrameTarget(c.exposure)
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
            self.setFrameTarget(c.exposure)
            self.writer = nil
            self.framesDir = nil
            self.videoIndex = 0
            self.outIndex = 0
            self.live = []
            self.trailMax = nil
            self.nightFrames = 0
            self.liveCur = nil
            self.liveIndex = 0
            self.recStartQ = Date()
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
        Diag.event("Ошибка камеры, перезапуск")
        queue.async {
            if !self.session.isRunning { self.session.startRunning() }
        }
        applyCamera()
        tryResume()
    }

    private func pauseRecording(_ why: String) {
        guard phase == .recording else { return }
        Diag.event(why)
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
        Diag.event("Съёмка продолжена")
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
                    saveVideo: saveVideo, saveFrames: true, name: name,
                    warmup: warmupFrames(), isoAuto: isoAuto, autoShutter: autoShutter, ev: Float(evComp), iso: iso,
                    scene: scene, interval: intervalSeconds)
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
        if phase == .idle && tickCount % 2 == 0 {
            let cs = currentSettings()
            queue.async {
                self.currentSettingsQueue = cs
                self.checkNightPreview()
            }
        }
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
                Diag.event("Нагрев \(Diag.thermal()): пауза +\(Int(x)) с")
            }
            if x != coolExtra {
                setExtra(x)
                if phase == .recording { status = "Телефон нагрелся: пауза +\(Int(x)) с, пока не остынет" }
            }
        } else if cooling {
            cooling = false
            setExtra(0)
            Diag.event("Остыл")
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
        let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        Diag.device = "Камера: \(dev.localizedName), зум \(zoom.title), формат \(dims.width)x\(dims.height), "
            + "выдержка сенсора \(String(format: "%.4f", subMin))-\(String(format: "%.3f", sub)) с, ISO \(Int(lo))-\(Int(hi))"
        Diag.event("Камера: " + Diag.device)
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
            if nightPreview && dev.isExposureModeSupported(.custom) {
                // Ночью автоэкспозиция превью упирается в 1/30 с и кадр чёрный. Тогда превью - 1/3 с на максимальном ISO:
                // звёзды и горизонт видно, можно выстроить кадр. Яркость результата задаёт ☀︎ и проверяет «Тест»
                let d = min(1.0 / 3.0, CMTimeGetSeconds(fmt.maxExposureDuration))
                dev.setExposureModeCustom(duration: CMTime(seconds: d, preferredTimescale: 1_000_000),
                                          iso: fmt.maxISO, completionHandler: nil)
            } else {
                // До старта превью с автоэкспозицией, чтобы было видно, что в кадре. Коррекция EV видна сразу
                if dev.isExposureModeSupported(.continuousAutoExposure) {
                    dev.exposureMode = .continuousAutoExposure
                }
                dev.setExposureTargetBias(min(max(s.ev, dev.minExposureTargetBias), dev.maxExposureTargetBias),
                                          completionHandler: nil)
            }
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

    /// queue: ночное превью включается, когда автоэкспозиция упёрлась в максимум ISO,
    /// и выключается, когда стало заметно светлее
    private var nightPreview = false

    func checkNightPreview() {
        guard mode == .off, let dev = device else { return }
        let fmt = dev.activeFormat
        if nightPreview {
            if dev.exposureMode != .custom {
                // Касание кадра включило автоэкспозицию - через пару секунд возвращаем ночное превью
                applyOnQueue(currentSettingsQueue)
            } else if dev.exposureTargetOffset > 5 {
                nightPreview = false
                applyOnQueue(currentSettingsQueue)
            }
        } else if dev.exposureMode == .continuousAutoExposure,
                  dev.iso >= fmt.maxISO * 0.9,
                  CMTimeGetSeconds(dev.exposureDuration) >= 1.0 / 40 {
            nightPreview = true
            applyOnQueue(currentSettingsQueue)
        }
        let dark = nightPreview
        DispatchQueue.main.async { if self.isDark != dark { self.isDark = dark } }
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
        // Днём - средне-серый 118. Ночью (сенсор на пределе) небо должно остаться тёмным, как на ночном
        // снимке iPhone: яркость неба около 50, а не серое «как днём»
        var base = 118.0
        if let dev = device {
            let maxDur = min(cfg.exposure, CMTimeGetSeconds(dev.activeFormat.maxExposureDuration))
            if curISO >= dev.activeFormat.maxISO * 0.95 && CMTimeGetSeconds(curDur) >= maxDur * 0.95 { base = 60 }
        }
        let target = base * pow(pow(2.0, Double(cfg.ev)), 1.0 / 2.2)
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
        let m = meanLuma(pb)
        let f = lightFactor(mean: m, limit: 64)
        // Без ограничения: сколько света не хватает на самом деле. Нужно, чтобы ☀︎ влияла на усиление,
        // даже когда сенсор уже на максимуме (иначе усиление всегда упиралось в один и тот же предел)
        let fAll = lightFactor(mean: m, limit: 100_000)
        calibLeft -= 1
        if abs(f - 1) < 0.08 {
            calibLeft = 0
        } else {
            let r = setExposure(light: currentLight() * min(f, 16))
            if abs(r - 1) < 0.02 || calibLeft == 0 {
                calibLeft = 0
                // Сенсор на пределе: недостающий свет добавит цифровое усиление
                let rest = fAll / max(r, 0.0001)
                setAutoGain(rest > 1.08 ? Float(pow(rest, 1 / 2.2)) : 1)
            } else {
                calibSkip = 2
            }
        }
        if calibLeft == 0 {
            updateFrameTarget()
            let isTest = mode == .test
            DispatchQueue.main.async {
                if self.phase == .recording { self.status = "Съёмка" }
                else if isTest { self.status = "Тестовый кадр..." }
            }
        }
    }

    /// После каждого кадра: плавная подстройка, не больше 1/3 EV за кадр, чтобы не было скачков яркости
    private func autoISOStep(mean: Float) {
        defer { updateFrameTarget() }
        let f = lightFactor(mean: mean, limit: 1.26)
        guard abs(f - 1) > 0.02 else { return }
        // Ночью при максимуме сенсора яркость ведёт усиление в renderFrame
        if sensorMaxed() && (f > 1 || autoGain > 1.01) { return }
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

    /// Умная выдержка, как приоритет диафрагмы на камере: выдержка кадра такая, чтобы шум был
    /// не больше, чем у одного снимка на низком ISO. Ночью - вся выставленная выдержка,
    /// на рассвете короче, днём - один короткий снимок
    private func updateFrameTarget() {
        guard cfg.isoAuto, cfg.autoShutter, let dev = device else {
            setFrameTarget(cfg.exposure)
            return
        }
        let isoRef = Double(max(dev.activeFormat.minISO * 2, 100))
        let dur = CMTimeGetSeconds(curDur)
        let need = autoGain > 1.01 ? cfg.exposure : dur * Double(curISO) / isoRef
        setFrameTarget(min(cfg.exposure, max(dur, need)))
    }

    private func setFrameTarget(_ t: Double) {
        frameTarget = t
        DispatchQueue.main.async { self.effExposure = t }
    }

    private func setAutoGain(_ g: Float) {
        autoGain = min(max(g, 1), maxAutoGain)
        let v = autoGain
        DispatchQueue.main.async { self.autoGainShown = v }
    }

    // MARK: Обработка кадров (queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard mode != .off, !suspended, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if mode == .focus {
            focusStep(pb)
            return
        }
        if warmupLeft > 0 {
            warmupLeft -= 1
            return
        }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if inPause {
            if CMTimeGetSeconds(t - phaseStart) < pauseNow + extraPause { return }
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
        let done = min(total, Int((got / max(frameTarget, 0.001) * Double(total)).rounded(.down)))
        DispatchQueue.main.async { self.subDone = done }
        guard got >= frameTarget - sub * 0.5 else { return }

        let n = subCount
        subCount = 0
        phaseStart = t
        let t0 = CACurrentMediaTime()
        let frame = renderFrame(count: n)
        var mean: Float = 0
        if cfg.isoAuto, let f = frame { mean = meanLuma(f) }

        if mode == .test {
            mode = .off
            DispatchQueue.main.async { self.applyCamera() }
            let img = frame.flatMap { makeThumb($0, maxSide: 2000) }
            let note = cfg.isoAuto ? "Тест готов. ISO подобран: \(Int(curISO))" : "Тест готов: проверь яркость и резкость"
            Diag.event("Тест: подкадров \(n), сенсор \(String(format: "%.4f", CMTimeGetSeconds(curDur))) с, ISO \(Int(curISO)), "
                + "усиление \(String(format: "%.2f", autoGain)), яркость \(String(format: "%.0f", mean)), выдержка \(cfg.exposure) с")
            DispatchQueue.main.async {
                self.lastImage = img
                self.subDone = 0
                self.testCount += 1
                self.finished(note)
            }
            return
        }

        pauseNow = cfg.pause + max(0, cfg.exposure - frameTarget)
        inPause = pauseNow + extraPause > 0
        if let f = frame {
            writeFrame(f)
            if cfg.isoAuto { autoISOStep(mean: mean) }
        } else {
            Diag.event("Кадр \(outIndex + 1) не собрался")
        }
        let ms = (CACurrentMediaTime() - t0) * 1000
        let since = recStartQ.map { Date().timeIntervalSince($0) } ?? 0
        Diag.frame([String(format: "%.1f", since), "\(outIndex)", "\(n)", String(format: "%.5f", CMTimeGetSeconds(curDur)),
                    "\(Int(curISO))", String(format: "%.2f", autoGain), String(format: "%.3f", frameTarget),
                    String(format: "%.1f", mean), String(format: "%.1f", pauseNow), String(format: "%.0f", extraPause),
                    String(format: "%.0f", ms), Diag.thermal(), "\(battery)", String(format: "%.1f", freeGB)])
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
        var g = cfg.isoAuto ? autoGain : cfg.gain
        let div: Float = cfg.lighten ? 1 : Float(max(n, 1))
        let night = isNightLight(Double(curISO) * CMTimeGetSeconds(curDur))
        if cfg.isoAuto && sensorMaxed() {
            // Ночь, сенсор на пределе. Усиление считаем по готовому кадру, а не по одному подкадру:
            // сначала убираем «пол» шума, потом доводим небо (медиана зелёного) до яркости
            // ночного снимка iPhone - около 50 при ☀︎ -1, светлее или темнее по ☀︎
            subtractBlack(div: div)
            let m = channelLevel(1, div: div)
            let target = Float(68 * pow(pow(2.0, Double(cfg.ev)), 1.0 / 2.2))
            let want = min(max(target / max(m, 0.5), 1), maxAutoGain)
            // В видео усиление меняется плавно, чтобы кадры не мигали
            setAutoGain(mode == .test || outIndex == 0 ? want : autoGain * 0.7 + want * 0.3)
            g = autoGain
            if g > 1.01 { neutralizeSky(div: div) }
        } else {
            // С цифровым усилением сначала убираем «пол» шума по каждому цвету: иначе усиление
            // поднимает его вместе с картинкой и ночное небо выходит серо-фиолетовым.
            // В «Треках» и «Городе» берётся самая яркая точка из подкадров - ночью шум от этого
            // поднимает фон, поэтому фон тоже опускаем
            if g > 1.01 || (cfg.lighten && n > 1 && night) { subtractBlack(div: div) }
            if g > 1.01 && night { neutralizeSky(div: div) }
        }
        var s: Float = g / div
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

    /// Ночью при усилении небо уходит в фиолетовый: красный выше зелёного. Подравниваем каналы так,
    /// чтобы фон был как на ночном снимке iPhone - нейтральный с лёгкой синевой (R:G:B около 0.93 : 1 : 1.16).
    /// Поправка меняется плавно от кадра к кадру, чтобы видео не мигало
    private var skyScale: [Float] = [1, 1, 1]

    private func neutralizeSky(div: Float) {
        let px = acc.count / 4
        guard px > 1000 else { return }
        var hist = [Int](repeating: 0, count: 3 * 1024)  // шаг 0.25, тёмное небо - всего несколько единиц
        var total = 0
        acc.withUnsafeBufferPointer { a in
            var i = 0
            while i < px {
                for c in 0..<3 {
                    hist[c * 1024 + Int(min(1023, max(0, a[i * 4 + c] / div * 4)))] += 1
                }
                total += 1
                i += 37
            }
        }
        var med: [Float] = [0, 0, 0]
        for c in 0..<3 {
            var sum = 0, v = 0
            while v < 1023 {
                sum += hist[c * 1024 + v]
                if sum >= total / 2 { break }
                v += 1
            }
            med[c] = Float(max(v, 2)) / 4
        }
        // BGRA: 0 - синий, 1 - зелёный, 2 - красный
        let want: [Float] = [med[1] * 1.16 / med[0], 1, med[1] * 0.93 / med[2]]
        for c in [0, 2] {
            let w = min(max(want[c], 0.7), 1.4)
            skyScale[c] = skyScale[c] * 0.8 + w * 0.2
        }
        if mode == .test || outIndex == 0 { skyScale = [min(max(want[0], 0.7), 1.4), 1, min(max(want[2], 0.7), 1.4)] }
        acc.withUnsafeMutableBufferPointer { a in
            guard let p = a.baseAddress else { return }
            for c in [0, 2] {
                var k = skyScale[c]
                vDSP_vsmul(p + c, 4, &k, p + c, 4, vDSP_Length(px))
            }
        }
    }

    /// ISO и выдержка подкадра на максимуме: светлее сенсором уже не сделать
    private func sensorMaxed() -> Bool {
        guard let dev = device else { return false }
        let maxDur = min(cfg.exposure, CMTimeGetSeconds(dev.activeFormat.maxExposureDuration))
        return curISO >= dev.activeFormat.maxISO * 0.95 && CMTimeGetSeconds(curDur) >= maxDur * 0.95
    }

    /// Яркость фона по каналу (0 - синий, 1 - зелёный, 2 - красный): 60% точек темнее.
    /// Не середина, чтобы тёмные деревья и горы внизу кадра не тянули усиление вверх
    private func channelLevel(_ c: Int, div: Float) -> Float {
        let px = acc.count / 4
        guard px > 1000 else { return 1 }
        var hist = [Int](repeating: 0, count: 1024)
        var total = 0
        acc.withUnsafeBufferPointer { a in
            var i = 0
            while i < px {
                hist[Int(min(1023, max(0, a[i * 4 + c] / div * 4)))] += 1
                total += 1
                i += 37
            }
        }
        var sum = 0, v = 0
        while v < 1023 {
            sum += hist[v]
            if sum >= total * 6 / 10 { break }
            v += 1
        }
        return Float(v) / 4
    }

    /// Чёрная точка по каждому каналу: 1% самых тёмных точек кадра становится чёрным
    private func subtractBlack(div: Float) {
        let px = acc.count / 4
        guard px > 1000 else { return }
        var hist = [Int](repeating: 0, count: 3 * 256)
        var total = 0
        acc.withUnsafeBufferPointer { a in
            var i = 0
            while i < px {
                for c in 0..<3 {
                    let v = Int(min(255, max(0, a[i * 4 + c] / div)))
                    hist[c * 256 + v] += 1
                }
                total += 1
                i += 37
            }
        }
        let need = max(1, total / 100)
        acc.withUnsafeMutableBufferPointer { a in
            guard let p = a.baseAddress else { return }
            for c in 0..<3 {
                var sum = 0, bl = 0
                while bl < 255 {
                    sum += hist[c * 256 + bl]
                    if sum >= need { break }
                    bl += 1
                }
                var neg = -Float(min(bl, 60)) * div
                if neg < 0 { vDSP_vsadd(p + c, 4, &neg, p + c, 4, vDSP_Length(px)) }
            }
        }
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
                ShootStore.writeInfo(dir, ["fps": Int(cfg.fps), "scene": cfg.scene, "interval": cfg.interval,
                                           "created": Date().timeIntervalSince1970, "done": false,
                                           "exposure": cfg.exposure, "pause": cfg.pause, "ev": Double(cfg.ev),
                                           "device": Diag.model(), "camera": Diag.device])
                Diag.beginShoot(dir, "режим \(cfg.scene), интервал \(cfg.interval) с, выдержка \(cfg.exposure) с, "
                    + "пауза \(cfg.pause) с, яркость \(cfg.ev) EV, \(cfg.fps) к/с, подкадров \(cfg.subNeeded)")
            }
            if let dir = framesDir, let cs = CGColorSpace(name: CGColorSpace.sRGB) {
                var img = CIImage(cvPixelBuffer: out)
                if cfg.vertical { img = img.oriented(.right) }
                let url = dir.appendingPathComponent(String(format: "frame_%05d.jpg", outIndex + 1))
                let q = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                try? ci.writeJPEGRepresentation(of: img, to: url, colorSpace: cs, options: [q: 0.95])
            }
            updateLive(out)
        }

        outIndex += 1
        let c = outIndex
        let thumb = makeThumb(out, maxSide: 900)
        DispatchQueue.main.async {
            self.framesDone = c
            if let t = thumb { self.lastImage = t }
        }
    }

    private func makeLiveWriter(_ url: URL, _ w: Int, _ h: Int) -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor)? {
        try? FileManager.default.removeItem(at: url)
        guard let wr = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        wr.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: w * h * 18]
        ])
        input.expectsMediaDataInRealTime = false
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h
        ])
        guard wr.canAdd(input) else { return nil }
        wr.add(input)
        guard wr.startWriting() else { return nil }
        wr.startSession(atSourceTime: .zero)
        return (wr, input, ad)
    }

    /// queue: каждый новый кадр сразу добавляется в Starlapse и в фото со следами - после «Стоп» всё готово
    private func updateLive(_ pb: CVPixelBuffer) {
        guard let dir = framesDir else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if trailMax == nil || trailMax?.w != w || trailMax?.h != h {
            trailMax = Frame(w: w, h: h)
            liveCur = Frame(w: w, h: h)
            liveIndex = 0
            live = Trail.allCases.compactMap { t in
                guard let u = ShootStore.liveURL(dir, .starlapse, t), let m = makeLiveWriter(u, w, h) else { return nil }
                return LiveOut(writer: m.0, input: m.1, adaptor: m.2, acc: Frame(w: w, h: h), lut: decayLUT(t.decay))
            }
        }
        guard var cur = liveCur else { return }
        liveCur = nil
        cur.load(from: pb)
        // Следы копятся только в темноте: днём «самое яркое» из всех кадров - это белое небо,
        // а листья на ветру заменяются небом. Светлый кадр идёт в Starlapse как есть, без следа
        let night = isNightLight(Double(curISO) * CMTimeGetSeconds(curDur))
        if night {
            trailMax?.trail(with: cur, lut: maxLUT)
            nightFrames += 1
        }
        for i in live.indices {
            if night {
                live[i].acc.trail(with: cur, lut: live[i].lut)
            } else {
                live[i].acc = cur
            }
            var pbo: CVPixelBuffer?
            if let pool = live[i].adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbo)
            } else {
                CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pbo)
            }
            guard let o = pbo else { continue }
            live[i].acc.copy(to: o)
            var tries = 0
            while !live[i].input.isReadyForMoreMediaData && tries < 300 {
                usleep(10_000)
                tries += 1
            }
            if live[i].input.isReadyForMoreMediaData {
                live[i].adaptor.append(o, withPresentationTime: CMTime(value: liveIndex, timescale: cfg.fps))
            }
        }
        liveCur = cur
        liveIndex += 1
    }

    /// queue: дописать Starlapse и сохранить фото со следами в папку съёмки
    private func finishLive(_ dir: URL?) {
        let outs = live
        live = []
        for o in outs {
            o.input.markAsFinished()
            let sem = DispatchSemaphore(value: 0)
            o.writer.finishWriting { sem.signal() }
            sem.wait()
        }
        if nightFrames > 0, let d = dir, let tm = trailMax, let img = tm.cgImage(), let jpg = ShootStore.jpeg(img) {
            try? jpg.write(to: d.appendingPathComponent("startrail.jpg"))
        }
        trailMax = nil
        liveCur = nil
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
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 18]
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
        let dir = framesDir
        framesDir = nil
        finishLive(dir)
        if let d = dir { ShootStore.markDone(d) }
        Diag.event("Стоп: \(frames) кадров")
        Diag.endShoot()
        func end(_ m: String) {
            DispatchQueue.main.async {
                self.finished(m)
                if let d = dir { self.lastShoot = d }
            }
        }
        guard let w = writer, let url = videoURL, videoIndex > 0 else {
            writer = nil
            if frames == 0 {
                DispatchQueue.main.async { self.finished("Ни одного кадра не снято") }
            } else {
                end("Кадры сохранены: Файлы → На iPhone → NightLapse")
            }
            return
        }
        writerInput?.markAsFinished()
        writer = nil
        writerInput = nil
        adaptor = nil
        w.finishWriting {
            guard w.status == .completed else {
                Diag.event("Ошибка записи видео: \(w.error?.localizedDescription ?? "-")")
                end("Ошибка записи видео, но все кадры целы: Файлы → NightLapse")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, _ in
                if ok { try? FileManager.default.removeItem(at: url) }
                end(ok ? "Видео сохранено в Фото" : "Нет доступа к Фото. Видео лежит в Файлы → NightLapse")
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
    /// Свайп вбок: +1 - следующий режим, -1 - предыдущий
    var onSwipe: (Int) -> Void = { _ in }

    final class PView: UIView {
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
        v.onSwipe = onSwipe
        let e = engine
        DispatchQueue.main.async { e.attachPreview(v.pl) }
        return v
    }

    func updateUIView(_ uiView: PView, context: Context) {
        uiView.onTap = onTap
        uiView.onPan = onPan
        uiView.onSwipe = onSwipe
    }
}

// MARK: - Главный экран, как Камера iPhone

struct ContentView: View {
    var onSwitch: () -> Void = {}
    @StateObject private var e = LapseEngine()
    @State private var dark = false
    @State private var showTest = false
    @State private var showSettings = false
    @State private var focusMark: CGPoint?
    @State private var markTick = 0
    @State private var openParam: Param?
    @State private var showShoots = false
    @AppStorage("guideSeen") private var guideSeen = false
    @State private var shootToOpen: URL?

    enum Param { case brightness, interval, duration }

    private var idle: Bool { e.phase == .idle }
    private var shooting: Bool {
        e.phase == .recording || e.phase == .paused || e.phase == .saving || e.phase == .waiting
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                // Один и тот же кадр камеры в обеих ориентациях: при повороте он только двигается,
                // а не создаётся заново - поэтому экран не пропадает на несколько секунд
                CameraLayout(landscape: landscape) {
                    topBar
                        .padding(.horizontal, landscape ? 8 : 16)
                        .padding(.bottom, landscape ? 0 : 6)
                    preview
                    bottomControls
                        .padding(.top, landscape ? 0 : 8)
                        .padding(.horizontal, landscape ? 8 : 0)
                        .clipped()
                }
                if dark { darkOverlay }
                if !guideSeen { GuideView { guideSeen = true } }
            }
        }
        .onAppear {
            e.configure()
            if let p = UserDefaults.standard.string(forKey: "pendingScene"), let sc = LapseScene(rawValue: p) {
                UserDefaults.standard.removeObject(forKey: "pendingScene")
                e.applyScene(sc)
            }
        }
        .onDisappear { e.shutdown() }
        .onChange(of: e.testCount) { showTest = true }
        .onChange(of: e.zoom) {
            e.changeCamera()
            e.syncExposure()
        }
        .onChange(of: e.uhd) {
            e.changeCamera()
            e.syncExposure()
        }
        .onChange(of: e.wbAuto) { e.applyCamera() }
        .onChange(of: e.evComp) { e.applyCamera() }
        .onChange(of: e.phase) { if e.phase != .idle { openParam = nil } }
        .onChange(of: e.lastShoot) {
            if let d = e.lastShoot {
                shootToOpen = d
                showShoots = true
            }
        }
        .sheet(isPresented: $showShoots, onDismiss: { shootToOpen = nil }) {
            ShootsView(open: shootToOpen)
        }
        .sheet(isPresented: $showTest) { testSheet }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(e: e)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Верхняя полоса

    private var topBar: some View {
        HStack(spacing: 10) {
            infoChip
            Spacer(minLength: 0)
            if shooting { recTimer }
            Spacer(minLength: 0)
            Button { e.focusInfinity() } label: {
                Text("∞")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(e.focus >= 0.99 || e.starFocused ? Color.yellow : Color.white)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .disabled(!idle)
            .accessibilityLabel("Фокус на бесконечность")
            roundIcon("moon.fill") { dark = true }
            roundIcon("gearshape.fill") { showSettings = true }
                .disabled(!idle)
        }
        .padding(.top, 4)
    }

    private func roundIcon(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 36)
                .foregroundStyle(Color.white)
                .background(Color.white.opacity(0.12), in: Circle())
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
        .labelStyle(.titleAndIcon)
        .foregroundStyle(Color.white.opacity(0.8))
    }

    /// Красный таймер, как при записи видео в Камере
    private var recTimer: some View {
        Text(e.phase == .waiting ? "Старт через \(hms(e.countdown))" : hms(e.elapsed))
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(e.phase == .recording ? Color.red : Color.gray.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Кадр

    private var preview: some View {
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
                          },
                          onSwipe: { d in
                              guard idle else { return }
                              select((LapseScene.allCases.firstIndex(of: e.sceneKind) ?? 0) + 1 + d)
                          })
            if let m = focusMark { focusIndicator(at: m) }
            VStack(spacing: 6) {
                if e.phase == .recording || e.phase == .test {
                    ProgressView(value: Double(min(e.subDone, e.subTotal)), total: Double(max(e.subTotal, 1)))
                        .tint(.red)
                }
                if showStatus {
                    Text(statusLine)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(e.hot ? Color.orange : Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.55), in: Capsule())
                }
                Spacer()
                if shooting {
                    HStack {
                        recordingInfo
                        Spacer()
                    }
                } else if idle {
                    zoomRow
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var showStatus: Bool {
        !idle || (e.status != "Готово" && !e.status.isEmpty)
    }

    /// Кнопки зума, как в Камере: круглые, выбранная жёлтая
    private var zoomRow: some View {
        HStack(spacing: 6) {
            ForEach(e.zoomOptions) { z in
                let sel = abs(z.value - e.zoom) < 0.01
                Button { e.zoom = z.value } label: {
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
        .animation(.easeOut(duration: 0.15), value: e.zoom)
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

    private var recordingInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(e.framesDone) кадров").font(.headline.monospacedDigit())
            Text("видео \(String(format: "%.1f", Double(e.framesDone) / Double(max(e.fps, 1)))) с")
                .font(.caption.monospacedDigit())
        }
        .padding(8)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusLine: String {
        var s = e.phase == .waiting ? "Ожидание старта" : e.status
        if e.pauses > 0 && (e.phase == .recording || e.phase == .paused) { s += " · пауз: \(e.pauses)" }
        if e.cooling && (e.phase == .recording || e.phase == .paused) { s += " · пауза +\(Int(e.coolExtra)) с от нагрева" }
        if e.phase == .recording && e.effExposure > 0 && e.effExposure < e.exposureSeconds - 0.01 {
            s += " · выдержка \(expText(e.effExposure))"
        }
        if e.hot { s += " · телефон перегрет" }
        return s
    }

    // MARK: Низ: параметры, режимы, кнопка спуска

    private var bottomControls: some View {
        VStack(spacing: 10) {
            if idle {
                if let p = openParam { paramEditor(p) }
                paramRow
                Text(planLine)
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                modeCarousel
            } else if e.phase == .recording || e.phase == .paused {
                Text("Не двигай телефон. Луна сверху гасит экран")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            shutterRow
        }
        .padding(.bottom, 8)
    }

    private var paramRow: some View {
        HStack(spacing: 8) {
            paramChip(.brightness, "sun.max.fill", String(format: "%+.1f", e.evComp))
            paramChip(.interval, "timer", expText(e.intervalSeconds))
            paramChip(.duration, "hourglass", e.autoStopMin == 0 ? "∞" : durText(Double(e.autoStopMin) * 60))
        }
    }

    private func paramChip(_ p: Param, _ icon: String, _ value: String) -> some View {
        let on = openParam == p
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { openParam = on ? nil : p }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(value).monospacedDigit()
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(on ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(on ? Color.yellow : Color.white.opacity(0.14), in: Capsule())
        }
    }

    @ViewBuilder private func paramEditor(_ p: Param) -> some View {
        VStack(spacing: 6) {
            switch p {
            case .brightness:
                HStack {
                    Image(systemName: "sun.min")
                    Slider(value: $e.evComp, in: -4...2, step: 0.1)
                        .tint(.yellow)
                    Image(systemName: "sun.max.fill")
                }
                Text("Яркость \(String(format: "%+.1f", e.evComp)). Можно и пальцем по кадру вверх-вниз")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.6))
            case .interval:
                HStack(spacing: 16) {
                    stepButton("minus") { e.intervalDown() }
                    Text("Снимок каждые \(expText(e.intervalSeconds))")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .frame(minWidth: 170)
                    stepButton("plus") { e.intervalUp() }
                }
                Text(intervalNote)
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            case .duration:
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach([0, 30, 60, 120, 240, 480], id: \.self) { m in
                            let sel = e.autoStopMin == m
                            Button { e.autoStopMin = m } label: {
                                Text(m == 0 ? "Пока не остановлю" : durText(Double(m) * 60))
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(sel ? Color.black : Color.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(sel ? Color.yellow : Color.white.opacity(0.14), in: Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.horizontal, 16)
        .transition(.opacity)
    }

    private func stepButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 38, height: 38)
                .foregroundStyle(Color.white)
                .background(Color.white.opacity(0.14), in: Circle())
        }
    }

    private var intervalNote: String {
        let ex = expText(e.exposureSeconds)
        switch e.sceneKind {
        case .stars:
            return e.pauseSeconds > 0
                ? "Выдержка \(ex) - дольше звёзды размажутся. Остальное время - пауза"
                : "Выдержка \(ex)"
        case .clouds:
            return "Выдержка до \(ex), днём сама короче"
        case .trails, .city:
            return "Выдержка на весь интервал, линии без разрывов"
        }
    }

    /// Режимы листаются пальцем или касанием, как в Камере
    private var modeCarousel: some View {
        ModeCarousel(selected: (LapseScene.allCases.firstIndex(of: e.sceneKind) ?? 0) + 1) { select($0) }
    }

    private func select(_ i: Int) {
        guard idle else { return }
        if i <= 0 {
            onSwitch()
            return
        }
        let all = LapseScene.allCases
        guard i - 1 < all.count else { return }
        openParam = nil
        e.applyScene(all[i - 1])
    }

    private var shutterRow: some View {
        HStack {
            thumbButton
            Spacer()
            shutterButton
            Spacer()
            testButton
        }
        .padding(.horizontal, 28)
    }

    @ViewBuilder private var thumbButton: some View {
        Button {
            shootToOpen = nil
            showShoots = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1))
                if let img = e.lastImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "film.stack").foregroundStyle(Color.white)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.4)))
        }
    }

    /// Большая кнопка: круг - старт, квадрат - стоп
    private var shutterButton: some View {
        Button {
            switch e.phase {
            case .idle: e.start()
            case .recording, .paused: e.stop()
            case .test, .waiting: e.cancel()
            case .saving: break
            }
        } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                switch e.phase {
                case .idle:
                    Circle().fill(Color.red).frame(width: 64, height: 64)
                case .recording, .paused:
                    RoundedRectangle(cornerRadius: 7).fill(Color.red).frame(width: 30, height: 30)
                case .test, .waiting:
                    Image(systemName: "xmark").font(.system(size: 26, weight: .bold)).foregroundStyle(Color.white)
                case .saving:
                    ProgressView()
                }
            }
        }
        .disabled(e.phase == .saving)
        .accessibilityLabel(idle ? "Старт" : "Стоп")
    }

    private var testButton: some View {
        Button { e.testFrame() } label: {
            VStack(spacing: 1) {
                if e.phase == .test {
                    ProgressView()
                } else {
                    Image(systemName: "camera.aperture").font(.system(size: 18, weight: .semibold))
                }
                Text("Тест").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .frame(width: 52, height: 52)
            .background(Color.white.opacity(0.14), in: Circle())
        }
        .disabled(!idle)
        .opacity(idle || e.phase == .test ? 1 : 0.3)
    }

    private var planLine: String {
        let interval = max(e.intervalSeconds, 0.01)
        let fps = Double(max(e.fps, 1))
        let videoPerHour = 3600 / interval / fps
        var s = "\(e.sceneKind.hint)\n1 час съёмки = \(String(format: "%.1f", videoPerHour)) с видео"
        if e.autoStopMin > 0 {
            s += ", за \(durText(Double(e.autoStopMin) * 60)) - \(String(format: "%.1f", videoPerHour * Double(e.autoStopMin) / 60)) с"
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

// MARK: - Подсказки при первом запуске

struct GuideView: View {
    let onDone: () -> Void
    @State private var page = 0

    private struct Page {
        let icon: String
        let title: String
        let text: String
    }

    private let pages: [Page] = [
        Page(icon: "hand.draw", title: "Листай режимы",
             text: "Проведи пальцем по кадру влево или вправо - режим сменится, как в Камере: Кадр дня, Звёзды, Треки, Город, Облака"),
        Page(icon: "viewfinder", title: "Фокус и яркость",
             text: "Коснись кадра - фокус и яркость в этой точке. Веди пальцем вверх или вниз - ярче или темнее. ∞ сверху - ночью сам наводит резкость по звёздам, около 20 секунд"),
        Page(icon: "timer", title: "Как часто и сколько",
             text: "Внизу три кнопки: ☀︎ яркость, ⏱ как часто снимать, ⌛ сколько снимать. Выдержку приложение подбирает само под режим и свет"),
        Page(icon: "record.circle", title: "Старт и результат",
             text: "Красная кнопка - старт и стоп, «Тест» - пробный кадр. После «Стоп» откроется редактор: таймлапс, Starlapse и фото со следами. Все съёмки - в миниатюре слева"),
        Page(icon: "moon.fill", title: "Ночью",
             text: "Луна сверху гасит экран, чтобы не светил. Если телефон нагреется, пауза между кадрами сама станет длиннее. Исходные кадры всегда в Файлы → NightLapse")
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(spacing: 18) {
                HStack {
                    Spacer()
                    Button("Пропустить") { onDone() }
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { i in
                        VStack(spacing: 16) {
                            Image(systemName: pages[i].icon)
                                .font(.system(size: 54, weight: .light))
                                .foregroundStyle(Color.yellow)
                            Text(pages[i].title)
                                .font(.title2.bold())
                            Text(pages[i].text)
                                .font(.body)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(Color.white.opacity(0.85))
                                .padding(.horizontal, 12)
                        }
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .frame(maxHeight: 380)
                Button {
                    if page < pages.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        onDone()
                    }
                } label: {
                    Text(page < pages.count - 1 ? "Дальше" : "Понятно")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.yellow, in: Capsule())
                        .foregroundStyle(Color.black)
                }
            }
            .padding(24)
            .foregroundStyle(Color.white)
        }
    }
}

// MARK: - Лента режимов, общая для найтлапса и кадра дня

/// 0 - Кадр дня, дальше режимы найтлапса по порядку
struct ModeCarousel: View {
    let selected: Int
    let onSelect: (Int) -> Void

    struct Item: Identifiable {
        let title: String
        let index: Int
        var id: Int { index }
    }

    var body: some View {
        let items: [Item] = [Item(title: "Кадр дня", index: 0)]
            + LapseScene.allCases.enumerated().map { Item(title: $0.element.title, index: $0.offset + 1) }
        let w: CGFloat = 86
        let sel = selected
        HStack(spacing: 0) {
            ForEach(items) { item in
                let i = item.index
                Button { if i != sel { onSelect(i) } } label: {
                    Text(item.title.uppercased())
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(i == sel ? Color.yellow : Color.white)
                        .lineLimit(1)
                        .frame(width: w, height: 28)
                }
            }
        }
        .fixedSize()
        .offset(x: (CGFloat(items.count - 1) / 2 - CGFloat(sel)) * w)
        .frame(maxWidth: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 15).onEnded { v in
            if v.translation.width < -30 && sel + 1 < items.count { onSelect(sel + 1) }
            if v.translation.width > 30 && sel > 0 { onSelect(sel - 1) }
        })
        .animation(.easeOut(duration: 0.2), value: sel)
    }
}

// MARK: - Настройки (шторка по шестерёнке)

struct SettingsSheet: View {
    @ObservedObject var e: LapseEngine
    @Environment(\.dismiss) private var dismiss
    @AppStorage("guideSeen") private var guideSeen = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("4K (выкл. = 1080p)", isOn: $e.uhd)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Баланс белого")
                            Spacer()
                            Text(e.wbAuto ? "Авто" : "\(Int(e.wbTemp)) K").foregroundStyle(.secondary).monospacedDigit()
                        }
                        HStack(spacing: 10) {
                            Button("Авто") { e.wbAuto = true }
                                .buttonStyle(.bordered)
                                .tint(e.wbAuto ? .yellow : .gray)
                            Slider(value: Binding(get: { e.wbTemp }, set: { v in
                                e.wbTemp = v
                                if e.wbAuto { e.wbAuto = false }
                            }), in: 2500...7500, step: 100, onEditingChanged: { editing in if !editing { e.applyCamera() } })
                            .opacity(e.wbAuto ? 0.4 : 1)
                        }
                    }
                } header: {
                    Text("Камера")
                } footer: {
                    Text("Видео будет горизонтальным или вертикальным - как держишь телефон в момент старта")
                }

                Section("Сохранение") {
                    Toggle("Видео в Фото", isOn: $e.saveVideo)
                    Picker("Кадров в секунду", selection: $e.fps) {
                        Text("24").tag(24)
                        Text("25").tag(25)
                        Text("30").tag(30)
                    }
                    Text("Исходные кадры всегда сохраняются в Файлы → На iPhone → NightLapse. Удалить их можно только вручную")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Задержка старта", selection: $e.startDelayMin) {
                        Text("Нет").tag(0)
                        Text("1 мин").tag(1)
                        Text("5 мин").tag(5)
                        Text("15 мин").tag(15)
                        Text("30 мин").tag(30)
                        Text("1 ч").tag(60)
                    }
                    Toggle("Длиннее пауза при перегреве", isOn: $e.coolBreaks)
                } header: {
                    Text("Съёмка")
                } footer: {
                    Text("Если телефон сильно нагреется, к паузе между кадрами добавится время, пока не остынет. Съёмка не прерывается")
                }

                Section {
                    ReportRow()
                } header: {
                    Text("Отчёт для улучшения")
                } footer: {
                    Text("Приложение ведёт журнал: настройки, яркость, ISO, нагрев, ошибки по каждому кадру. Само ничего не отправляет. Собери отчёт и пришли файл в чат с Claude")
                }

                Section("Подсказки") {
                    Button("Показать подсказки снова") {
                        guideSeen = false
                        dismiss()
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}


// MARK: - Раскладка экрана камеры

/// Верхняя панель, кадр и нижние кнопки. Вертикально - друг под другом,
/// горизонтально - кадр слева, панель и кнопки колонкой справа. Порядок вложенных view не меняется,
/// поэтому SwiftUI не пересоздаёт кадр камеры при повороте
struct CameraLayout: Layout {
    var landscape: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let top = subviews[0], mid = subviews[1], bottom = subviews[2]
        if landscape {
            let sw = min(380, b.width * 0.42)
            let sx = b.maxX - sw
            let th = top.sizeThatFits(ProposedViewSize(width: sw, height: nil)).height
            let bh = min(b.height - th, bottom.sizeThatFits(ProposedViewSize(width: sw, height: nil)).height)
            top.place(at: CGPoint(x: sx, y: b.minY), proposal: ProposedViewSize(width: sw, height: th))
            bottom.place(at: CGPoint(x: sx, y: b.maxY - bh), proposal: ProposedViewSize(width: sw, height: bh))
            mid.place(at: b.origin, proposal: ProposedViewSize(width: b.width - sw, height: b.height))
        } else {
            let th = top.sizeThatFits(ProposedViewSize(width: b.width, height: nil)).height
            let bh = bottom.sizeThatFits(ProposedViewSize(width: b.width, height: nil)).height
            top.place(at: b.origin, proposal: ProposedViewSize(width: b.width, height: th))
            mid.place(at: CGPoint(x: b.minX, y: b.minY + th),
                      proposal: ProposedViewSize(width: b.width, height: max(0, b.height - th - bh)))
            bottom.place(at: CGPoint(x: b.minX, y: b.maxY - bh), proposal: ProposedViewSize(width: b.width, height: bh))
        }
    }
}
