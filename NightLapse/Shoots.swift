// Съёмки и редактор: из одних и тех же кадров - таймлапс, Starlapse (растущие треки) и фото со следами.
// Исходные кадры только читаются, ничего не удаляется само.

import SwiftUI
import UIKit
import AVFoundation
import Photos
import ImageIO
import UniformTypeIdentifiers
import Accelerate

// MARK: - Хранилище съёмок

struct Shoot: Identifiable, Hashable {
    let dir: URL
    let frames: Int
    let bytes: Int64
    let date: Date
    let done: Bool
    let fps: Int
    let scene: String
    var id: String { dir.lastPathComponent }
}

enum ShootStore {
    static func docs() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func writeInfo(_ dir: URL, _ info: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: info) {
            try? d.write(to: dir.appendingPathComponent("info.json"), options: .atomic)
        }
    }

    static func readInfo(_ dir: URL) -> [String: Any] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("info.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    /// Съёмка закончена нормально (кнопкой «Стоп» или по времени)
    static func markDone(_ dir: URL) {
        var i = readInfo(dir)
        i["done"] = true
        writeInfo(dir, i)
    }

    static func frameURLs(_ dir: URL) -> [URL] {
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension.lowercased() == "jpg" && $0.lastPathComponent.hasPrefix("frame_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func load(_ dir: URL) -> Shoot {
        let fm = FileManager.default
        let urls = frameURLs(dir)
        var bytes: Int64 = 0
        for u in urls {
            if let a = try? fm.attributesOfItem(atPath: u.path), let n = a[.size] as? NSNumber { bytes += n.int64Value }
        }
        let info = readInfo(dir)
        var date = Date.distantPast
        if let t = info["created"] as? Double {
            date = Date(timeIntervalSince1970: t)
        } else if let a = try? fm.attributesOfItem(atPath: dir.path), let d = a[.creationDate] as? Date {
            date = d
        }
        return Shoot(dir: dir, frames: urls.count, bytes: bytes, date: date,
                     done: (info["done"] as? Bool) ?? false,
                     fps: (info["fps"] as? Int) ?? 30,
                     scene: (info["scene"] as? String) ?? "")
    }

    static func list() -> [Shoot] {
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(at: docs(), includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return all.filter { $0.lastPathComponent.hasSuffix("_frames") && $0.hasDirectoryPath }
            .map { load($0) }
            .filter { $0.frames > 0 }
            .sorted { $0.date > $1.date }
    }

    static func thumb(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Готовые результаты, которые приложение собрало прямо во время съёмки
    static func liveURL(_ dir: URL, _ look: Look, _ trail: Trail) -> URL? {
        switch look {
        case .starlapse: return dir.appendingPathComponent("starlapse_\(trail.rawValue).mov")
        case .startrail: return dir.appendingPathComponent("startrail.jpg")
        case .timelapse, .reel: return nil
        }
    }

    static func jpeg(_ img: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func full(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

// MARK: - Что делаем из кадров

enum Look: String, CaseIterable, Identifiable {
    case starlapse, timelapse, startrail, reel
    var id: String { rawValue }
    var title: String {
        switch self {
        case .starlapse: return "Starlapse"
        case .timelapse: return "Таймлапс"
        case .startrail: return "Фото"
        case .reel: return "Рилс 3в1"
        }
    }
    var hint: String {
        switch self {
        case .starlapse: return "Видео, где за звёздами тянутся хвосты"
        case .timelapse: return "Обычное видео, звёзды точками"
        case .startrail: return "Одна фотография: все кадры наложены, звёзды рисуют круги"
        case .reel: return "Вертикальное видео 1080×1920 для Instagram: сверху таймлапс, посередине средний след, снизу длинный"
        }
    }
    var isVideo: Bool { self != .startrail }
}

enum Trail: String, CaseIterable, Identifiable {
    case short, medium, long
    var id: String { rawValue }
    var title: String {
        switch self {
        case .short: return "Короткий"
        case .medium: return "Средний"
        case .long: return "Длинный"
        }
    }
    /// Во сколько раз гаснет старый след с каждым кадром (1 - не гаснет совсем)
    var decay: Float {
        switch self {
        case .short: return 0.85
        case .medium: return 0.95
        case .long: return 1
        }
    }
}

/// Кадр в памяти: BGRA, строки подряд
struct Frame {
    var w: Int
    var h: Int
    var px: [UInt8]
    /// Кадр загрузился нормально
    var ok = false

    init(w: Int, h: Int) {
        self.w = w
        self.h = h
        px = [UInt8](repeating: 0, count: w * h * 4)
    }

    mutating func draw(_ img: CGImage) {
        let w = self.w, h = self.h
        px.withUnsafeMutableBytes { buf in
            guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        ok = true
    }

    /// Из кадра камеры (BGRA, у строк может быть запас)
    mutating func load(from pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let rb = CVPixelBufferGetBytesPerRow(pb)
        let row = w * 4
        let h = self.h
        px.withUnsafeMutableBytes { dst in
            guard let dp = dst.baseAddress else { return }
            for y in 0..<h {
                memcpy(dp + y * row, base + y * rb, row)
            }
        }
        ok = true
    }

    /// След: старое гаснет по таблице, новое ложится сверху по правилу «оставить самое яркое»
    mutating func trail(with cur: Frame, lut: [UInt8]) {
        let n = px.count
        px.withUnsafeMutableBufferPointer { a in
            cur.px.withUnsafeBufferPointer { c in
                lut.withUnsafeBufferPointer { t in
                    guard let ap = a.baseAddress, let cp = c.baseAddress, let tp = t.baseAddress else { return }
                    var i = 0
                    while i < n {
                        let old = tp[Int(ap[i])]
                        let new = cp[i]
                        ap[i] = new > old ? new : old
                        i += 1
                    }
                }
            }
        }
    }

    /// Средняя яркость 0-255 (по каждой 16-й точке)
    func meanLuma() -> Double {
        var sum = 0.0, n = 0.0
        px.withUnsafeBufferPointer { p in
            var i = 0
            while i + 2 < p.count {
                sum += 0.114 * Double(p[i]) + 0.587 * Double(p[i + 1]) + 0.299 * Double(p[i + 2])
                n += 1
                i += 64
            }
        }
        return n > 0 ? sum / n : 0
    }

    func cgImage() -> CGImage? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let data = Data(px) as CFData
        guard let prov = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    func copy(to pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let rb = CVPixelBufferGetBytesPerRow(pb)
        let row = w * 4
        px.withUnsafeBytes { src in
            guard let sp = src.baseAddress else { return }
            for y in 0..<h {
                memcpy(base + y * rb, sp + y * row, row)
            }
        }
    }
}

/// Свет на сенсоре = ISO × выдержка подкадра. Звёздное небо - тысячи (ISO 5000 × 1 с),
/// пасмурный вечер днём - около 20. Меньше 300 - сумерки или день: следов звёзд там нет
func isNightLight(_ light: Double) -> Bool { light >= 300 }

/// Из журнала съёмки: какие кадры сняты в темноте (номер кадра → да/нет). Пусто, если журнала нет
func nightMap(_ dir: URL) -> [Int: Bool] {
    guard let text = try? String(contentsOf: dir.appendingPathComponent("log.csv"), encoding: .utf8) else { return [:] }
    var m: [Int: Bool] = [:]
    for line in text.split(separator: "\n").dropFirst() {
        let c = line.split(separator: ",")
        guard c.count > 4, let f = Int(c[1]), let s = Double(c[3]), let iso = Double(c[4]) else { continue }
        m[f] = isNightLight(iso * s)
    }
    return m
}

func decayLUT(_ d: Float) -> [UInt8] {
    (0..<256).map { UInt8(min(255, max(0, (Float($0) * d).rounded(.down)))) }
}

// MARK: - Обработка

final class Renderer: ObservableObject {
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var message = ""
    @Published var preview: UIImage?
    @Published var previewBusy = false

    private var cancelled = false
    private var previewToken = 0
    private let q = DispatchQueue(label: "nightlapse.render", qos: .userInitiated)

    func cancel() { cancelled = true }

    /// Быстрый просмотр на маленьких кадрах (не больше 150 кадров)
    func makePreview(_ shoot: Shoot, _ look: Look, _ trail: Trail) {
        previewToken += 1
        let token = previewToken
        previewBusy = true
        q.async {
            let urls = ShootStore.frameURLs(shoot.dir)
            guard !urls.isEmpty else {
                DispatchQueue.main.async { self.previewBusy = false }
                return
            }
            let step = max(1, urls.count / 150)
            let pick = stride(from: 0, to: urls.count, by: step).map { urls[$0] }
            var img: CGImage?
            if look == .startrail, let ready = ShootStore.liveURL(shoot.dir, look, trail),
               FileManager.default.fileExists(atPath: ready.path) {
                img = ShootStore.thumb(ready, maxPixel: 900)
            } else if look == .timelapse {
                img = ShootStore.thumb(urls[urls.count / 2], maxPixel: 900)
            } else if look == .reel, let first = ShootStore.thumb(pick[0], maxPixel: 900) {
                var mid = Frame(w: first.width, h: first.height)
                var accA = Frame(w: first.width, h: first.height)
                var accB = Frame(w: first.width, h: first.height)
                var cur = Frame(w: first.width, h: first.height)
                let lutA = decayLUT(pow(Trail.medium.decay, Float(step)))
                let lutB = decayLUT(1)
                for (k, u) in pick.enumerated() {
                    if token != self.previewToken { return }
                    guard let c = ShootStore.thumb(u, maxPixel: 900) else { continue }
                    cur.draw(c)
                    if k == pick.count / 2 { mid = cur }
                    accA.trail(with: cur, lut: lutA)
                    accB.trail(with: cur, lut: lutB)
                }
                var r = Frame(w: 540, h: 960)
                r.drawPanel(mid, y0: 0, w: 540, h: 318)
                r.drawPanel(accA, y0: 321, w: 540, h: 318)
                r.drawPanel(accB, y0: 642, w: 540, h: 318)
                img = r.cgImage()
            } else if let first = ShootStore.thumb(pick[0], maxPixel: 900) {
                var acc = Frame(w: first.width, h: first.height)
                var cur = Frame(w: first.width, h: first.height)
                let lut = decayLUT(look == .startrail ? 1 : pow(trail.decay, Float(step)))
                for u in pick {
                    if token != self.previewToken { return }
                    guard let c = ShootStore.thumb(u, maxPixel: 900) else { continue }
                    cur.draw(c)
                    acc.trail(with: cur, lut: lut)
                }
                img = acc.cgImage()
            }
            let ui = img.map { UIImage(cgImage: $0) }
            DispatchQueue.main.async {
                guard token == self.previewToken else { return }
                self.preview = ui
                self.previewBusy = false
            }
        }
    }

    func run(_ shoot: Shoot, _ look: Look, _ trail: Trail, denoise: Bool) {
        guard !busy else { return }
        busy = true
        cancelled = false
        progress = 0
        message = look == .startrail ? "Накладываю кадры..." : "Собираю видео..."
        UIApplication.shared.isIdleTimerDisabled = true
        let t0 = Date()
        q.async {
            let r: String
            // Готовый Starlapse из съёмки - без шумодава, поэтому с «Убрать шум» собираем заново
            // Если между кадрами были паузы, готовые следы из съёмки пунктирные - собираем заново с дорисовкой
            if let ready = ShootStore.liveURL(shoot.dir, look, trail), FileManager.default.fileExists(atPath: ready.path),
               !(denoise && look.isVideo), !GapFill.needed(shoot.dir) {
                r = self.saveReady(ready, isVideo: look.isVideo)
            } else if look == .startrail {
                r = self.renderPhoto(shoot)
            } else {
                r = self.renderMovie(shoot, look, trail, denoise: denoise)
            }
            Diag.event("Редактор: \(look.title) \(look == .starlapse ? trail.title : "")\(denoise && look.isVideo ? " без шума" : "") для \(shoot.id), \(shoot.frames) кадров, "
                + "\(Int(Date().timeIntervalSince(t0))) с: \(r)")
            DispatchQueue.main.async {
                self.busy = false
                self.message = r
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    /// Уже собрано во время съёмки: просто копия в Фото, файл остаётся в папке съёмки
    private func saveReady(_ url: URL, isVideo: Bool) -> String {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        var data: Data?
        if !isVideo { data = try? Data(contentsOf: url) }
        PHPhotoLibrary.shared().performChanges({
            if isVideo {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } else if let d = data {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: d, options: nil)
            }
        }) { s, _ in
            ok = s
            sem.signal()
        }
        sem.wait()
        DispatchQueue.main.async { self.progress = 1 }
        return ok ? "Сохранено в Фото" : "Нет доступа к Фото. Файл лежит в папке съёмки"
    }

    /// Читает кадры по 4 сразу на разных ядрах, потом склеивает по порядку
    private func eachFrame(_ urls: [URL], _ w: Int, _ h: Int, _ body: (Frame, Int) -> Void) -> Bool {
        let batch = 4
        var curs = (0..<batch).map { _ in Frame(w: w, h: h) }
        var i = 0
        while i < urls.count {
            if cancelled { return false }
            let n = min(batch, urls.count - i)
            let base = i
            curs.withUnsafeMutableBufferPointer { cb in
                DispatchQueue.concurrentPerform(iterations: n) { k in
                    autoreleasepool {
                        cb[k].ok = false
                        if let c = ShootStore.full(urls[base + k]), c.width == w, c.height == h { cb[k].draw(c) }
                    }
                }
            }
            for k in 0..<n where curs[k].ok { body(curs[k], base + k) }
            i += n
            report(i, urls.count)
        }
        return true
    }

    private func report(_ i: Int, _ n: Int) {
        let p = Double(i) / Double(max(n, 1))
        DispatchQueue.main.async { self.progress = p }
    }

    private func renderPhoto(_ shoot: Shoot) -> String {
        let urls = ShootStore.frameURLs(shoot.dir)
        guard let first = urls.first.flatMap({ ShootStore.full($0) }) else { return "Нет кадров" }
        var acc = Frame(w: first.width, h: first.height)
        let lut = decayLUT(1)
        let nm = nightMap(shoot.dir)
        let gap = GapFill(shoot.dir)
        var used = 0
        let done = eachFrame(urls, first.width, first.height) { raw, i in
            // Номер кадра в журнале = номер файла frame_00001 → 1
            // Без журнала (старые съёмки) пересвеченный кадр рассвета узнаётся по яркости
            guard nm.isEmpty ? raw.meanLuma() < 170 : (nm[i + 1] ?? true) else { return }
            var cur = raw
            gap.apply(&cur)
            acc.trail(with: cur, lut: lut)
            used += 1
        }
        if !done { return "Остановлено" }
        if used == 0 { return "Все кадры сняты днём или в сумерках. Фото со следами получается только в темноте" }
        guard let img = acc.cgImage(), let jpg = ShootStore.jpeg(img) else { return "Не удалось собрать фото" }
        // Копия рядом с исходниками, на случай если в Фото нет доступа
        try? jpg.write(to: shoot.dir.appendingPathComponent("startrail.jpg"))
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpg, options: nil)
        }) { s, _ in
            ok = s
            sem.signal()
        }
        sem.wait()
        return ok ? "Фото со следами сохранено в Фото" : "Нет доступа к Фото. Фото лежит в папке съёмки"
    }

    /// Видео из кадров: таймлапс, Starlapse или рилс «3 в 1» (таймлапс, средний след, длинный след друг под другом).
    /// denoise - убрать шум, сглаживая каждую точку по соседним кадрам
    private func renderMovie(_ shoot: Shoot, _ look: Look, _ trail: Trail, denoise: Bool) -> String {
        let urls = ShootStore.frameURLs(shoot.dir)
        guard let first = urls.first.flatMap({ ShootStore.full($0) }) else { return "Нет кадров" }
        let w = first.width, h = first.height
        let reel = look == .reel
        // Рилс: 1080×1920, три полосы по 636 с чёрными промежутками 6
        let ow = reel ? 1080 : w, oh = reel ? 1920 : h
        let name = shoot.dir.lastPathComponent.replacingOccurrences(of: "_frames", with: "")
        let out = ShootStore.docs().appendingPathComponent(name + "_" + look.rawValue + ".mov")
        try? FileManager.default.removeItem(at: out)
        guard let writer = try? AVAssetWriter(outputURL: out, fileType: .mov) else { return "Не удалось начать запись" }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            // Рилс - H.264, его без перекодирования принимают все соцсети
            AVVideoCodecKey: reel ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: ow,
            AVVideoHeightKey: oh,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: reel ? 20_000_000 : ow * oh * 18]
        ])
        input.expectsMediaDataInRealTime = false
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: ow,
            kCVPixelBufferHeightKey as String: oh
        ])
        guard writer.canAdd(input) else { return "Не удалось начать запись" }
        writer.add(input)
        guard writer.startWriting() else { return "Не удалось начать запись" }
        writer.startSession(atSourceTime: .zero)

        let fps = Int32(max(shoot.fps, 1))
        var dn = TemporalDenoise()
        var accA = Frame(w: w, h: h)          // Starlapse (или средний след в рилсе)
        var accB = Frame(w: w, h: h)          // длинный след в рилсе
        let lutA = decayLUT(reel ? Trail.medium.decay : trail.decay)
        let lutB = decayLUT(Trail.long.decay)
        var reelFrame = Frame(w: ow, h: oh)
        var idx: Int64 = 0
        let nm = nightMap(shoot.dir)
        let gap = GapFill(shoot.dir)
        let done = eachFrame(urls, w, h) { raw, i in
            var cur = raw
            if denoise { dn.apply(&cur) }
            let night = nm.isEmpty ? cur.meanLuma() < 170 : (nm[i + 1] ?? true)
            if look != .timelapse {
                // Для следов - кадр с дорисованным путём звёзд, в таймлапсе-полосе рилса - как снят
                var tr = cur
                if night { gap.apply(&tr) }
                if night { accA.trail(with: tr, lut: lutA) } else { accA = cur }
                if reel {
                    if night { accB.trail(with: tr, lut: lutB) } else { accB = cur }
                }
            }
            let src: Frame
            if reel {
                reelFrame.drawPanel(cur, y0: 0, w: 1080, h: 636)
                reelFrame.drawPanel(accA, y0: 642, w: 1080, h: 636)
                reelFrame.drawPanel(accB, y0: 1284, w: 1080, h: 636)
                src = reelFrame
            } else {
                src = look == .timelapse ? cur : accA
            }
            var pbo: CVPixelBuffer?
            if let pool = ad.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbo)
            } else {
                CVPixelBufferCreate(nil, ow, oh, kCVPixelFormatType_32BGRA, nil, &pbo)
            }
            guard let pb = pbo else { return }
            src.copy(to: pb)
            var tries = 0
            while !input.isReadyForMoreMediaData && tries < 500 {
                usleep(10_000)
                tries += 1
            }
            if ad.append(pb, withPresentationTime: CMTime(value: idx, timescale: fps)) { idx += 1 }
        }
        if !done {
            input.markAsFinished()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: out)
            return "Остановлено"
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed, idx > 0 else { return "Ошибка записи видео" }
        var ok = false
        let s2 = DispatchSemaphore(value: 0)
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: out)
        }) { s, _ in
            ok = s
            s2.signal()
        }
        s2.wait()
        if ok { try? FileManager.default.removeItem(at: out) }
        return ok ? (reel ? "Рилс сохранён в Фото" : "Видео сохранено в Фото") : "Нет доступа к Фото. Видео лежит в Файлы → NightLapse"
    }
}

/// Шум по времени: точка, которая от кадра к кадру меняется чуть-чуть, - это шум, её сглаживаем.
/// Если меняется сильно (звезда сдвинулась, проехала машина) - берём как есть, без шлейфов
struct TemporalDenoise {
    private var prev: [UInt8] = []

    mutating func apply(_ f: inout Frame) {
        guard prev.count == f.px.count else {
            prev = f.px
            return
        }
        let n = f.px.count
        prev.withUnsafeMutableBufferPointer { p in
            f.px.withUnsafeMutableBufferPointer { c in
                guard let pp = p.baseAddress, let cp = c.baseAddress else { return }
                var i = 0
                while i < n {
                    let a = Int(pp[i]), d = Int(cp[i]) - a
                    if d > -12 && d < 12 {
                        let v = UInt8(a + d * 2 / 5)
                        pp[i] = v
                        cp[i] = v
                    } else {
                        pp[i] = cp[i]
                    }
                    i += 1
                }
            }
        }
    }
}

extension Frame {
    /// Кладёт уменьшенный кадр полосой w×h на высоте y0: заполняет полосу целиком, лишнее по краям обрезается
    mutating func drawPanel(_ src: Frame, y0: Int, w pw: Int, h ph: Int) {
        let s = max(Double(pw) / Double(src.w), Double(ph) / Double(src.h))
        let sw = max(pw, Int((Double(src.w) * s).rounded())), sh = max(ph, Int((Double(src.h) * s).rounded()))
        var tmp = [UInt8](repeating: 0, count: sw * sh * 4)
        let srcW = src.w, srcH = src.h
        src.px.withUnsafeBytes { sp in
            tmp.withUnsafeMutableBytes { tp in
                guard let sb = sp.baseAddress, let tb = tp.baseAddress else { return }
                var a = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: sb), height: vImagePixelCount(srcH),
                                      width: vImagePixelCount(srcW), rowBytes: srcW * 4)
                var b = vImage_Buffer(data: tb, height: vImagePixelCount(sh), width: vImagePixelCount(sw), rowBytes: sw * 4)
                vImageScale_ARGB8888(&a, &b, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        let x0 = (sw - pw) / 2, yc = (sh - ph) / 2
        let rowW = self.w
        let rows = min(ph, self.h - y0)
        guard rows > 0 else { return }
        px.withUnsafeMutableBytes { op in
            tmp.withUnsafeBytes { tp in
                guard let ob = op.baseAddress, let tb = tp.baseAddress else { return }
                for y in 0..<rows {
                    memcpy(ob + ((y0 + y) * rowW) * 4, tb + ((yc + y) * sw + x0) * 4, pw * 4)
                }
            }
        }
    }
}

// MARK: - Список съёмок

struct ShootsView: View {
    var open: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var shoots: [Shoot] = []
    @State private var path: [Shoot] = []
    @State private var loaded = false

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if loaded && shoots.isEmpty {
                    Text("Пока нет съёмок. После «Стоп» съёмка появится здесь")
                        .foregroundStyle(.secondary)
                }
                ForEach(shoots) { s in
                    NavigationLink(value: s) {
                        HStack(spacing: 12) {
                            ShootThumb(dir: s.dir)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Self.fmt.string(from: s.date)).font(.headline)
                                Text("\(s.frames) кадров · \(sizeText(s.bytes))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !s.done {
                                    Text("Съёмка оборвалась, кадры целы")
                                        .font(.caption)
                                        .foregroundStyle(Color.orange)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Съёмки")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Shoot.self) { s in
                ShootEditor(shoot: s) { reload() }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .onAppear {
            reload()
            if let o = open, let s = shoots.first(where: { $0.dir.lastPathComponent == o.lastPathComponent }) {
                path = [s]
            }
        }
    }

    private func reload() {
        shoots = ShootStore.list()
        loaded = true
    }
}

func sizeText(_ b: Int64) -> String {
    let g = Double(b) / 1_000_000_000
    return g >= 1 ? String(format: "%.1f ГБ", g) : String(format: "%.0f МБ", Double(b) / 1_000_000)
}

struct ShootThumb: View {
    let dir: URL
    @State private var img: UIImage?

    var body: some View {
        Color(white: 0.15)
            .frame(width: 64, height: 64)
            .overlay {
                if let img { Image(uiImage: img).resizable().scaledToFill() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: dir) {
                let d = dir
                img = await Task.detached {
                    ShootStore.frameURLs(d).first.flatMap { ShootStore.thumb($0, maxPixel: 200) }.map { UIImage(cgImage: $0) }
                }.value
            }
    }
}

// MARK: - Редактор съёмки

struct ShootEditor: View {
    let shoot: Shoot
    var onDeleted: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @StateObject private var r = Renderer()
    @State private var look: Look = .starlapse
    @State private var trail: Trail = .medium
    @AppStorage("denoise") private var denoise = true
    @State private var confirmDelete = false

    /// Собрано во время съёмки - сохранится мгновенно
    private var isReady: Bool {
        if denoise && look.isVideo { return false }
        guard let u = ShootStore.liveURL(shoot.dir, look, trail) else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ZStack {
                    Color(white: 0.08)
                    if let p = r.preview {
                        Image(uiImage: p).resizable().scaledToFit()
                    }
                    if r.previewBusy { ProgressView() }
                }
                .aspectRatio(look == .reel ? 0.75 : 16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Picker("Что сделать", selection: $look) {
                    ForEach(Look.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(r.busy)

                if look == .starlapse {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Длина следа").font(.footnote).foregroundStyle(.secondary)
                        Picker("Длина следа", selection: $trail) {
                            ForEach(Trail.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .disabled(r.busy)
                    }
                }

                if look.isVideo {
                    Toggle("Убрать шум", isOn: $denoise)
                        .disabled(r.busy)
                }

                Text(look.hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if r.busy {
                    VStack(spacing: 8) {
                        ProgressView(value: r.progress)
                        Text("\(r.message) \(Int(r.progress * 100))%. Не сворачивай приложение")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Остановить") { r.cancel() }
                            .buttonStyle(.bordered)
                    }
                } else {
                    Button {
                        r.run(shoot, look, trail, denoise: denoise)
                    } label: {
                        Label(isReady ? "Сохранить в Фото (уже готово)" : "Собрать и сохранить в Фото", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    if !r.message.isEmpty {
                        Text(r.message).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Divider().padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Исходники: \(shoot.frames) кадров, \(sizeText(shoot.bytes))").font(.footnote.weight(.semibold))
                    Text("Лежат в Файлы → На iPhone → NightLapse → \(shoot.dir.lastPathComponent). Отсюда их можно скопировать на компьютер. Редактор их только читает")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Удалить исходники", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(r.busy)
            }
            .padding()
        }
        .navigationTitle("Съёмка")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(r.busy)
        .interactiveDismissDisabled(r.busy)
        .onAppear { r.makePreview(shoot, look, trail) }
        .onChange(of: look) { r.makePreview(shoot, look, trail) }
        .onChange(of: trail) { r.makePreview(shoot, look, trail) }
        .onDisappear { r.cancel() }
        .alert("Удалить исходники?", isPresented: $confirmDelete) {
            Button("Удалить навсегда", role: .destructive) {
                try? FileManager.default.removeItem(at: shoot.dir)
                onDeleted()
                dismiss()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("\(shoot.frames) кадров будут удалены навсегда. Видео и фото, уже сохранённые в Фото, останутся")
        }
    }
}

// MARK: - Журнал для улучшения приложения
// Ничего не отправляется само: журнал лежит в телефоне, отчёт собирается кнопкой в настройках и отправляется вручную.

enum Diag {
    private static let q = DispatchQueue(label: "nightlapse.diag", qos: .utility)
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static var dir: URL {
        let d = ShootStore.docs().appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Папка текущей съёмки: события и строки по кадрам пишутся и туда
    static var shootDir: URL?
    /// Камера, формат, пределы сенсора - пишется в каждую съёмку
    static var device = ""

    static let csvHeader = "t_s,frame,subframes,sensor_s,iso,gain,frame_target_s,mean_luma,pause_s,extra_pause_s,proc_ms,thermal,battery,free_gb"

    static func model() -> String {
        var s = utsname()
        uname(&s)
        let m = withUnsafeBytes(of: &s.machine) { b in String(decoding: b.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return "\(m), iOS \(UIDevice.current.systemVersion)"
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }

    private static func append(_ line: String, to url: URL) {
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Событие: старт, пауза, нагрев, ошибка...
    static func event(_ text: String) {
        let line = "\(fmt.string(from: Date()))  \(text)"
        let sd = shootDir
        q.async {
            let app = dir.appendingPathComponent("app.log")
            // Журнал не растёт бесконечно: больше 2 МБ - начинается заново
            if let a = try? FileManager.default.attributesOfItem(atPath: app.path),
               let n = a[.size] as? NSNumber, n.intValue > 2_000_000 {
                try? FileManager.default.removeItem(at: app)
            }
            append(line, to: app)
            if let d = sd { append(line, to: d.appendingPathComponent("events.txt")) }
        }
    }

    /// Начало новой съёмки: шапка таблицы по кадрам
    static func beginShoot(_ d: URL, _ settings: String) {
        shootDir = d
        q.async {
            append(csvHeader, to: d.appendingPathComponent("log.csv"))
            append("Устройство: \(model())\n\(device)\nНастройки: \(settings)", to: d.appendingPathComponent("events.txt"))
        }
    }

    static func endShoot() {
        q.async {}
        shootDir = nil
    }

    /// Строка по кадру
    static func frame(_ values: [String]) {
        guard let d = shootDir else { return }
        let line = values.joined(separator: ",")
        q.async { append(line, to: d.appendingPathComponent("log.csv")) }
    }

    /// Отчёт одним zip-файлом: журнал, данные последних съёмок и по 3 уменьшенных кадра. Исходники не трогаются
    static func makeReport(completion: @escaping (URL?) -> Void) {
        q.async {
            let fm = FileManager.default
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd_HH-mm"
            let name = "NightLapse_report_\(stamp.string(from: Date()))"
            let tmp = fm.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
            try? fm.removeItem(at: tmp)
            try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let app = dir.appendingPathComponent("app.log")
            if fm.fileExists(atPath: app.path) { try? fm.copyItem(at: app, to: tmp.appendingPathComponent("app.log")) }
            var settings = "Устройство: \(model())\n\(device)\n\nНастройки приложения:\n"
            if let all = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") {
                for k in all.keys.sorted() where !k.hasPrefix("NS") && !k.hasPrefix("Apple") {
                    settings += "\(k) = \(all[k] ?? "")\n"
                }
            }
            try? settings.write(to: tmp.appendingPathComponent("device_and_settings.txt"), atomically: true, encoding: .utf8)

            for s in ShootStore.list().prefix(3) {
                let sd = tmp.appendingPathComponent(s.id, isDirectory: true)
                try? fm.createDirectory(at: sd, withIntermediateDirectories: true)
                for f in ["info.json", "log.csv", "events.txt"] {
                    let u = s.dir.appendingPathComponent(f)
                    if fm.fileExists(atPath: u.path) { try? fm.copyItem(at: u, to: sd.appendingPathComponent(f)) }
                }
                let frames = ShootStore.frameURLs(s.dir)
                var pick: [URL] = []
                if let f = frames.first { pick.append(f) }
                if frames.count > 2 { pick.append(frames[frames.count / 2]) }
                if frames.count > 1, let l = frames.last { pick.append(l) }
                // Один кадр в полном размере - чтобы видеть резкость и шум
                if let f = frames.dropFirst(frames.count / 2).first {
                    try? fm.copyItem(at: f, to: sd.appendingPathComponent("full_" + f.lastPathComponent))
                }
                for f in pick {
                    if let cg = ShootStore.thumb(f, maxPixel: 1600), let d = ShootStore.jpeg(cg) {
                        try? d.write(to: sd.appendingPathComponent("small_" + f.lastPathComponent))
                    }
                }
                let st = s.dir.appendingPathComponent("startrail.jpg")
                if let cg = ShootStore.thumb(st, maxPixel: 1600), let d = ShootStore.jpeg(cg) {
                    try? d.write(to: sd.appendingPathComponent("startrail_small.jpg"))
                }
            }

            // zip силами системы
            var result: URL?
            var err: NSError?
            NSFileCoordinator().coordinate(readingItemAt: tmp, options: .forUploading, error: &err) { zip in
                let dest = fm.temporaryDirectory.appendingPathComponent(name + ".zip")
                try? fm.removeItem(at: dest)
                if (try? fm.copyItem(at: zip, to: dest)) != nil { result = dest }
            }
            try? fm.removeItem(at: tmp)
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// Кнопка в настройках: собрать отчёт и отправить его (например, сохранить в Файлы и прислать в чат)
struct ReportRow: View {
    @State private var busy = false
    @State private var url: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let u = url {
                ShareLink(item: u) {
                    Label("Отправить отчёт", systemImage: "square.and.arrow.up")
                }
            } else {
                Button {
                    busy = true
                    Diag.makeReport { u in
                        url = u
                        busy = false
                    }
                } label: {
                    HStack {
                        Label("Собрать отчёт", systemImage: "doc.text.magnifyingglass")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy)
            }
        }
    }
}

// MARK: - Дорисовка следов между кадрами

/// Если между кадрами была пауза (выдержка 7 с, интервал 30 с), звезда на фото со следами
/// рисует пунктир. Здесь путь звезды между соседними кадрами дорисовывается: по первым кадрам
/// находим, куда сдвигается небо в каждой части кадра, и протягиваем каждую звезду назад
/// к её прошлому месту. Деревья и горы не трогаем - тянутся только яркие точки над фоном
final class GapFill {
    private(set) var on: Bool
    private let gx = 6, gy = 4
    private var shift: [SIMD2<Float>]?
    private var prevPts: [[(x: Int, y: Int, v: Int)]]?
    private var tries = 0

    /// Нужна ли дорисовка: пауза больше четверти интервала
    static func needed(_ dir: URL) -> Bool {
        let info = ShootStore.readInfo(dir)
        let pause = (info["pause"] as? Double) ?? 0
        let interval = (info["interval"] as? Double) ?? 0
        return interval > 0 && pause / interval > 0.25
    }

    init(_ dir: URL) {
        on = GapFill.needed(dir)
    }

    /// Вызывать для каждого ночного кадра по порядку, до наложения следа
    func apply(_ f: inout Frame) {
        guard on, f.ok else { return }
        let bg = blockMeans(f)
        if shift == nil {
            let pts = stars(f, bg)
            if let p = prevPts { estimate(p, pts) }
            prevPts = pts
            tries += 1
            if shift == nil && tries > 6 { on = false }
            if shift == nil { return }
        }
        fill(&f, bg)
    }

    // Средний фон блоками 16x16 по каждому каналу
    private let blk = 16
    private func blockMeans(_ f: Frame) -> [Float] {
        let bw = (f.w + blk - 1) / blk, bh = (f.h + blk - 1) / blk
        var sum = [Float](repeating: 0, count: bw * bh * 3)
        var cnt = [Float](repeating: 0, count: bw * bh)
        f.px.withUnsafeBufferPointer { p in
            var y = 0
            while y < f.h {
                let by = y / blk
                var x = 0
                while x < f.w {
                    let o = (y * f.w + x) * 4
                    let b = by * bw + x / blk
                    sum[b * 3] += Float(p[o]); sum[b * 3 + 1] += Float(p[o + 1]); sum[b * 3 + 2] += Float(p[o + 2])
                    cnt[b] += 1
                    x += 2
                }
                y += 2
            }
        }
        for b in 0..<(bw * bh) where cnt[b] > 0 {
            sum[b * 3] /= cnt[b]; sum[b * 3 + 1] /= cnt[b]; sum[b * 3 + 2] /= cnt[b]
        }
        return sum
    }

    // Звёзды: местные максимумы зелёного, заметно ярче фона. По каждой части кадра
    private func stars(_ f: Frame, _ bg: [Float]) -> [[(x: Int, y: Int, v: Int)]] {
        var out = [[(x: Int, y: Int, v: Int)]](repeating: [], count: gx * gy)
        let bw = (f.w + blk - 1) / blk
        let w = f.w, h = f.h
        f.px.withUnsafeBufferPointer { p in
            for y in 2..<(h - 2) {
                for x in 2..<(w - 2) {
                    let o = (y * w + x) * 4 + 1
                    let g = Int(p[o])
                    let b = Int(bg[((y / blk) * bw + x / blk) * 3 + 1])
                    guard g > b + 25 else { continue }
                    if g < Int(p[o - 4]) || g < Int(p[o + 4]) || g < Int(p[o - w * 4]) || g < Int(p[o + w * 4]) { continue }
                    if g == Int(p[o - 4]) || g == Int(p[o - w * 4]) { continue }
                    let t = min(gy - 1, y * gy / h) * gx + min(gx - 1, x * gx / w)
                    out[t].append((x: x, y: y, v: g - b))
                }
            }
        }
        return out.map { list in Array(list.sorted { $0.v > $1.v }.prefix(80)) }
    }

    // Сдвиг неба между двумя кадрами в каждой части: перебор сдвигов, где совпадает больше всего звёзд
    private func estimate(_ a: [[(x: Int, y: Int, v: Int)]], _ b: [[(x: Int, y: Int, v: Int)]]) {
        let r = 48, cell = 3
        var res = [SIMD2<Float>?](repeating: nil, count: gx * gy)
        for t in 0..<(gx * gy) {
            let pa = Array(a[t].prefix(60)), pb = b[t]
            guard pa.count >= 6, pb.count >= 6 else { continue }
            var set = Set<Int>()
            for q in pb { set.insert((q.x / cell) &* 100_003 &+ q.y / cell) }
            var best = 0, bd = SIMD2<Float>(0, 0)
            for dy in -r...r {
                for dx in -r...r {
                    if abs(dx) < 2 && abs(dy) < 2 { continue }   // неподвижное (горячие пиксели, фонари) не считаем
                    var s = 0
                    for q in pa where set.contains(((q.x + dx) / cell) &* 100_003 &+ (q.y + dy) / cell) { s += 1 }
                    if s > best { best = s; bd = SIMD2(Float(dx), Float(dy)) }
                }
            }
            if best >= max(6, pa.count / 4) { res[t] = bd }
        }
        let ok = res.compactMap { $0 }
        guard ok.count >= 2 else { return }
        let mx = ok.map { $0.x }.sorted()[ok.count / 2], my = ok.map { $0.y }.sorted()[ok.count / 2]
        shift = res.map { $0 ?? SIMD2(mx, my) }
    }

    // Каждую яркую точку протягиваем назад по сдвигу неба: путь между прошлым и этим кадром
    private func fill(_ f: inout Frame, _ bg: [Float]) {
        guard let sh = shift else { return }
        let w = f.w, h = f.h
        let bw = (w + blk - 1) / blk
        let src = f.px
        f.px.withUnsafeMutableBufferPointer { d in
            src.withUnsafeBufferPointer { p in
                for y in 0..<h {
                    for x in 0..<w {
                        let o = (y * w + x) * 4
                        let bi = ((y / blk) * bw + x / blk) * 3
                        let e0 = Int(p[o]) - Int(bg[bi]), e1 = Int(p[o + 1]) - Int(bg[bi + 1]), e2 = Int(p[o + 2]) - Int(bg[bi + 2])
                        guard e1 > 14 else { continue }
                        let t = min(gy - 1, y * gy / h) * gx + min(gx - 1, x * gx / w)
                        let v = sh[t]
                        let k = max(1, Int(max(abs(v.x), abs(v.y)).rounded(.up)))
                        for s in 1...k {
                            let f0 = Float(s) / Float(k)
                            let tx = x - Int((v.x * f0).rounded()), ty = y - Int((v.y * f0).rounded())
                            guard tx >= 0, ty >= 0, tx < w, ty < h else { continue }
                            let q = (ty * w + tx) * 4
                            d[q] = max(d[q], UInt8(min(255, Int(p[q]) + max(0, e0))))
                            d[q + 1] = max(d[q + 1], UInt8(min(255, Int(p[q + 1]) + e1)))
                            d[q + 2] = max(d[q + 2], UInt8(min(255, Int(p[q + 2]) + max(0, e2))))
                        }
                    }
                }
            }
        }
    }
}
