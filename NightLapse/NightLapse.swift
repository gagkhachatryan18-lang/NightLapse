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

    init() { Trace.start() }

    var body: some Scene {
        WindowGroup {
            Group {
                if mode == .night {
                    ContentView(onSwitch: { switchTo(.daily) })
                        .tint(Pal(night: false).accent)
                } else {
                    RootView(onSwitch: { switchTo(.night) }, onScene: { sc in
                        UserDefaults.standard.set(sc.rawValue, forKey: "pendingScene")
                        switchTo(.night)
                    })
                        .tint(Pal(night: false).accent)
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

/// Режимы съёмки, как режимы в Камере iPhone: всё остальное выставляется само.
/// Найтлапс - ночь и звёзды: кадры почти подряд, следы, Starlapse и фото - потом в редакторе.
/// Таймлапс - обычный, в основном днём. rawValue оставлены старые, чтобы не терялись настройки
enum LapseScene: String, CaseIterable, Identifiable {
    case stars, clouds, photo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stars: return "Найтлапс"
        case .clouds: return "Таймлапс"
        case .photo: return "Фото"
        }
    }
    var hint: String {
        switch self {
        case .stars: return "Ночное небо"
        case .clouds: return "Дневной таймлапс"
        case .photo: return "Одно фото"
        }
    }
    /// Снимок каждые N секунд по умолчанию
    var interval: Double {
        switch self {
        case .stars: return 8
        case .clouds: return 5
        case .photo: return 30   // у фото интервала нет: это потолок выдержки
        }
    }
    var lighten: Bool { false }
    var ev: Double {
        switch self {
        case .stars: return -1
        case .clouds: return -0.5
        case .photo: return -0.5
        }
    }
}

/// 1/8 с, 0.5 с, 17 с
func expText(_ v: Double) -> String {
    // 0 и мусор не делим: 1/0 давало вылет, когда выдержка равна интервалу и пауза 0
    guard v.isFinite, v > 0.00005 else { return "0 с" }
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
    @Published var zoom: Double {
        didSet {
            ud.set(zoom, forKey: "zoom")
            // У другого объектива своя резкость - ∞ по звёздам надо найти заново
            if oldValue != zoom { starFocused = false }
        }
    }
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
        case .stars: cap = intervalSeconds   // без скрытых ограничений: кадр на весь интервал, что выйдет - покажет тест
        case .clouds: cap = 2
        case .photo: cap = starLimit   // днём сама станет короче, как в таймлапсе
        }
        let ex = expManual ? min(exposureSeconds, intervalSeconds) : min(intervalSeconds, cap)
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
    /// поэтому ночью ∞ сам ищет резкость по звёздам (около 30 секунд)
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

    /// Таймер после нажатия «Тест», «Старт» и ∞: 3 с для крепкого штатива, 10 с для лёгкого
    @Published var startHold: Int = 3 { didSet { UserDefaults.standard.set(startHold, forKey: "startHold") } }

    /// Резкость по звёздам найдена для текущего объектива (запоминается между запусками)
    /// Вернуть обычный автофокус
    func resetFocusAuto() {
        guard phase == .idle else { return }
        starFocused = false
        focusAuto = true
        applyCamera(forceFocus: true)
    }

    @Published var starFocused = false { didSet { UserDefaults.standard.set(starFocused, forKey: "starFocused") } }
    @Published var isDark = false

    // queue: поиск резкости по звёздам
    private var focusPlan: [Float] = []
    /// queue: до этого времени кадры не берутся (защита от дрожания после нажатия)
    private var holdUntil: CFTimeInterval = 0
    private var focusIdx = 0
    private var focusSkip = 0
    private var focusAcc = 0.0
    private var focusN = 0
    private var focusFine = false
    private var focusResults: [(Float, Double)] = []

    func starFocus() {
        guard phase == .idle else { return }
        phase = .test
        status = "Навожу фокус по звёздам, около 15 с. Не трогай телефон"
        let hold = startHold
        subTotal = 20
        subDone = 0
        UIApplication.shared.isIdleTimerDisabled = true
        queue.async {
            guard let dev = self.device else { return }
            // Грубо через 0.05 (13 положений), потом точно ±0.03 вокруг лучшего: всего 20 шагов по 0.75 с
            self.focusPlan = stride(from: 0.40, through: 1.0001, by: 0.05).map { Float(min($0, 1)) }
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
            self.holdUntil = CACurrentMediaTime() + Double(hold)
            self.mode = .focus
        }
    }

    private func setLens(_ p: Float) {
        guard let dev = device, (try? dev.lockForConfiguration()) != nil else { return }
        if dev.isLockingFocusWithCustomLensPositionSupported {
            dev.setFocusModeLocked(lensPosition: min(max(p, 0), 1), completionHandler: nil)
        }
        dev.unlockForConfiguration()
        focusSkip = 1
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
        guard focusN >= 2 else { return }
        focusResults.append((focusPlan[focusIdx], focusAcc / Double(focusN)))
        let done = focusResults.count
        DispatchQueue.main.async {
            self.subDone = done
            let left = max(1, Int((Double(max(0, self.subTotal - done)) * 0.75).rounded()))
            self.status = "Навожу фокус по звёздам: осталось около \(left) с. Не трогай телефон"
        }
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
            self.finished("Фокус по звёздам наведён")
            if let next = self.afterFocus {
                self.afterFocus = nil
                next()
            }
        }
    }

    /// Резкость звёзд: насколько звёзды выделяются над фоном рядом с ними (зелёный канал, 2x2).
    /// Звезда в фокусе - яркая точка на тёмном фоне, не в фокусе - кружок, у которого в 4 точках
    /// от центра почти так же светло. Свечение у горизонта и общий фон на это не влияют
    private func starMetric(_ pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return 0 }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        let bw = min(1600, w) / 2, bh = min(1200, h) / 2
        let x0 = (w - bw * 2) / 2, y0 = (h - bh * 2) / 2
        var b = [Int32](repeating: 0, count: bw * bh)
        for by in 0..<bh {
            let row = (y0 + by * 2) * rb + x0 * 4 + 1
            for bx in 0..<bw {
                let o = row + bx * 8
                b[by * bw + bx] = Int32(p[o]) + Int32(p[o + 4]) + Int32(p[o + rb]) + Int32(p[o + rb + 4])
            }
        }
        let d = 4
        var hist = [Int](repeating: 0, count: 1021)
        var n = 0
        for by in d..<(bh - d) {
            for bx in d..<(bw - d) {
                let i = by * bw + bx
                let ring = (b[i - d] + b[i + d] + b[i - d * bw] + b[i + d * bw]) / 4
                let hp = Int(b[i] - ring)
                if hp > 0 { hist[min(hp, 1020)] += 1 }
                n += 1
            }
        }
        var need = max(1, n / 10000)
        var sum = 0.0, cnt = 0
        var v = 1020
        while v > 0 && need > 0 {
            let k = min(hist[v], need)
            sum += Double(k * v)
            cnt += k
            need -= k
            v -= 1
        }
        return cnt > 0 ? sum / Double(cnt) : 0
    }

    /// Выдержка выставлена руками в шторке: интервал её больше не меняет, только не даёт стать длиннее себя
    @Published var expManual = false

    /// Шаг выдержки в шторке: от 1/8 с до интервала, остальное - пауза
    func exposureStep(_ up: Bool) {
        expManual = true
        let steps = exposureRange
        if up {
            if let n = steps.first(where: { $0 > exposureSeconds + 0.0001 }) { exposureSeconds = n }
        } else if let n = steps.last(where: { $0 < exposureSeconds - 0.0001 }) {
            exposureSeconds = n
        }
        pauseSeconds = max(0, intervalSeconds - exposureSeconds)
        applyCamera()
    }

    /// Доступные шаги: ночью от 1/8 с, днём от 1/1000 с, и не длиннее интервала
    var exposureRange: [Double] {
        let lo = sceneKind == .stars ? 0.125 : 0.001
        return Self.exposureSteps.filter { $0 >= lo - 0.0001 && $0 <= intervalSeconds + 0.0001 }
    }
    var canExposureDown: Bool { (exposureRange.first ?? 0) < exposureSeconds - 0.0001 }
    var canExposureUp: Bool { (exposureRange.last ?? 0) > exposureSeconds + 0.0001 }

    /// Выдержка снова сама: по интервалу и режиму
    func exposureAuto() {
        expManual = false
        syncExposure()
        applyCamera()
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
        lighten = false  // режимов «Треки» и «Город» больше нет: следы делает редактор
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
        starFocused = d.flag("starFocused", false)
        startHold = d.num("startHold", 3)
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
                if ok {
                    self.changeCamera()
                    self.resumeIfInterrupted()
                } else {
                    self.status = "Нет доступа к камере: Настройки → NightLapse"
                }
            }
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }

    // MARK: Пробные RAW-кадры (эксперимент)

    private let photoOut = AVCapturePhotoOutput()
    private var rawLeft = 0
    private var rawTotal = 0
    private var rawSaved = 0
    private var rawFormat: OSType = 0

    /// Серия RAW (DNG) по 1 с на максимальном ISO - сравнить с нашим кадром в Lightroom.
    /// Камера на время переключается в фото-формат, потом возвращается обратно
    func rawTest(count: Int = 5) {
        guard phase == .idle else { return }
        phase = .test
        subTotal = count
        subDone = 0
        status = "RAW: готовлю камеру..."
        UIApplication.shared.isIdleTimerDisabled = true
        let focusPos = focus
        queue.async {
            guard let dev = self.device else { return self.rawDone("Камера недоступна") }
            self.session.beginConfiguration()
            if !self.session.outputs.contains(self.photoOut), self.session.canAddOutput(self.photoOut) {
                self.session.addOutput(self.photoOut)
            }
            self.session.commitConfiguration()
            // Ищем формат, где фото-выход отдаёт Bayer RAW, начиная с самого большого фото
            func px(_ f: AVCaptureDevice.Format) -> Int {
                f.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
            }
            var found: OSType?
            for f in dev.formats.sorted(by: { px($0) > px($1) }).prefix(16) {
                if (try? dev.lockForConfiguration()) != nil {
                    dev.activeFormat = f
                    dev.unlockForConfiguration()
                }
                // Обычный RAW, а если его нет (на новых iPhone бывает только ProRAW) - ProRAW
                if self.photoOut.isAppleProRAWSupported { self.photoOut.isAppleProRAWEnabled = true }
                let types = self.photoOut.availableRawPhotoPixelFormatTypes
                if let r = types.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
                    ?? types.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
                    found = r
                    if let big = f.supportedMaxPhotoDimensions.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
                        self.photoOut.maxPhotoDimensions = big
                    }
                    break
                }
            }
            guard let raw = found else { return self.rawDone("RAW на этой камере недоступен") }
            self.rawFormat = raw
            if (try? dev.lockForConfiguration()) != nil {
                let d = min(1.0, CMTimeGetSeconds(dev.activeFormat.maxExposureDuration))
                dev.setExposureModeCustom(duration: CMTime(seconds: d, preferredTimescale: 1_000_000),
                                          iso: dev.activeFormat.maxISO, completionHandler: nil)
                if dev.isLockingFocusWithCustomLensPositionSupported {
                    dev.setFocusModeLocked(lensPosition: focusPos, completionHandler: nil)
                }
                dev.unlockForConfiguration()
            }
            self.rawLeft = count
            self.rawTotal = count
            self.rawSaved = 0
            DispatchQueue.main.async { self.status = "RAW: снимаю, не трогай телефон" }
            // Дать выдержке и фокусу встать
            self.queue.asyncAfter(deadline: .now() + 2.5) { self.shootRaw() }
        }
    }

    private func shootRaw() {
        let st = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        st.maxPhotoDimensions = photoOut.maxPhotoDimensions
        photoOut.capturePhoto(with: st, delegate: self)
    }

    fileprivate func rawFinished(_ data: Data?) {
        queue.async {
            if let d = data {
                let dir = Self.docs().appendingPathComponent("RAW", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let n = self.rawTotal - self.rawLeft + 1
                if (try? d.write(to: dir.appendingPathComponent("raw_\(f.string(from: Date()))_\(n).dng"))) != nil { self.rawSaved += 1 }
            }
            self.rawLeft -= 1
            let done = self.rawTotal - self.rawLeft
            DispatchQueue.main.async {
                self.subDone = done
                self.status = "RAW: снято \(done) из \(self.rawTotal)"
            }
            if self.rawLeft > 0 {
                self.queue.asyncAfter(deadline: .now() + 0.3) { self.shootRaw() }
            } else {
                self.rawDone(self.rawSaved > 0
                             ? "RAW: \(self.rawSaved) кадров в Файлы → NightLapse → RAW"
                             : "RAW не сохранился")
            }
        }
    }

    // MARK: Режим «Фото» и сравнение способов: снимки через фото-обработку iPhone

    /// Один способ снять: авто как в Камере или своя выдержка и ISO, сколько снимков сложить, подтягивать ли яркость
    struct PhotoJob {
        enum Look { case asIs, night(Float), nightContrast(Float) }
        var label: String
        var auto = false
        var dur = 1.0
        var iso: Float = 0          // 0 - максимальный, -2 - на 2 ступени ниже
        var count = 1
        var normalize = false
        var fast = false            // без тяжёлой обработки iPhone - сравнить, что она даёт
        var checkpoints: [Int] = []  // после скольких снимков сохранять промежуточное среднее (для сравнения)
        var looks: [Look] = []       // какие обработки сохранять в каждой точке
    }

    /// Идёт серия фото: снимки из делегата идут сюда, а не в RAW
    fileprivate var seriesActive = false
    private var jobs: [PhotoJob] = []
    private var jobIdx = 0
    private var jobsToGallery = true
    private var seriesAcc: [UInt32] = []
    /// Для сравнения: маленькая копия, кусок 100% из середины и подпись каждого варианта - потом два общих листа
    private var sheet: [(label: String, small: CGImage, crop: CGImage)] = []
    private var seriesW = 0
    private var seriesH = 0
    private var seriesN = 0
    private var seriesLeft = 0
    private var seriesTotal = 0
    private var seriesEV = 0.0
    private var seriesThumb: UIImage?
    private var seriesSaved = 0

    /// Режим «Фото». Днём - один снимок с автоэкспозицией, как в Камере. Ночью или с выдержкой, выставленной руками, -
    /// серия снимков до 1 с и их среднее: чем длиннее выдержка, тем больше снимков и тем чище кадр
    func photoSeries() {
        guard phase == .idle, let dev = device else { return }
        let fmt = dev.activeFormat
        var j = PhotoJob(label: "Фото")
        if isDark || expManual {
            let dmax = min(1.0, CMTimeGetSeconds(fmt.maxExposureDuration))
            j.count = min(60, max(1, Int((exposureSeconds / dmax - 0.001).rounded(.up))))
            j.dur = max(exposureSeconds / Double(j.count), CMTimeGetSeconds(fmt.minExposureDuration))
            if !isDark {
                // Яркость как в превью: то же количество света, только другой выдержкой
                j.iso = Float(Double(dev.iso) * CMTimeGetSeconds(dev.exposureDuration) / j.dur)
            }
            j.normalize = isDark
        } else {
            j.auto = true
        }
        j.checkpoints = [j.count]
        j.looks = [j.normalize ? .night(45) : .asIs]
        runJobs([j], toGallery: true)
    }

    /// Эксперимент: несколько способов подряд, все кадры - в «Тесты», чтобы сравнить и выбрать лучший
    /// Одни и те же снимки обрабатываются по-разному: кадров снимается немного, вариантов выходит много
    func compareTest() {
        let three: [PhotoJob.Look] = [.asIs, .night(45), .nightContrast(45)]
        runJobs([
            PhotoJob(label: "А авто как Камера", auto: true, checkpoints: [1], looks: [.asIs, .night(45)]),
            PhotoJob(label: "Б 1 с ISO макс", dur: 1, count: 16, checkpoints: [1, 4, 16], looks: three),
            PhotoJob(label: "В 1 с ISO ниже", dur: 1, iso: -2, count: 16, checkpoints: [4, 16], looks: three),
            PhotoJob(label: "Г 0.5 с ISO макс", dur: 0.5, count: 16, checkpoints: [16], looks: three),
            PhotoJob(label: "Д 1 с без обработки", dur: 1, count: 16, fast: true, checkpoints: [1, 16], looks: three),
            PhotoJob(label: "Е 1 с темнее", dur: 1, count: 16, checkpoints: [16], looks: [.night(30), .nightContrast(30)]),
        ], toGallery: false)
    }

    private func runJobs(_ list: [PhotoJob], toGallery: Bool) {
        guard phase == .idle else { return }
        let hold = startHold
        phase = .test
        subDone = 0
        subTotal = list.reduce(0) { $0 + $1.count }
        status = "Не трогай телефон \(hold) с..."
        UIApplication.shared.isIdleTimerDisabled = true
        let angle = captureAngle()
        let ev = evComp
        queue.async {
            guard let dev = self.device else { return self.jobsDone("Камера недоступна") }
            self.session.beginConfiguration()
            if !self.session.outputs.contains(self.photoOut), self.session.canAddOutput(self.photoOut) {
                self.session.addOutput(self.photoOut)
            }
            self.session.commitConfiguration()
            self.photoOut.maxPhotoQualityPrioritization = .quality
            if let big = dev.activeFormat.supportedMaxPhotoDimensions.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
                self.photoOut.maxPhotoDimensions = big
            }
            if let c = self.photoOut.connection(with: .video), c.isVideoRotationAngleSupported(angle) {
                c.videoRotationAngle = angle
            }
            self.jobs = list
            self.jobIdx = 0
            self.jobsToGallery = toGallery
            self.sheet = []
            self.seriesEV = ev
            self.seriesThumb = nil
            self.seriesSaved = 0
            self.seriesActive = true
            Diag.event("Фото: \(list.map { "\($0.label) \($0.count)×\($0.auto ? "авто" : String(format: "%.2f с", $0.dur))" }.joined(separator: "; "))")
            // Пока телефон успокоится после касания
            self.queue.asyncAfter(deadline: .now() + Double(hold)) { self.startJob() }
        }
    }

    /// queue: выставить выдержку способа и начать его снимки
    private func startJob() {
        guard seriesActive else { return }
        guard jobIdx < jobs.count, let dev = device else { return jobsDone(nil) }
        let j = jobs[jobIdx]
        let fmt = dev.activeFormat
        if (try? dev.lockForConfiguration()) != nil {
            if j.auto {
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                dev.setExposureTargetBias(min(max(Float(seriesEV), dev.minExposureTargetBias), dev.maxExposureTargetBias), completionHandler: nil)
            } else {
                var iso = j.iso > 0 ? j.iso : fmt.maxISO
                if j.iso < 0 { iso = fmt.maxISO * powf(2, j.iso) }   // -2: на 2 ступени ниже максимума
                iso = min(max(iso, fmt.minISO), fmt.maxISO)
                let d = min(max(j.dur, CMTimeGetSeconds(fmt.minExposureDuration)), CMTimeGetSeconds(fmt.maxExposureDuration))
                dev.setExposureModeCustom(duration: CMTime(seconds: d, preferredTimescale: 1_000_000), iso: iso, completionHandler: nil)
            }
            dev.unlockForConfiguration()
        }
        seriesAcc = []
        seriesW = 0
        seriesH = 0
        seriesN = 0
        seriesLeft = j.count
        seriesTotal = j.count
        let label = j.label
        DispatchQueue.main.async {
            self.status = self.jobs.count > 1 ? "\(label): снимаю" : (j.count > 1 ? "Снимаю \(j.count) кадров, не трогай телефон" : "Снимаю...")
        }
        // Выдержке встать: авто нужно чуть дольше
        queue.asyncAfter(deadline: .now() + (j.auto ? 1.5 : 1.2)) { self.shootSeries() }
    }

    private func shootSeries() {
        guard seriesActive else { return }
        let st = AVCapturePhotoSettings()
        st.photoQualityPrioritization = jobIdx < jobs.count && jobs[jobIdx].fast ? .speed : .quality
        st.maxPhotoDimensions = photoOut.maxPhotoDimensions
        photoOut.capturePhoto(with: st, delegate: self)
    }

    fileprivate func seriesShot(_ data: Data?) {
        queue.async {
            guard self.seriesActive else { return }
            // Нажали «Отмена» - дальше не снимаем, лишнего не сохраняем
            if self.phase != .test {
                self.seriesAcc = []
                return self.jobsDone("Отменено")
            }
            if let d = data, let src = CGImageSourceCreateWithData(d as CFData, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: 12000,
               ] as CFDictionary) {
                self.seriesAdd(cg)
                if self.jobs[self.jobIdx].checkpoints.contains(self.seriesN) { self.emitJob() }
            }
            self.seriesLeft -= 1
            DispatchQueue.main.async { self.subDone += 1 }
            if self.seriesLeft > 0 {
                self.shootSeries()
            } else {
                self.seriesAcc = []
                self.jobIdx += 1
                self.startJob()
            }
        }
    }

    /// Сложить снимок в сумму. Снимок читается в 16 бит на канал: при сильном осветлении не будет полос
    private func seriesAdd(_ cg: CGImage) {
        if seriesN == 0 {
            seriesW = cg.width
            seriesH = cg.height
            seriesAcc = [UInt32](repeating: 0, count: seriesW * seriesH * 4)
        }
        let w = seriesW, h = seriesH
        var px = [UInt16](repeating: 0, count: w * h * 4)
        var ok: Bool = px.withUnsafeMutableBytes { b in
            guard let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        if !ok {
            // Запасной путь: 8 бит, растянутые в 16
            var p8 = [UInt8](repeating: 0, count: w * h * 4)
            ok = p8.withUnsafeMutableBytes { b in
                guard let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            if ok { for i in 0..<px.count { px[i] = UInt16(p8[i]) * 257 } }
        }
        guard ok else { return }
        seriesAcc.withUnsafeMutableBufferPointer { a in
            px.withUnsafeBufferPointer { p in
                for i in 0..<a.count { a[i] &+= UInt32(p[i]) }
            }
        }
        seriesN += 1
    }

    /// queue: текущее среднее способа во всех нужных обработках -> в галерею (режим «Фото») или в «Тесты» (сравнение)
    private func emitJob() {
        let j = jobs[jobIdx]
        let n = seriesN, w = seriesW, h = seriesH
        guard n > 0 else { return }
        // Гистограмма яркости среднего (0...255): середина (небо) и 1% самых тёмных (чёрная точка)
        let div = Float(n) * 257
        var hist = [Int](repeating: 0, count: 256)
        var i = 0
        while i < seriesAcc.count {
            let l = (Float(seriesAcc[i]) * 0.3 + Float(seriesAcc[i + 1]) * 0.59 + Float(seriesAcc[i + 2]) * 0.11) / div
            hist[min(max(Int(l), 0), 255)] += 1
            i += 4 * 7
        }
        let all = hist.reduce(0, +)
        func pct(_ p: Double) -> Float {
            let need = Int(Double(all) * p)
            var acc = 0
            for (v, c) in hist.enumerated() { acc += c; if acc >= need { return Float(max(v, 1)) } }
            return 1
        }
        let median = pct(0.5), black = pct(0.01) * 0.9
        let ev = Float(pow(2, seriesEV + 0.5))
        for look in j.looks {
            var g: Float = 1
            var b: Float = 0
            var name = "как есть"
            switch look {
            case .asIs: break
            case .night(let t):
                g = min(max(t * ev / median, 0.5), 8)
                name = "ночь \(Int(t))"
            case .nightContrast(let t):
                b = black
                g = min(max(t * ev / max(median - b, 1), 0.5), 12)
                name = "ночь \(Int(t)) контраст"
            }
            // 8 бит на выходе + лёгкий шум против полос на гладком небе
            let k = g / div
            var out = [UInt8](repeating: 255, count: w * h * 4)
            seriesAcc.withUnsafeBufferPointer { a in
                out.withUnsafeMutableBufferPointer { o in
                    var seed: UInt32 = 12345
                    for i in 0..<a.count where i % 4 != 3 {
                        seed = seed &* 1664525 &+ 1013904223
                        let dither = Float(seed >> 24) / 256 - 0.5
                        o[i] = UInt8(min(255, max(0, (Float(a[i]) * k - b * g) + 0.5 + dither)))
                    }
                }
            }
            guard let prov = CGDataProvider(data: Data(out) as CFData),
                  let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                   provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { continue }
            if jobsToGallery {
                guard let jpg = ShootStore.jpeg(cg) else { continue }
                seriesThumb = ShootStore.thumbData(jpg, maxPixel: 600)
                let sem = DispatchSemaphore(value: 0)
                PHPhotoLibrary.shared().performChanges({
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpg, options: nil)
                }) { ok, _ in
                    if ok { self.seriesSaved += 1 }
                    sem.signal()
                }
                sem.wait()
            } else {
                let label = "\(j.label), \(n) кадр., \(name)"
                TestStore.save(cg, label: label)
                seriesSaved += 1
                // Для общих листов: уменьшенная копия и кусок неба 100% из середины
                let sw = 600, sh = max(1, h * 600 / max(w, 1))
                if let ctx = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                    ctx.interpolationQuality = .high
                    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: sw, height: sh))
                    let side = min(400, w, h)
                    // Кусок чуть выше середины - там обычно небо
                    let r = CGRect(x: (w - side) / 2, y: max(0, h / 3 - side / 2), width: side, height: side)
                    if let small = ctx.makeImage(), let crop = cg.cropping(to: r) {
                        sheet.append((label, small, crop))
                    }
                }
            }
        }
    }

    /// Два общих листа сравнения: все варианты целиком и куски 100% - удобно прислать одной картинкой
    private func makeSheets() {
        guard !sheet.isEmpty else { return }
        func render(_ cellW: Int, _ cellH: Int, _ cols: Int, _ pick: (Int) -> CGImage) -> CGImage? {
            let rows = (sheet.count + cols - 1) / cols
            let labelH = 34
            let size = CGSize(width: cols * cellW, height: rows * (cellH + labelH))
            let f = UIGraphicsImageRendererFormat()
            f.scale = 1
            let img = UIGraphicsImageRenderer(size: size, format: f).image { c in
                UIColor.black.setFill()
                c.fill(CGRect(origin: .zero, size: size))
                for (i, it) in sheet.enumerated() {
                    let x = (i % cols) * cellW, y = (i / cols) * (cellH + labelH)
                    UIImage(cgImage: pick(i)).draw(in: CGRect(x: x + 2, y: y + labelH, width: cellW - 4, height: cellH - 4))
                    (it.label as NSString).draw(in: CGRect(x: x + 6, y: y + 6, width: cellW - 12, height: labelH - 6),
                                                withAttributes: [.font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                                                                 .foregroundColor: UIColor.white])
                }
            }
            return img.cgImage
        }
        let sw = sheet[0].small.width, sh = sheet[0].small.height
        let whole = render(sw, sh, 4) { self.sheet[$0].small }
        let crops = render(400, 400, 4) { self.sheet[$0].crop }
        for (img, name) in [(whole, "ЛИСТ общий вид"), (crops, "ЛИСТ кусок неба 100%")] {
            guard let cg = img else { continue }
            TestStore.save(cg, label: name)
            if let jpg = ShootStore.jpeg(cg) {
                PHPhotoLibrary.shared().performChanges({
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpg, options: nil)
                }, completionHandler: nil)
            }
        }
        sheet = []
    }

    /// queue: убрать фото-выход, вернуть превью
    private func jobsDone(_ msg0: String?) {
        seriesActive = false
        if msg0 == nil && !jobsToGallery { makeSheets() }
        sheet = []
        session.beginConfiguration()
        if session.outputs.contains(photoOut) { session.removeOutput(photoOut) }
        session.commitConfiguration()
        let msg = msg0 ?? (jobsToGallery
            ? (seriesSaved > 0 ? "Фото в галерее" : "Фото не сохранилось")
            : "Сравнение готово: \(seriesSaved) вариантов в «Тестах», два общих листа - и в галерее")
        Diag.event(msg)
        let thumb = seriesThumb
        let showTests = msg0 == nil && !jobsToGallery && seriesSaved > 0
        DispatchQueue.main.async {
            if let t = thumb { self.lastImage = t }
            self.subDone = 0
            self.applyCamera()
            self.finished(msg)
            if showTests { self.testCount += 1 }
        }
    }

    /// Убрать фото-выход и вернуть видео-формат и настройки
    private func rawDone(_ msg: String) {
        session.beginConfiguration()
        if session.outputs.contains(photoOut) { session.removeOutput(photoOut) }
        session.commitConfiguration()
        Diag.event(msg)
        DispatchQueue.main.async {
            self.subDone = 0
            self.changeCamera()
            self.finished(msg)
        }
    }

    /// Если приложение закрылось посреди съёмки (вылет, система выгрузила), при следующем открытии
    /// в течение 15 минут съёмка продолжается сама через 10 секунд. Новая съёмка помнит, что она продолжение
    private func resumeIfInterrupted() {
        guard phase == .idle, let last = ShootStore.list().first, !last.done,
              let lastFrame = ShootStore.frameURLs(last.dir).last,
              let t = (try? FileManager.default.attributesOfItem(atPath: lastFrame.path))?[.modificationDate] as? Date,
              Date().timeIntervalSince(t) < 15 * 60 else { return }
        let info = ShootStore.readInfo(last.dir)
        if let u = info["until"] as? Double, u > 0 {
            guard u > Date().timeIntervalSince1970 + 60 else { return }   // время съёмки уже вышло
            resumeUntil = Date(timeIntervalSince1970: u)
        }
        resumeOf = last.id
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        Diag.event("Съёмка \(last.id) оборвалась в \(f.string(from: t)), продолжаю")
        UIApplication.shared.isIdleTimerDisabled = true
        startAt = Date().addingTimeInterval(10)
        countdown = 10
        phase = .waiting
        status = "Съёмка оборвалась в \(f.string(from: t)). Продолжаю - не трогай телефон"
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
        expManual = false
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

    /// queue: увеличение выбранного объектива без лупы
    private var baseCrop: CGFloat = 1

    /// Лупа для ручного фокуса: середина кадра крупно в 4 раза, чтобы видеть, точки звёзды или кружки
    func setLoupe(_ on: Bool) {
        queue.async {
            guard let dev = self.device else { return }
            // Плавно, как зум пальцами в Камере: туда и обратно
            guard (try? dev.lockForConfiguration()) != nil else { return }
            let z = min(max(on ? self.baseCrop * 4 : self.baseCrop, 1), dev.activeFormat.videoMaxZoomFactor)
            dev.ramp(toVideoZoomFactor: z, withRate: 6)
            dev.unlockForConfiguration()
        }
    }

    /// main. Экран погашен - картинку камеры на экран не выводим: меньше работы, меньше расход батареи.
    /// Съёмка от этого не зависит, кадры идут отдельно
    func setPreview(_ on: Bool) {
        previewLayer?.connection?.isEnabled = on
    }

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

    /// Экран всегда вертикальный (как в Камере), поэтому поворот кадра берём прямо из положения телефона
    private func captureAngle() -> CGFloat {
        switch UIDevice.current.orientation {
        case .portrait: return 90
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        case .portraitUpsideDown: return 270
        default: return coordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        }
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

    /// Ночью в Найтлапсе резкость по звёздам нужна до первого кадра: если её ещё нет, ищем сами
    var needsStarFocus: Bool { sceneKind == .stars && isDark && !starFocused }

    /// Что сделать сразу после поиска резкости (тест или старт, которые его вызвали)
    private var afterFocus: (() -> Void)?

    /// Режим «Фото»: тот же кадр, что «Тест», только в полном размере и сразу в галерею
    private var photoPending = false

    func takePhoto() {
        photoSeries()
    }

    func testFrame() {
        guard phase == .idle else { return }
        if needsStarFocus {
            afterFocus = { [weak self] in self?.testFrame() }
            starFocus()
            return
        }
        let c = makeConfig(name: "test")
        phase = .test
        subTotal = c.subNeeded
        subDone = 0
        status = "Не трогай телефон \(startHold) с..."
        let hold = startHold
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
            self.preFrames = 0
            self.calibSkip = 0
            self.setAutoGain(1)
            self.setFrameTarget(c.exposure)
            self.holdUntil = CACurrentMediaTime() + Double(hold)
            self.mode = .test
            self.beginCaptureExposure(s, forceFocus: ff)
        }
    }

    func start() {
        guard phase == .idle else { return }
        guard saveVideo || saveFrames else { status = "Включи сохранение видео или кадров"; return }
        if needsStarFocus {
            afterFocus = { [weak self] in self?.start() }
            starFocus()
            return
        }
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
        Haptic.heavy()
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
        autoStopAt = resumeUntil ?? (autoStopMin > 0 ? now.addingTimeInterval(Double(autoStopMin) * 60) : nil)
        infoUntil = autoStopAt?.timeIntervalSince1970
        infoContinues = resumeOf
        resumeUntil = nil
        resumeOf = nil
        phase = .recording
        status = "Не трогай телефон \(startHold) с..."
        let hold = startHold
        LiveStatus.shared.start(mode: sceneKind.title, battery: battery)
        batStart = nil
        batteryLeftH = nil
        batteryWarn = nil
        batWarnLogged = false
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
            self.preFrames = 0
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
            self.holdUntil = CACurrentMediaTime() + Double(hold)
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
            resumeUntil = nil
            resumeOf = nil
            finished("Отменено")
        case .test:
            afterFocus = nil
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
        LiveStatus.shared.update(state: "paused", note: why)
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
        LiveStatus.shared.update(state: "rec", note: "")
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

    private func finished(_ msg0: String) {
        let msg = (stopReason ?? "") + msg0
        stopReason = nil
        phase = .idle
        status = msg
        LiveStatus.shared.end(note: msg)
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

    // MARK: Заряд во время съёмки

    /// Сколько ещё продержится батарея при нынешнем расходе (часы); nil - пока не ясно или идёт зарядка
    @Published var batteryLeftH: Double?
    /// Предупреждение о заряде во время съёмки
    @Published var batteryWarn: String?
    private var batStart: (Date, Int)?
    private var batWarnLogged = false
    /// Почему съёмка остановилась сама (заряд, память) - допишется к итоговому сообщению
    private var stopReason: String?
    /// Для записи в info.json: до какого времени снимать и какую оборванную съёмку продолжает эта
    private var infoUntil: Double?
    private var infoContinues: String?
    /// Продолжение оборванной съёмки: до какого времени снимать
    private var resumeUntil: Date?
    private var resumeOf: String?

    private var charging: Bool {
        let s = UIDevice.current.batteryState
        return s == .charging || s == .full
    }

    /// Расход в процентах за час: по прошлым съёмкам, а до первой - 10%/ч
    var batteryRate: Double {
        let r = UserDefaults.standard.double(forKey: "batRate")
        return r > 0.5 ? r : 10
    }

    /// На этом заряде съёмка останавливается сама, с запасом: на морозе телефон может выключиться и при 5%,
    /// а видео и кадры ещё нужно дописать
    static let batteryStop = 8

    /// Сколько часов продержится батарея до остановки при обычном расходе (для подсказки до старта)
    var batteryHoursEstimate: Double { max(0, Double(battery - Self.batteryStop)) / batteryRate }

    private func watchBattery(_ now: Date) {
        guard battery >= 0 else { return }
        if charging {
            batStart = nil
            batteryLeftH = nil
            batteryWarn = nil
            return
        }
        guard let st = batStart else {
            batStart = (now, battery)
            return
        }
        let hours = now.timeIntervalSince(st.0) / 3600
        let used = Double(st.1 - battery)
        // Расход видно через 10 минут и хотя бы 2% - раньше цифры прыгают
        if hours >= 1.0 / 6 && used >= 2 {
            let rate = used / hours
            UserDefaults.standard.set(rate, forKey: "batRate")
            batteryLeftH = max(0, Double(battery - Self.batteryStop)) / rate
        }
        var warn: String?
        if let left = batteryLeftH {
            if let end = autoStopAt {
                let need = end.timeIntervalSince(now) / 3600
                if left < need {
                    warn = "Заряда хватит примерно на \(hoursText(left)), а до конца съёмки \(hoursText(need)). Подключи пауэрбанк"
                }
            } else if left < 1 {
                warn = "Заряда осталось примерно на \(hoursText(left)). Подключи пауэрбанк"
            }
        }
        if battery <= Self.batteryStop {
            // Пока телефон не выключился сам: останавливаем съёмку, чтобы видео и кадры успели сохраниться
            Diag.event("Батарея \(battery)%: съёмка остановлена, чтобы сохранить видео")
            stopReason = "Заряд кончался, съёмка остановлена заранее. "
            stop()
            return
        }
        if warn == nil && battery <= Self.batteryStop + 5 {
            warn = "Заряд \(battery)%: на \(Self.batteryStop)% съёмка остановится сама и всё сохранит"
        }
        if warn != batteryWarn {
            batteryWarn = warn
            if let w = warn, !batWarnLogged {
                batWarnLogged = true
                Diag.event("Заряд: " + w)
            }
            LiveStatus.shared.update(note: warn ?? "")
        }
    }

    /// 1 ч 20 мин, 35 мин
    func hoursText(_ h: Double) -> String {
        let m = Int((h * 60).rounded())
        if m < 60 { return "\(max(m, 1)) мин" }
        return m % 60 == 0 ? "\(m / 60) ч" : "\(m / 60) ч \(m % 60) мин"
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
        if phase == .recording || phase == .paused {
            watchBattery(now)
        }
        // Отсчёт «не трогай телефон»: сколько секунд осталось до первого кадра
        if phase == .recording || phase == .test || phase == .idle, status.hasPrefix("Не трогай телефон") {
            let left = holdUntil - CACurrentMediaTime()
            if left > 0 { status = "Не трогай телефон: \(Int(left.rounded(.up))) с до первого кадра" }
        }
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
        baseCrop = zoom.crop
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
            } else if dev.exposureTargetOffset > 2.5 {
                // Стало светло (включили днём, зажгли свет) - обратно на автоэкспозицию, без засвеченного кадра
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
    /// Сколько пробных кадров перед первым настоящим (не больше 3)
    private var preFrames = 0

    private func autoISOStep(mean: Float, full: Bool = false) {
        defer { updateFrameTarget() }
        // Половина поправки за кадр: новая выдержка доходит до кадра с задержкой, полная поправка раскачивала яркость
        // (на рассвете первые кадры прыгали 70 -> 86 -> 59 -> 89)
        let f = full ? lightFactor(mean: mean, limit: 4) : pow(lightFactor(mean: mean, limit: 1.26), 0.5)
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
        // Картинка для часов - и в простое, и во время съёмки
        if let wpb = CMSampleBufferGetImageBuffer(sampleBuffer) { WatchLink.shared.offer(wpb, portrait: vertical) }
        guard mode != .off, !suspended, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Первые 3 секунды после нажатия телефон ещё дрожит от касания - эти кадры пропускаем
        if CACurrentMediaTime() < holdUntil { return }
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

        if mode == .test && photoPending {
            mode = .off
            photoPending = false
            DispatchQueue.main.async { self.applyCamera() }
            let img = frame.flatMap { makeThumb($0, maxSide: 2000) }
            let full = frame.flatMap { makeThumb($0, maxSide: 10000) }?.cgImage
            Diag.event("Фото: подкадров \(n), сенсор \(String(format: "%.4f", CMTimeGetSeconds(curDur))) с, ISO \(Int(curISO)), выдержка \(cfg.exposure) с")
            DispatchQueue.main.async { self.lastImage = img; self.subDone = 0 }
            guard let cg = full, let data = ShootStore.jpeg(cg) else {
                DispatchQueue.main.async { self.finished("Фото не получилось") }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }) { ok, _ in
                DispatchQueue.main.async { self.finished(ok ? "Фото в галерее" : "Нет доступа к галерее") }
            }
            return
        }

        if mode == .test {
            mode = .off
            DispatchQueue.main.async { self.applyCamera() }
            let img = frame.flatMap { makeThumb($0, maxSide: 2000) }
            // Каждый тест сохраняется: до старта можно пролистать, увеличить и экспортировать
            if let cg = frame.flatMap({ makeThumb($0, maxSide: 4000) })?.cgImage { TestStore.save(cg) }
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
        if frame != nil, outIndex == 0, cfg.isoAuto, preFrames < 3, !sensorMaxed(),
           abs(lightFactor(mean: mean, limit: 4) - 1) > 0.08 {
            // Первый кадр заметно светлее или темнее нужного: в видео не пишем, сразу поправляем
            // и снимаем заново - иначе ролик начинается со вспышки
            preFrames += 1
            autoISOStep(mean: mean, full: true)
            Diag.event("Первый кадр: яркость \(Int(mean)), поправка, снимаю заново")
        } else if let f = frame {
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
            // Если включено «оставлять самое яркое» из подкадров - ночью шум от этого
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
                                           "device": Diag.model(), "camera": Diag.device,
                                           "until": infoUntil ?? 0, "continues": infoContinues ?? ""])
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
            LiveStatus.shared.update(frames: c, battery: self.battery, hot: self.hot, state: "rec", note: self.batteryWarn ?? "")
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
                end(ok ? "Видео сохранено в галерее телефона" : "Нет доступа к галерее телефона. Видео лежит в Файлы → NightLapse")
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

// MARK: - Значок батареи

/// Батарейка, заполненная ровно на настоящий процент заряда
struct BatteryGlyph: View {
    let level: Int
    var charging = false
    var color: Color = .white

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5).stroke(color, lineWidth: 1)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 1.2)
                        .fill(color)
                        .frame(width: max(0, (g.size.width - 3) * CGFloat(min(max(level, 0), 100)) / 100))
                        .padding(1.5)
                }
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 20, height: 10)
            RoundedRectangle(cornerRadius: 0.8).fill(color).frame(width: 1.5, height: 4)
        }
        .accessibilityLabel(level >= 0 ? "Заряд \(level)%" : "Заряд неизвестен")
    }
}

// MARK: - Отклик и цвета

/// Вибрация только одна - когда съёмка реально началась: понятно без взгляда на экран.
/// Во время съёмки телефон не вибрирует, чтобы не сдвинуть кадр
enum Haptic {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func heavy() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warn() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

/// Цвета интерфейса в одном месте. Приглушённые, не слепят.
/// Ночной режим - всё в тёмно-красном: красный свет меньше всего сбивает глаза, привыкшие к темноте
struct Pal {
    let night: Bool
    /// Главный цвет: выбранное, активное
    var accent: Color { night ? Color(red: 0.80, green: 0.24, blue: 0.20) : Color(red: 0.93, green: 0.79, blue: 0.42) }
    /// Обычный текст и значки
    var text: Color { night ? Color(red: 0.82, green: 0.32, blue: 0.27) : Color(white: 0.90) }
    /// Второстепенный текст
    var dim: Color { night ? Color(red: 0.55, green: 0.19, blue: 0.16) : Color(white: 0.60) }
    /// Предупреждение
    var warn: Color { night ? Color(red: 1.0, green: 0.45, blue: 0.30) : Color(red: 0.96, green: 0.48, blue: 0.44) }
    /// Подложка кнопок
    var fill: Color { night ? Color(red: 0.45, green: 0.06, blue: 0.05).opacity(0.38) : Color.white.opacity(0.12) }
    /// Кнопка записи
    var rec: Color { night ? Color(red: 0.70, green: 0.10, blue: 0.08) : Color(red: 0.90, green: 0.27, blue: 0.23) }
    /// Текст на выбранной (залитой accent) кнопке
    var onAccent: Color { Color.black }
}

struct ContentView: View {
    var onSwitch: () -> Void = {}
    /// Красный ночной интерфейс: 0 - сам, когда темно; 1 - всегда; 2 - никогда
    @AppStorage("redUI") private var redUI = 0
    private var t: Pal { Pal(night: redUI == 1 || (redUI == 0 && e.isDark)) }
    @StateObject private var e = LapseEngine()
    @State private var dark = false
    @State private var showFocusMenu = false
    /// Один раз ночью: подсказка, что фокус наведётся сам
    @AppStorage("focusHintSeen") private var focusHintSeen = false
    /// Экономия батареи: через 30 с после старта экран сам гаснет
    @AppStorage("autoDark") private var autoDark = true
    @State private var showTest = false
    /// Сколько пробных кадров сохранено
    @State private var savedTests = 0
    @State private var showSettings = false
    @State private var focusMark: CGPoint?
    @StateObject private var pole = PoleFinder()
    @State private var markTick = 0
    @State private var openParam: Param?
    /// Шторка с настройками съёмки, как панель в Камере: по касанию на сводку сверху
    @State private var panel = false
    /// Как в Камере: экран не переворачивается, поворачиваются только значки и подписи
    @State private var devAngle: Angle = .zero
    @State private var showShoots = false
    @AppStorage("guideSeen") private var guideSeen = false
    @State private var shootToOpen: URL?

    enum Param { case brightness, exposure, interval, duration, focus }

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
            WatchLink.shared.attach(e)
            if let p = UserDefaults.standard.string(forKey: "pendingScene"), let sc = LapseScene(rawValue: p) {
                UserDefaults.standard.removeObject(forKey: "pendingScene")
                e.applyScene(sc)
            }
        }
        .onDisappear { e.shutdown() }
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications(); turnIcons() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in turnIcons() }
        // Вернулся в приложение - выдержка снова сама: днём не будет кадра, выставленного под ночь
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            if idle && e.expManual { e.exposureAuto() }
        }
        .onChange(of: e.testCount) {
            showTest = true
            savedTests = TestStore.list().count
        }
        .task { savedTests = TestStore.list().count }
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
        .onChange(of: e.phase) {
            if e.phase != .idle { openParam = nil; panel = false }
            if e.phase == .recording && autoDark {
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    if e.phase == .recording { dark = true }
                }
            }
        }
        .onChange(of: dark) { e.setPreview(!dark) }
        .onChange(of: e.starFocused) { if e.starFocused { focusHintSeen = true } }
        .onChange(of: openParam) { e.setLoupe(openParam == .focus) }
        .onChange(of: e.focus) {
            // Ручной фокус: линза сразу едет в новое положение, найденное руками тоже считается найденным
            if openParam == .focus {
                e.focusAuto = false
                e.starFocused = true
                e.applyCamera()
            }
        }
        .onChange(of: e.lastShoot) {
            if let d = e.lastShoot {
                shootToOpen = d
                showShoots = true
            }
        }
        .sheet(isPresented: $showShoots, onDismiss: { shootToOpen = nil }) {
            ShootsView(open: shootToOpen)
        }
        .sheet(isPresented: $showTest) { nightSheet(testSheet) }
        .sheet(isPresented: $showSettings) {
            nightSheet(SettingsSheet(e: e))
                .presentationDetents([.medium, .large])
        }
        .traceScreen("Камера")
        .modifier(CameraTrace(e: e, open: openParam.map { "\($0)" } ?? "ничего"))
    }

    /// Шторки ночью тоже в красном: всё окрашивается красным, фон - чёрный
    private func nightSheet<V: View>(_ v: V) -> some View {
        v.colorMultiply(t.night ? Color(red: 1, green: 0.32, blue: 0.27) : Color.white)
            .presentationBackground(t.night ? Color.black : Color(white: 0.11))
    }

    // MARK: Верхняя полоса

    private var topBar: some View {
        HStack(spacing: 10) {
            infoChip
            Spacer(minLength: 0)
            if shooting { recTimer }
            Spacer(minLength: 0)
            if shooting {
                roundIcon("moon") { dark = true }
                    .accessibilityLabel("Погасить экран")
            } else {
                summaryPill
            }
        }
        .padding(.top, 4)
        .confirmationDialog("Фокус", isPresented: $showFocusMenu, titleVisibility: .visible) {
            Button("Вручную") {
                withAnimation(.easeOut(duration: 0.15)) { openParam = .focus }
            }
            Button("Авто") {
                // Ручная настройка закрывается, увеличение плавно уходит назад
                withAnimation(.easeOut(duration: 0.2)) { if openParam == .focus { openParam = nil } }
                e.resetFocusAuto()
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    /// Сводка сверху: интервал, яркость, длительность. Касание - шторка с настройками. Точка - есть предупреждение
    private var summaryPill: some View {
        Button {
            withAnimation(.spring(duration: 0.3)) {
                panel.toggle()
                if !panel { openParam = nil }
            }
        } label: {
            HStack(spacing: 7) {
                summaryText.monospacedDigit()
                Image(systemName: panel ? "xmark" : "ellipsis")
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .foregroundStyle(panel ? t.accent : t.text)
            .background(t.fill, in: Capsule())
            .overlay(alignment: .topTrailing) {
                if firstWarning != nil && !panel {
                    Circle().fill(t.warn).frame(width: 9, height: 9).offset(x: 2, y: -2)
                }
            }
        }
        .disabled(!idle)
        .accessibilityLabel("Настройки съёмки")
    }

    /// Интервал, выдержка, длительность - значками, как в шторке
    private var summaryText: Text {
        if e.sceneKind == .photo {
            return Text(Image(systemName: "stopwatch")) + Text(" \(expText(e.exposureSeconds))")
        }
        return Text(Image(systemName: "timer")) + Text(" \(expText(e.intervalSeconds))   ")
            + Text(Image(systemName: "stopwatch")) + Text(" \(expText(e.exposureSeconds))   ")
            + Text(Image(systemName: "hourglass")) + Text(e.autoStopMin == 0 ? " ∞" : " " + durText(Double(e.autoStopMin) * 60))
    }

    /// Значки смотрят вверх, как ни держи телефон. Лицом вверх или вниз - оставляем как было
    private func turnIcons() {
        let a: Double
        switch UIDevice.current.orientation {
        case .portrait: a = 0
        case .landscapeLeft: a = 90
        case .landscapeRight: a = -90
        case .portraitUpsideDown: a = 180
        default: return
        }
        withAnimation(.easeInOut(duration: 0.3)) { devAngle = .degrees(a) }
    }

    private func roundIcon(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 17, weight: .regular))
                .rotationEffect(devAngle)
                .frame(width: 44, height: 44)
                .foregroundStyle(t.text)
                .background(t.fill, in: Circle())
        }
    }

    private var charging: Bool {
        let st = UIDevice.current.batteryState
        return st == .charging || st == .full
    }

    private var infoChip: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                BatteryGlyph(level: e.battery, charging: charging, color: (0..<20).contains(e.battery) ? t.warn : t.dim)
                Text(e.battery >= 0 ? "\(e.battery)%" : "-")
            }
            Label(String(format: "%.0f ГБ", e.freeGB), systemImage: "internaldrive")
            if e.hot {
                Image(systemName: "thermometer.high").foregroundStyle(t.warn)
            }
        }
        .font(.caption.monospacedDigit())
        .labelStyle(.titleAndIcon)
        .foregroundStyle(t.dim)
    }

    /// Красный таймер, как при записи видео в Камере
    private var recTimer: some View {
        Text(e.phase == .waiting ? "Старт через \(hms(e.countdown))" : hms(e.elapsed))
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(e.phase == .recording ? t.rec : t.fill, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Кадр

    private var preview: some View {
        ZStack {
            CameraPreview(engine: e,
                          onTap: { dp, vp in
                              guard idle else { return }
                              // Касание по кадру сначала закрывает шторку, как в Камере
                              if panel {
                                  withAnimation(.spring(duration: 0.3)) { panel = false; openParam = nil }
                                  return
                              }
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
                              select((LapseScene.allCases.firstIndex(of: e.sceneKind) ?? 0) + d)
                          })
            if let m = focusMark { focusIndicator(at: m) }
            VStack(spacing: 6) {
                if e.phase == .recording || e.phase == .test {
                    ProgressView(value: Double(min(e.subDone, e.subTotal)), total: Double(max(e.subTotal, 1)))
                        .tint(t.rec)
                }
                if showStatus {
                    Text(statusLine)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(e.hot ? t.warn : t.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.55), in: Capsule())
                }
                if idle && e.sceneKind == .stars {
                    PolePill(p: pole, pal: t)
                }
                Spacer()
                if idle {
                    if panel { controlPanel } else { zoomRow }
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
                Button {
                            e.zoom = z.value
                } label: {
                    Text(sel ? z.title : z.title.replacingOccurrences(of: "x", with: ""))
                        .font(.system(size: sel ? 14 : 13, weight: .bold))
                        .rotationEffect(devAngle)
                        .foregroundStyle(sel ? t.accent : t.text)
                        .frame(width: sel ? 40 : 34, height: sel ? 40 : 34)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
            }
        }
        .padding(4)
        .background(t.fill, in: Capsule())
        .animation(.easeOut(duration: 0.15), value: e.zoom)
    }

    /// Жёлтая рамка фокуса и солнце яркости, как в Камере iPhone
    private func focusIndicator(at m: CGPoint) -> some View {
        GeometryReader { _ in
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(t.accent, lineWidth: 1.5)
                    .frame(width: 72, height: 72)
                    .position(m)
                VStack(spacing: 2) {
                    Image(systemName: "sun.max")
                    Text(String(format: "%+.1f", e.evComp)).font(.footnote.monospacedDigit())
                }
                .foregroundStyle(t.accent)
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
        var s = e.status
        if e.pauses > 0 && (e.phase == .recording || e.phase == .paused) { s += " · пауз: \(e.pauses)" }
        let cool = e.cooling && (e.phase == .recording || e.phase == .paused)
        if cool { s += " · нагрев: пауза +\(Int(e.coolExtra)) с" }
        if e.phase == .recording && e.effExposure > 0 && e.effExposure < e.exposureSeconds - 0.01 {
            s += " · выдержка \(expText(e.effExposure))"
        }
        if e.hot && !cool { s += " · телефон перегрет" }
        return s
    }

    // MARK: Низ: параметры, режимы, кнопка спуска

    private var bottomControls: some View {
        VStack(spacing: 10) {
            if idle {
                if !focusHintSeen && e.needsStarFocus {
                    HStack(spacing: 8) {
                        Image(systemName: "viewfinder")
                        Text("Фокус по звёздам - сам, ~15 с")
                        Button { focusHintSeen = true } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Понятно")
                    }
                    .font(.footnote)
                    .foregroundStyle(t.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(t.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                }
                modeCarousel
            } else if e.phase == .recording || e.phase == .paused {
                dashboard
            }
            shutterRow
        }
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.25), value: e.phase)
        .animation(.easeInOut(duration: 0.2), value: openParam)
        .animation(.easeInOut(duration: 0.2), value: firstWarning)
    }

    /// Во время съёмки - только главное, крупно: сколько идёт, сколько кадров, сколько видео и хватит ли заряда
    private var dashboard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                dashCell("Идёт", hms(e.elapsed))
                dashCell("Кадров", "\(e.framesDone)")
                dashCell("Видео", String(format: "%.1f с", Double(e.framesDone) / Double(max(e.fps, 1))))
            }
            .padding(.vertical, 10)
            .background(t.fill, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            if let w = e.batteryWarn {
                Text(w)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(t.warn)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            } else {
                Text(e.batteryLeftH.map { "Заряда хватит примерно на \(e.hoursText($0))" } ?? "Не двигай телефон")
                    .font(.footnote)
                    .foregroundStyle(t.dim)
            }
        }
        .transition(.opacity)
    }

    private func dashCell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(t.dim)
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(t.text)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Шторка настроек

    private var controlPanel: some View {
        VStack(spacing: 12) {
            if let p = openParam {
                HStack {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { openParam = nil }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(t.text)
                            .frame(width: 40, height: 40)
                            .background(t.fill, in: Circle())
                    }
                    .accessibilityLabel("Назад")
                    Spacer()
                    Text(paramTitle(p))
                        .font(.footnote.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(t.dim)
                    Spacer()
                    Color.clear.frame(width: 40, height: 40)
                }
                paramEditor(p)
                if p == .exposure, let w = exposureWarn {
                    Text(w).font(.footnote).foregroundStyle(t.dim).multilineTextAlignment(.center)
                } else if let w = warning(for: p) {
                    warnText(w)
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 14) {
                    // Выдержка вместо яркости: яркость - пальцем по кадру вверх-вниз
                    paramCircle(.exposure, "stopwatch",
                                e.expManual ? expText(e.exposureSeconds) : "авто \(expText(e.exposureSeconds))",
                                warn: false)
                    if e.sceneKind != .photo {
                        paramCircle(.interval, "timer", expText(e.intervalSeconds), warn: intervalWarn != nil)
                        paramCircle(.duration, "hourglass",
                                    e.autoStopMin == 0 ? "Пока не остановлю" : durText(Double(e.autoStopMin) * 60),
                                    warn: durationWarn != nil)
                    }
                    circleButton("viewfinder", "Фокус", focusShort, on: e.starFocused || openParam == .focus, warn: false) {
                        showFocusMenu = true
                    }
                    circleButton("moon", "Погасить", "экран", on: false, warn: false) {
                        panel = false
                        dark = true
                    }
                    circleButton("gearshape", "Настройки", "", on: false, warn: false) {
                        showSettings = true
                    }
                }
                if let w = firstWarning { warnText(w) }
                Text(planLine)
                    .font(.caption)
                    .foregroundStyle(t.dim)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 28).fill(t.night ? Color.black.opacity(0.88) : Color(white: 0.1).opacity(0.86)))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(t.fill, lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func paramTitle(_ p: Param) -> String {
        switch p {
        case .brightness: return "Яркость"
        case .exposure: return "Выдержка"
        case .interval: return "Интервал"
        case .duration: return "Длительность"
        case .focus: return "Фокус вручную"
        }
    }

    private func warning(for p: Param) -> String? {
        switch p {
        case .brightness: return evWarn
        case .exposure: return exposureWarn
        case .interval: return intervalWarn
        case .duration: return durationWarn
        case .focus: return nil
        }
    }

    private func warnText(_ w: String) -> some View {
        Text(w)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(t.warn)
            .multilineTextAlignment(.center)
    }

    private var focusShort: String {
        if e.starFocused { return "наведён" }
        if e.focusAuto || e.needsStarFocus { return "авто" }
        return e.focus >= 0.99 ? "вдаль" : "вручную"
    }

    private func paramCircle(_ p: Param, _ icon: String, _ value: String, warn: Bool) -> some View {
        circleButton(icon, paramTitle(p), value, on: false, warn: warn) {
            withAnimation(.easeOut(duration: 0.2)) { openParam = p }
        }
    }

    /// Круглая кнопка, как в шторке Камеры: значок, подпись, значение
    private func circleButton(_ icon: String, _ title: String, _ value: String, on: Bool, warn: Bool,
                              _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .rotationEffect(devAngle)
                    .foregroundStyle(on ? t.accent : (warn ? t.warn : t.text))
                    .frame(width: 56, height: 56)
                    .background(t.fill, in: Circle())
                    .overlay(Circle().stroke(warn ? t.warn.opacity(0.7) : Color.clear, lineWidth: 1.5))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(t.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(value.isEmpty ? " " : value)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(warn ? t.warn : t.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(title)
    }

    private var paramRow: some View {
        HStack(spacing: 8) {
            paramChip(.brightness, "Яркость", String(format: "%+.1f", e.evComp), warn: evWarn != nil)
            paramChip(.interval, "Интервал", expText(e.intervalSeconds), warn: intervalWarn != nil)
            paramChip(.duration, "Длительность", e.autoStopMin == 0 ? "Пока не остановлю" : durText(Double(e.autoStopMin) * 60), warn: durationWarn != nil)
        }
    }

    // MARK: Подсказки: значение краснеет, если по опыту прошлых съёмок выйдет плохо. Снимать всё равно можно

    /// Ночь: режим Найтлапс или темно по превью
    private var nightish: Bool { e.sceneKind == .stars || e.isDark }

    // Как выйдет кадр - покажет «Тест». Предупреждаем только о заряде и памяти
    private var evWarn: String? { nil }
    private var intervalWarn: String? { nil }

    private var durationWarn: String? {
        let hours = e.autoStopMin == 0 ? 8.0 : Double(e.autoStopMin) / 60
        let gb = hours * 3600 / max(e.intervalSeconds, 1) * 0.0025
        if e.freeGB > 0 && gb > e.freeGB * 0.9 {
            return "Памяти может не хватить: нужно около \(Int(gb.rounded())) ГБ"
        }
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        if e.battery >= 0 && !charging {
            let left = e.batteryHoursEstimate
            if left < hours {
                return e.autoStopMin == 0
                    ? "Заряда хватит примерно на \(e.hoursText(left)). Для долгой съёмки подключи пауэрбанк"
                    : "Заряда хватит примерно на \(e.hoursText(left)), а съёмка - \(durText(Double(e.autoStopMin) * 60)). Подключи пауэрбанк"
            }
        }
        return nil
    }


    /// Красное - только то, что правда испортит съёмку. Длинная выдержка - осознанный выбор, о ней тихо в самой настройке
    private var firstWarning: String? { e.sceneKind == .photo ? nil : durationWarn }

    private var exposureWarn: String? { nil }

    /// Подпись кнопки резкости: одно-два слова
    private var focusLabel: String {
        if e.starFocused { return "Фокус ✓" }
        if e.needsStarFocus { return "Фокус: авто" }
        if e.focusAuto { return "Фокус: авто" }
        return e.focus >= 0.99 ? "Фокус: вдаль" : "Фокус: вручную"
    }

    /// Кнопка параметра: сверху мелко что это, снизу значение. Высота 44 - попадёшь и в перчатках
    private func paramChip(_ p: Param, _ label: String, _ value: String, warn: Bool = false) -> some View {
        let on = openParam == p
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { openParam = on ? nil : p }
        } label: {
            VStack(spacing: 1) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .opacity(on ? 0.75 : 0.7)
                Text(value)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(on ? t.onAccent : (warn ? t.warn : t.text))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(on ? t.accent : t.fill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(warn && !on ? t.warn.opacity(0.6) : Color.clear))
        }
    }

    @ViewBuilder private func paramEditor(_ p: Param) -> some View {
        VStack(spacing: 6) {
            switch p {
            case .exposure:
                HStack(spacing: 16) {
                    stepButton("minus") { e.exposureStep(false) }
                        .disabled(!e.canExposureDown)
                        .opacity(e.canExposureDown ? 1 : 0.35)
                    Text(expText(e.exposureSeconds))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .frame(minWidth: 170)
                    stepButton("plus") { e.exposureStep(true) }
                        .disabled(!e.canExposureUp)
                        .opacity(e.canExposureUp ? 1 : 0.35)
                }
                if e.expManual {
                    Button("Вернуть авто") { e.exposureAuto() }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(t.accent)
                }
            case .brightness:
                HStack {
                    Image(systemName: "sun.min")
                    Slider(value: $e.evComp, in: -4...2, step: 0.1)
                        .tint(t.accent)
                    Image(systemName: "sun.max")
                }
                Text("Яркость \(String(format: "%+.1f", e.evComp))")
                    .font(.footnote)
                    .foregroundStyle(t.dim)
            case .interval:
                HStack(spacing: 16) {
                    stepButton("minus") { e.intervalDown() }
                    Text(expText(e.intervalSeconds))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .frame(minWidth: 170)
                    stepButton("plus") { e.intervalUp() }
                }
            case .focus:
                HStack(spacing: 10) {
                    stepButton("minus") { nudgeFocus(-0.005) }
                    Slider(value: $e.focus, in: 0.4...1)
                        .tint(t.accent)
                    stepButton("plus") { nudgeFocus(0.005) }
                }
                Text(e.isDark ? "Звёзды - самые мелкие точки" : "До самой чёткой картинки")
                    .font(.footnote)
                    .foregroundStyle(t.dim)
                    .multilineTextAlignment(.center)
            case .duration:
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach([0, 30, 60, 120, 240, 480], id: \.self) { m in
                            let sel = e.autoStopMin == m
                            Button { e.autoStopMin = m } label: {
                                Text(m == 0 ? "Пока не остановлю" : durText(Double(m) * 60))
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(sel ? t.onAccent : t.text)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(sel ? t.accent : t.fill, in: Capsule())
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

    private func nudgeFocus(_ d: Float) {
        e.focus = min(max(e.focus + d, 0.4), 1)
    }

    private func stepButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 38, height: 38)
                .foregroundStyle(t.text)
                .background(t.fill, in: Circle())
        }
    }

    private func zoomText(_ z: Double) -> String {
        abs(z - z.rounded()) < 0.01 ? "\(Int(z.rounded()))x" : String(format: "%.1fx", z)
    }

    private var intervalNote: String {
        let ex = expText(e.exposureSeconds)
        switch e.sceneKind {
        case .stars:
            if e.zoom > 1.01 && !e.expManual { return "На \(zoomText(e.zoom)) выдержка до \(ex)" }
            return e.pauseSeconds > 0.05 ? "Выдержка \(ex), пауза \(expText(e.pauseSeconds))" : "Выдержка \(ex), без пауз"
        case .clouds:
            return "Выдержка до \(ex)"
        case .photo:
            return "Выдержка \(ex)"
        }
    }

    /// Режимы листаются пальцем или касанием, как в Камере
    private var modeCarousel: some View {
        ModeCarousel(selected: LapseScene.allCases.firstIndex(of: e.sceneKind) ?? 0, accent: t.accent, text: t.text) {
            select($0)
        }
    }

    private func select(_ i: Int) {
        guard idle, i >= 0 else { return }
        let all = LapseScene.allCases
        if i >= all.count {
            onSwitch()
            return
        }
        openParam = nil
        e.applyScene(all[i])
    }

    private var shutterRow: some View {
        HStack {
            thumbButton.opacity(shooting ? 0 : 1).disabled(shooting)
            Spacer()
            shutterButton
            Spacer()
            testButton.opacity(shooting || e.sceneKind == .photo ? 0 : 1)
                .disabled(e.sceneKind == .photo)
        }
        .padding(.horizontal, 28)
    }

    @ViewBuilder private var thumbButton: some View {
        Button {
            shootToOpen = nil
            showShoots = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(t.fill)
                if let img = e.lastImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "film.stack").foregroundStyle(t.text)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.dim))
            .rotationEffect(devAngle)
        }
    }

    /// Большая кнопка: круг - старт, квадрат - стоп
    private var shutterButton: some View {
        Button {
            switch e.phase {
            case .idle:
                if e.sceneKind == .photo { e.takePhoto() } else { e.start() }
            case .recording, .paused: e.stop()
            case .test, .waiting: e.cancel()
            case .saving: break
            }
        } label: {
            ZStack {
                Circle().stroke(t.text, lineWidth: 4).frame(width: 78, height: 78)
                switch e.phase {
                case .idle:
                    // Фото - белая кнопка, как в Камере; съёмка - красная
                    Circle().fill(e.sceneKind == .photo ? t.text : t.rec).frame(width: 64, height: 64)
                case .recording, .paused:
                    RoundedRectangle(cornerRadius: 7).fill(t.rec).frame(width: 30, height: 30)
                case .test, .waiting:
                    Image(systemName: "xmark").font(.system(size: 26, weight: .bold)).foregroundStyle(t.text)
                case .saving:
                    ProgressView()
                }
            }
        }
        .disabled(e.phase == .saving)
        .accessibilityLabel(idle ? "Старт" : "Стоп")
    }

    /// Касание - пробный кадр, долгое нажатие - прошлые пробные кадры
    private var testButton: some View {
        VStack(spacing: 1) {
            if e.phase == .test {
                ProgressView()
            } else {
                Image(systemName: "camera.aperture").font(.system(size: 18, weight: .regular))
            }
            Text("Тест").font(.system(size: 11, weight: .semibold))
        }
        .rotationEffect(devAngle)
        .foregroundStyle(t.text)
        .frame(width: 56, height: 56)
        .background(t.fill, in: Circle())
        .contentShape(Circle())
        .opacity(idle || e.phase == .test ? 1 : 0.3)
        .overlay(alignment: .topTrailing) {
            // Сколько пробных кадров сохранено - касание открывает их
            if savedTests > 0 && idle {
                Text("\(savedTests)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(t.onAccent)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(t.accent, in: Capsule())
                    .offset(x: 4, y: -4)
                    .onTapGesture { showTest = true }
                    .accessibilityLabel("Прошлые тесты: \(savedTests)")
            }
        }
        .onTapGesture { if idle { e.testFrame() } }
        .onLongPressGesture(minimumDuration: 0.5) { if idle { showTest = true } }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Тест. Долгое нажатие - прошлые пробные кадры")
    }

    private var planLine: String {
        let interval = max(e.intervalSeconds, 0.01)
        let fps = Double(max(e.fps, 1))
        let videoPerHour = 3600 / interval / fps
        if e.sceneKind == .photo { return "Фото сразу в галерею" }
        var s = "\(e.sceneKind.hint) · 1 час = \(String(format: "%.0f", videoPerHour)) с видео"
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
                    if let w = e.batteryWarn { Text(w).foregroundStyle(t.warn) }
                    Text("Коснись, чтобы вернуться")
                }
                .font(.footnote)
                .foregroundStyle(t.dim)
            }
            .onTapGesture { dark = false }
    }

    private var testSheet: some View {
        TestViewer(pal: t)
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
             text: "Проведи пальцем по кадру влево или вправо - режим сменится, как в Камере: Кадр дня, Найтлапс, Таймлапс"),
        Page(icon: "viewfinder", title: "Фокус и яркость",
             text: "Ночью фокус по звёздам наводится сам перед первым кадром. Коснись кадра - фокус в этой точке, веди пальцем вверх-вниз - ярче или темнее"),
        Page(icon: "slider.horizontal.3", title: "Три кнопки внизу",
             text: "Яркость, интервал между кадрами и длительность съёмки. Если значение покраснело - так может выйти плохо, но снимать всё равно можно"),
        Page(icon: "record.circle", title: "Старт, тест и экспорт",
             text: "Красная кнопка - старт и стоп. «Тест» - пробный кадр, долгое нажатие на него - все прошлые тесты с увеличением. После «Стоп» откроется редактор: видео и фото, «Экспорт» с размером и качеством, склейка оборванной съёмки"),
        Page(icon: "moon", title: "Ночью",
             text: "Интерфейс сам становится красным, чтобы не слепить. Луна вверху гасит экран. «Где Полярная звезда?» на кадре подскажет, куда навести, чтобы следы стали кругами. Приложение следит за зарядом и памятью и остановится заранее, всё сохранив")
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
                                .foregroundStyle(Pal(night: false).accent)
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
                        .background(Pal(night: false).accent, in: Capsule())
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
    var accent: Color = Pal(night: false).accent
    var text: Color = Pal(night: false).text
    let onSelect: (Int) -> Void

    struct Item: Identifiable {
        let title: String
        let index: Int
        var id: Int { index }
    }

    var body: some View {
        // Как в Камере: Найтлапс, Таймлапс, Фото, а за Фото - Кадр дня
        let items: [Item] = LapseScene.allCases.enumerated().map { Item(title: $0.element.title, index: $0.offset) }
            + [Item(title: "Кадр дня", index: LapseScene.allCases.count)]
        let w: CGFloat = 86
        let sel = selected
        HStack(spacing: 0) {
            ForEach(items) { item in
                let i = item.index
                Button { if i != sel { onSelect(i) } } label: {
                    Text(item.title.uppercased())
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(i == sel ? accent : text)
                        .lineLimit(1)
                        .frame(width: w, height: 36)
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
    @AppStorage("autoDark") private var autoDark = true
    @AppStorage("redUI") private var redUI = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Красный интерфейс", selection: $redUI) {
                        Text("Авто").tag(0)
                        Text("Всегда").tag(1)
                        Text("Никогда").tag(2)
                    }
                } header: {
                    Text("Ночью")
                } footer: {
                    Text("Красный свет меньше всего сбивает глаза, привыкшие к темноте")
                }

                Section {
                    Toggle("Снимать в 4K", isOn: $e.uhd)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Баланс белого")
                            Spacer()
                            Text(e.wbAuto ? "Авто" : "\(Int(e.wbTemp)) K").foregroundStyle(.secondary).monospacedDigit()
                        }
                        HStack(spacing: 10) {
                            Button("Авто") { e.wbAuto = true }
                                .buttonStyle(.bordered)
                                .tint(e.wbAuto ? Pal(night: false).accent : .gray)
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
                    Text("Без 4K - Full HD 1080p: меньше места и заряда. Видео будет горизонтальным или вертикальным - как держишь телефон в момент старта")
                }

                Section("Сохранение") {
                    Toggle("Сразу экспортировать видео в галерею телефона", isOn: $e.saveVideo)
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
                    Toggle("Гасить экран через 30 с после старта", isOn: $autoDark)
                    Picker("Таймер перед кадрами", selection: $e.startHold) {
                        Text("3 с - крепкий штатив").tag(3)
                        Text("10 с - лёгкий штатив, ветер").tag(10)
                    }
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
                    Text("Приложение само записывает нажатия, экраны, подвисания, вылеты, настройки и данные по каждому кадру. Самопроверка показывает проблемы за сутки. Ничего не отправляется. Собери отчёт и пришли файл в чат с Claude")
                }

                Section {
                    Button("Сравнить способы съёмки") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { e.compareTest() }
                    }
                    Button("Снять 5 RAW-кадров по 1 с") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { e.rawTest() }
                    }
                } header: {
                    Text("Эксперимент")
                } footer: {
                    Text("Сравнение - около 3 минут на штативе, больше 25 вариантов в «Тестах». RAW - в Файлы → NightLapse → RAW")
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
        .traceScreen("Настройки")
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


// MARK: - RAW: приём готового снимка

extension LapseEngine: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if seriesActive {
            seriesShot(error == nil ? photo.fileDataRepresentation() : nil)
            return
        }
        rawFinished(error == nil && photo.isRawPhoto ? photo.fileDataRepresentation() : nil)
    }
}
