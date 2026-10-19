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
        case .timelapse, .reel, .deep: return nil
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
    case starlapse, timelapse, startrail, deep, reel
    var id: String { rawValue }
    var title: String {
        switch self {
        case .starlapse: return "Starlapse"
        case .timelapse: return "Таймлапс"
        case .startrail: return "Следы"
        case .deep: return "Звёзды"
        case .reel: return "3 в 1"
        }
    }
    var hint: String {
        switch self {
        case .starlapse: return "Видео, где за звёздами тянутся хвосты"
        case .timelapse: return "Обычное видео, звёзды точками"
        case .startrail: return "Одна фотография: все кадры наложены, звёзды рисуют круги"
        case .deep: return "Одна фотография: кадры выровнены по звёздам и сложены. Звёзды точками, шума почти нет, видно больше слабых звёзд"
        case .reel: return "Вертикальное видео 1080×1920 для Instagram: сверху таймлапс, посередине средний след, снизу длинный"
        }
    }
    var isVideo: Bool { self != .startrail && self != .deep }
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

/// Баланс белого в редакторе: тепло (синий ↔ жёлтый) и оттенок (зелёный ↔ пурпурный).
/// Кадры на диске не меняются, поправка ложится на всё, что собирает редактор
struct Grade: Equatable {
    var temp: Float = 0
    var tint: Float = 0
    /// Насыщенность и контраст: -1...1, 0 - как снято
    var sat: Float = 0
    var contrast: Float = 0
    /// Свет: экспозиция, тени, света, виньетка - всё -1...1
    var exposure: Float = 0
    var shadows: Float = 0
    var highlights: Float = 0
    var vignette: Float = 0
    /// Кадр: наклон горизонта в градусах и формат
    var angle: Float = 0
    var crop: Crop = .original

    enum Crop: String, CaseIterable, Identifiable {
        case original, wide, vertical, square, portrait
        var id: String { rawValue }
        var title: String {
            switch self {
            case .original: return "Как снято"
            case .wide: return "16:9"
            case .vertical: return "9:16"
            case .square: return "1:1"
            case .portrait: return "4:5"
            }
        }
        /// Ширина к высоте, nil - как снято
        var ratio: Float? {
            switch self {
            case .original: return nil
            case .wide: return 16.0 / 9
            case .vertical: return 9.0 / 16
            case .square: return 1
            case .portrait: return 4.0 / 5
            }
        }
    }

    var toneNeutral: Bool {
        abs(temp) < 0.01 && abs(tint) < 0.01 && abs(sat) < 0.01 && abs(contrast) < 0.01
            && abs(exposure) < 0.01 && abs(shadows) < 0.01 && abs(highlights) < 0.01 && abs(vignette) < 0.01
    }
    var geoNeutral: Bool { abs(angle) < 0.05 && crop == .original }
    var isNeutral: Bool { toneNeutral && geoNeutral }

    /// Таблицы для синего, зелёного и красного: цвет, экспозиция, тени и света, потом контраст вокруг середины
    func luts() -> [[UInt8]] {
        let kb = 1 - 0.3 * temp, kr = 1 + 0.3 * temp, kg = 1 - 0.18 * tint
        let kc = 1 + 0.6 * contrast
        let ke = pow(2, 1.5 * exposure)
        let sh = shadows, hl = highlights
        let mk: (Float) -> [UInt8] = { k in
            (0..<256).map { v in
                var x = min(1, Float(v) * k * ke / 255)
                // Тени поднимают тёмное, почти не трогая светлое; света - наоборот
                x += sh * 0.7 * x * (1 - x) * (1 - x)
                x += hl * 0.7 * x * x * (1 - x)
                let c = (x * 255 - 128) * kc + 128
                return UInt8(min(255, max(0, c.rounded())))
            }
        }
        return [mk(kb), mk(kg), mk(kr)]
    }

    /// Размер после наклона и обрезки: самый большой прямоугольник нужного формата внутри повёрнутого кадра
    func outSize(_ w: Int, _ h: Int) -> (Int, Int) {
        guard !geoNeutral else { return (w, h) }
        let r = crop.ratio ?? Float(w) / Float(h)
        let a = abs(angle) * .pi / 180
        let c = cos(a), sn = sin(a)
        let s = min(Float(w) / (c * r + sn), Float(h) / (sn * r + c))
        let ow = Int(s * r) & ~1, oh = Int(s) & ~1
        return (max(ow, 16), max(oh, 16))
    }
}

extension Frame {
    mutating func apply(_ g: Grade) {
        guard !g.toneNeutral else { return }
        if abs(g.vignette) >= 0.01 { vignette(g.vignette) }
        let t = g.luts()
        let n = px.count
        let ks = Int((1 + g.sat) * 256)
        let doSat = abs(g.sat) >= 0.01
        px.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i + 2 < n {
                var b = Int(t[0][Int(p[i])]), gg = Int(t[1][Int(p[i + 1])]), r = Int(t[2][Int(p[i + 2])])
                if doSat {
                    // Насыщенность: отдаляем цвет от серого той же яркости
                    let y = (b * 29 + gg * 150 + r * 77) >> 8
                    b = y + ((b - y) * ks) >> 8
                    gg = y + ((gg - y) * ks) >> 8
                    r = y + ((r - y) * ks) >> 8
                }
                p[i] = UInt8(min(255, max(0, b)))
                p[i + 1] = UInt8(min(255, max(0, gg)))
                p[i + 2] = UInt8(min(255, max(0, r)))
                i += 4
            }
        }
    }

    /// Виньетка: v < 0 - темнее к углам, v > 0 - светлее
    mutating func vignette(_ v: Float) {
        let w = self.w, h = self.h
        let cx = Float(w) / 2, cy = Float(h) / 2
        let inv = 1 / (cx * cx + cy * cy)
        px.withUnsafeMutableBufferPointer { p in
            DispatchQueue.concurrentPerform(iterations: 8) { part in
                for y in (part * h / 8)..<((part + 1) * h / 8) {
                    let dy = Float(y) - cy
                    for x in 0..<w {
                        let dx = Float(x) - cx
                        let r2 = (dx * dx + dy * dy) * inv
                        let k = max(0, 1 + v * 0.8 * r2 * r2)
                        let o = (y * w + x) * 4
                        p[o] = UInt8(min(255, Float(p[o]) * k))
                        p[o + 1] = UInt8(min(255, Float(p[o + 1]) * k))
                        p[o + 2] = UInt8(min(255, Float(p[o + 2]) * k))
                    }
                }
            }
        }
    }

    /// Наклон горизонта и обрезка под формат (центр кадра остаётся центром)
    func geometry(_ g: Grade) -> Frame {
        guard !g.geoNeutral else { return self }
        let w = self.w, h = self.h
        let (ow, oh) = g.outSize(w, h)
        var out = Frame(w: ow, h: oh)
        out.ok = ok
        let a = g.angle * .pi / 180
        let c = cos(a), sn = sin(a)
        let cx = Float(w) / 2, cy = Float(h) / 2, ocx = Float(ow) / 2, ocy = Float(oh) / 2
        px.withUnsafeBufferPointer { p in
            out.px.withUnsafeMutableBufferPointer { d in
                DispatchQueue.concurrentPerform(iterations: 8) { part in
                    for y in (part * oh / 8)..<((part + 1) * oh / 8) {
                        let v = Float(y) + 0.5 - ocy
                        for x in 0..<ow {
                            let u = Float(x) + 0.5 - ocx
                            let sx = min(max(cx + u * c - v * sn - 0.5, 0), Float(w - 2))
                            let sy = min(max(cy + u * sn + v * c - 0.5, 0), Float(h - 2))
                            let ix = Int(sx), iy = Int(sy)
                            let ax = sx - Float(ix), ay = sy - Float(iy)
                            let q = (iy * w + ix) * 4, o = (y * ow + x) * 4
                            for ch in 0..<3 {
                                let t = Float(p[q + ch]) * (1 - ax) + Float(p[q + 4 + ch]) * ax
                                let b = Float(p[q + w * 4 + ch]) * (1 - ax) + Float(p[q + w * 4 + 4 + ch]) * ax
                                d[o + ch] = UInt8(min(255, (t * (1 - ay) + b * ay).rounded()))
                            }
                            d[o + 3] = 255
                        }
                    }
                }
            }
        }
        return out
    }

    /// Яркость в k раз (для выравнивания мерцания)
    mutating func scale(_ k: Float) {
        guard abs(k - 1) > 0.005 else { return }
        let t = (0..<256).map { UInt8(min(255, max(0, (Float($0) * k).rounded()))) }
        px.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i + 2 < p.count {
                p[i] = t[Int(p[i])]; p[i + 1] = t[Int(p[i + 1])]; p[i + 2] = t[Int(p[i + 2])]
                i += 4
            }
        }
    }
}

// MARK: - Какие кадры брать и как выровнять яркость

/// Отбраковка и выравнивание по журналу съёмки (log.csv, яркость каждого кадра).
/// Вспышка фонаря или фар - кадр заметно светлее соседей, перекрытый объектив - заметно темнее.
/// Список исключённых кадров лежит в папке съёмки (excluded.json), его можно поправить руками в редакторе
enum FramePlan {
    static func lumas(_ dir: URL) -> [Int: Double] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("log.csv"), encoding: .utf8) else { return [:] }
        var m: [Int: Double] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let c = line.split(separator: ",")
            guard c.count > 7, let f = Int(c[1]), let l = Double(c[7]) else { continue }
            m[f] = l
        }
        return m
    }

    /// Кадры-выбросы по яркости: светлее соседей на 30% или темнее на 40%
    static func autoExclude(_ dir: URL) -> Set<Int> {
        let l = lumas(dir)
        var out = Set<Int>()
        for (f, v) in l {
            let nb = (-3...3).filter { $0 != 0 }.compactMap { l[f + $0] }.sorted()
            guard nb.count >= 3 else { continue }
            let med = nb[nb.count / 2]
            if v > med * 1.3 + 6 || v < med * 0.6 - 4 { out.insert(f) }
        }
        return out
    }

    private static func file(_ dir: URL) -> URL { dir.appendingPathComponent("excluded.json") }

    /// Исключённые кадры. При первом открытии - найденные автоматически
    static func excluded(_ dir: URL) -> Set<Int> {
        if let d = try? Data(contentsOf: file(dir)),
           let a = (try? JSONSerialization.jsonObject(with: d)) as? [Int] {
            return Set(a)
        }
        let auto = autoExclude(dir)
        save(dir, auto)
        return auto
    }

    static func save(_ dir: URL, _ set: Set<Int>) {
        if let d = try? JSONSerialization.data(withJSONObject: Array(set).sorted()) {
            try? d.write(to: file(dir))
        }
    }

    /// Во сколько раз поправить яркость каждого кадра, чтобы не мигало: к средней по 15 соседним кадрам
    static func deflicker(_ dir: URL, _ ex: Set<Int>) -> [Int: Float] {
        let l = lumas(dir).filter { !ex.contains($0.key) && $0.value > 1 }
        var out: [Int: Float] = [:]
        for (f, v) in l {
            let nb = (-7...7).compactMap { l[f + $0] }
            guard nb.count >= 5 else { continue }
            let avg = nb.reduce(0, +) / Double(nb.count)
            out[f] = Float(min(max(avg / v, 0.75), 1.33))
        }
        return out
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
    // Последний собранный просмотр без цвета: при движении ползунков цвета пересобирать его не нужно
    private var baseKey = ""
    private var base: CGImage?

    func makePreview(_ shoot: Shoot, _ look: Look, _ trail: Trail, _ grade: Grade = Grade()) {
        previewToken += 1
        let token = previewToken
        previewBusy = true
        let key = "\(shoot.id)|\(look.rawValue)|\(trail.rawValue)|\(FramePlan.excluded(shoot.dir).count)"
        q.async {
            if key == self.baseKey, let b = self.base {
                var img: CGImage? = b
                if !grade.isNeutral {
                    var f = Frame(w: b.width, h: b.height)
                    f.draw(b)
                    f.apply(grade)
                    img = (look == .reel ? f : f.geometry(grade)).cgImage()
                }
                let ui = img.map { UIImage(cgImage: $0) }
                DispatchQueue.main.async {
                    guard token == self.previewToken else { return }
                    self.preview = ui
                    self.previewBusy = false
                }
                return
            }
            let urls = ShootStore.frameURLs(shoot.dir)
            guard !urls.isEmpty else {
                DispatchQueue.main.async { self.previewBusy = false }
                return
            }
            let ex = FramePlan.excluded(shoot.dir)
            let step = max(1, urls.count / 150)
            let pick = stride(from: 0, to: urls.count, by: step).filter { !ex.contains($0 + 1) }.map { urls[$0] }
            var img: CGImage?
            if look == .startrail, let ready = ShootStore.liveURL(shoot.dir, look, trail),
               FileManager.default.fileExists(atPath: ready.path) {
                img = ShootStore.thumb(ready, maxPixel: 900)
            } else if look == .timelapse || look == .deep {
                img = ShootStore.thumb(urls[urls.count / 2], maxPixel: 900)
            } else if look == .reel, let p0 = pick.first, let first = ShootStore.thumb(p0, maxPixel: 900) {
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
            } else if let p0 = pick.first, let first = ShootStore.thumb(p0, maxPixel: 900) {
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
            if token == self.previewToken, let c = img {
                self.base = c
                self.baseKey = key
            }
            if !grade.isNeutral, let c = img {
                var f = Frame(w: c.width, h: c.height)
                f.draw(c)
                f.apply(grade)
                img = (look == .reel ? f : f.geometry(grade)).cgImage()
            }
            let ui = img.map { UIImage(cgImage: $0) }
            DispatchQueue.main.async {
                guard token == self.previewToken else { return }
                self.preview = ui
                self.previewBusy = false
            }
        }
    }

    func run(_ shoot: Shoot, _ look: Look, _ trail: Trail, denoise: Bool, grade: Grade = Grade(), deflicker: Bool = true) {
        guard !busy else { return }
        busy = true
        cancelled = false
        progress = 0
        message = look == .deep ? "Выравниваю кадры по звёздам..." : (look == .startrail ? "Накладываю кадры..." : "Собираю видео...")
        UIApplication.shared.isIdleTimerDisabled = true
        let t0 = Date()
        q.async {
            let r: String
            // Готовый Starlapse из съёмки - без шумодава, поэтому с «Убрать шум» собираем заново
            // Если между кадрами были паузы, готовые следы из съёмки пунктирные - собираем заново с дорисовкой
            if let ready = ShootStore.liveURL(shoot.dir, look, trail), FileManager.default.fileExists(atPath: ready.path),
               !(denoise && look.isVideo), !GapFill.needed(shoot.dir), grade.isNeutral,
               !(deflicker && look.isVideo), FramePlan.excluded(shoot.dir).isEmpty {
                r = self.saveReady(ready, isVideo: look.isVideo)
            } else if look == .startrail {
                r = self.renderPhoto(shoot, grade)
            } else if look == .deep {
                r = self.renderDeep(shoot, grade)
            } else {
                r = self.renderMovie(shoot, look, trail, denoise: denoise, grade: grade, deflicker: deflicker)
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

    private func renderPhoto(_ shoot: Shoot, _ grade: Grade) -> String {
        let urls = ShootStore.frameURLs(shoot.dir)
        guard let first = urls.first.flatMap({ ShootStore.full($0) }) else { return "Нет кадров" }
        var acc = Frame(w: first.width, h: first.height)
        let lut = decayLUT(1)
        let nm = nightMap(shoot.dir)
        let gap = GapFill(shoot.dir)
        let ex = FramePlan.excluded(shoot.dir)
        var used = 0
        let done = eachFrame(urls, first.width, first.height) { raw, i in
            if ex.contains(i + 1) { return }
            // Номер кадра в журнале = номер файла frame_00001 → 1
            // Без журнала (старые съёмки) пересвеченный кадр рассвета узнаётся по яркости
            guard nm.isEmpty ? raw.meanLuma() < 170 : (nm[i + 1] ?? true) else { return }
            var cur = raw
            cur.apply(grade)
            gap.apply(&cur)
            acc.trail(with: cur, lut: lut)
            used += 1
        }
        if !done { return "Остановлено" }
        if used == 0 { return "Все кадры сняты днём или в сумерках. Фото со следами получается только в темноте" }
        guard let img = acc.geometry(grade).cgImage(), let jpg = ShootStore.jpeg(img) else { return "Не удалось собрать фото" }
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

    /// Фото «Звёзды»: до 40 ночных кадров из середины съёмки выравниваются по звёздам и усредняются.
    /// Шум падает в несколько раз, звёзды остаются точками. Земля не движется - её берём из простого среднего,
    /// а небо из выровненного; граница - по яркости (ночью земля темнее неба)
    private func renderDeep(_ shoot: Shoot, _ grade: Grade) -> String {
        let urls = ShootStore.frameURLs(shoot.dir)
        guard let first = urls.first.flatMap({ ShootStore.full($0) }) else { return "Нет кадров" }
        let w = first.width, h = first.height
        let nm = nightMap(shoot.dir)
        let ex = FramePlan.excluded(shoot.dir)
        var night = (0..<urls.count).filter { !ex.contains($0 + 1) && (nm.isEmpty || (nm[$0 + 1] ?? true)) }
        guard night.count >= 5 else { return "Мало ночных кадров: для фото «Звёзды» нужно хотя бы 5" }
        // Середина ночной части съёмки, подряд
        let take = min(40, night.count)
        let mid = night.count / 2
        let lo = max(0, min(night.count - take, mid - take / 2))
        night = Array(night[lo..<(lo + take)])
        let ref = night[night.count / 2]

        // Сдвиг неба на один кадр: меряем между кадрами, отстоящими примерно на полторы минуты,
        // иначе сдвиг слишком мал, чтобы его заметить
        let interval = max(1, (ShootStore.readInfo(shoot.dir)["interval"] as? Double) ?? 8)
        var step: [SIMD2<Float>]?
        var gap = max(1, Int((90 / interval).rounded()))
        while step == nil && gap >= 1 {
            let a = night.first!, bIdx = a + gap
            if bIdx < urls.count, let ia = ShootStore.full(urls[a]), let ib = ShootStore.full(urls[bIdx]),
               ia.width == w, ib.width == w {
                var fa = Frame(w: w, h: h), fb = Frame(w: w, h: h)
                fa.draw(ia)
                fb.draw(ib)
                if let d = GapFill.skyShift(fa, fb) { step = d.map { $0 / Float(gap) } }
            }
            if step == nil { gap /= 2 }
        }
        guard let sh = step else {
            return "Не нашёл звёзд, чтобы выровнять кадры. Нужна ясная ночь со звёздами в кадре"
        }
        let gx = GapFill.gx, gy = GapFill.gy

        // Суммы ×4 в UInt16: 40 кадров × 1020 помещаются
        let n = w * h
        var sky = [UInt16](repeating: 0, count: n * 3)
        var cnt = [UInt8](repeating: 0, count: n)
        var flat = [UInt16](repeating: 0, count: n * 3)
        let pick = night.map { urls[$0] }
        var used = 0
        let done = eachFrame(pick, w, h) { raw, k in
            var cur = raw
            cur.apply(grade)
            let t = Float(night[k] - ref)
            sky.withUnsafeMutableBufferPointer { sb in
            cnt.withUnsafeMutableBufferPointer { cb in
            flat.withUnsafeMutableBufferPointer { fb in
            cur.px.withUnsafeBufferPointer { p in
                DispatchQueue.concurrentPerform(iterations: 16) { part in
                    let y0 = part * h / 16, y1 = (part + 1) * h / 16
                    for y in y0..<y1 {
                        // Сдвиг по частям кадра плавно: между центрами частей - по линии
                        let fy = min(max(Float(y) * Float(gy) / Float(h) - 0.5, 0), Float(gy - 1))
                        let ty0 = Int(fy), ty1 = min(ty0 + 1, gy - 1), wy = fy - Float(ty0)
                        for x in 0..<w {
                            let o = y * w + x
                            fb[o * 3] &+= UInt16(p[o * 4]) * 4
                            fb[o * 3 + 1] &+= UInt16(p[o * 4 + 1]) * 4
                            fb[o * 3 + 2] &+= UInt16(p[o * 4 + 2]) * 4
                            let fx = min(max(Float(x) * Float(gx) / Float(w) - 0.5, 0), Float(gx - 1))
                            let tx0 = Int(fx), tx1 = min(tx0 + 1, gx - 1), wx = fx - Float(tx0)
                            let d0 = sh[ty0 * gx + tx0] * (1 - wx) + sh[ty0 * gx + tx1] * wx
                            let d1 = sh[ty1 * gx + tx0] * (1 - wx) + sh[ty1 * gx + tx1] * wx
                            let d = (d0 * (1 - wy) + d1 * wy) * t
                            let sx = Float(x) + d.x, sy = Float(y) + d.y
                            guard sx >= 0, sy >= 0, sx < Float(w - 1), sy < Float(h - 1) else { continue }
                            let ix = Int(sx), iy = Int(sy)
                            let ax = sx - Float(ix), ay = sy - Float(iy)
                            let q = (iy * w + ix) * 4
                            for c in 0..<3 {
                                let v00 = Float(p[q + c]), v10 = Float(p[q + 4 + c])
                                let v01 = Float(p[q + w * 4 + c]), v11 = Float(p[q + w * 4 + 4 + c])
                                let v = (v00 * (1 - ax) + v10 * ax) * (1 - ay) + (v01 * (1 - ax) + v11 * ax) * ay
                                sb[o * 3 + c] &+= UInt16(v * 4 + 0.5)
                            }
                            cb[o] &+= 1
                        }
                    }
                }
            }}}}
            used += 1
        }
        if !done { return "Остановлено" }
        guard used >= 3 else { return "Не удалось прочитать кадры" }

        // Где земля: блоки 16×16 простого среднего заметно темнее неба
        let blk = 16
        let bw = (w + blk - 1) / blk, bh = (h + blk - 1) / blk
        var bg = [Float](repeating: 0, count: bw * bh)
        var bc = [Float](repeating: 0, count: bw * bh)
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                let b = (y / blk) * bw + x / blk
                bg[b] += Float(flat[(y * w + x) * 3 + 1])
                bc[b] += 1
            }
        }
        for b in 0..<bg.count { bg[b] = bc[b] > 0 ? bg[b] / bc[b] / Float(used * 4) : 0 }
        let sorted = bg.sorted()
        let level = max(sorted[sorted.count * 7 / 10], 4)   // уровень неба
        var mask = bg.map { min(max(($0 - 0.45 * level) / (0.25 * level), 0), 1) }
        // Сгладить границу 3×3
        let m0 = mask
        for by in 0..<bh {
            for bx in 0..<bw {
                var s: Float = 0, c: Float = 0
                for yy in max(0, by - 1)...min(bh - 1, by + 1) {
                    for xx in max(0, bx - 1)...min(bw - 1, bx + 1) { s += m0[yy * bw + xx]; c += 1 }
                }
                mask[by * bw + bx] = s / c
            }
        }
        var out = Frame(w: w, h: h)
        out.ok = true
        out.px.withUnsafeMutableBufferPointer { d in
            DispatchQueue.concurrentPerform(iterations: 16) { part in
                for y in (part * h / 16)..<((part + 1) * h / 16) {
                    let fy = min(max(Float(y) / Float(blk) - 0.5, 0), Float(bh - 1))
                    let by0 = Int(fy), by1 = min(by0 + 1, bh - 1), wy = fy - Float(by0)
                    for x in 0..<w {
                        let o = y * w + x
                        let fx = min(max(Float(x) / Float(blk) - 0.5, 0), Float(bw - 1))
                        let bx0 = Int(fx), bx1 = min(bx0 + 1, bw - 1), wx = fx - Float(bx0)
                        let t = (mask[by0 * bw + bx0] * (1 - wx) + mask[by0 * bw + bx1] * wx) * (1 - wy)
                            + (mask[by1 * bw + bx0] * (1 - wx) + mask[by1 * bw + bx1] * wx) * wy
                        let c = Float(cnt[o])
                        for ch in 0..<3 {
                            let g = Float(flat[o * 3 + ch]) / Float(used * 4)
                            let sv = c > 0 ? Float(sky[o * 3 + ch]) / (c * 4) : g
                            d[o * 4 + ch] = UInt8(min(255, max(0, (sv * t + g * (1 - t)).rounded())))
                        }
                        d[o * 4 + 3] = 255
                    }
                }
            }
        }
        guard let img = out.geometry(grade).cgImage(), let jpg = ShootStore.jpeg(img) else { return "Не удалось собрать фото" }
        try? jpg.write(to: shoot.dir.appendingPathComponent("stars_deep.jpg"))
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpg, options: nil)
        }) { s, _ in
            ok = s
            sem.signal()
        }
        sem.wait()
        return ok ? "Фото «Звёзды» из \(used) кадров сохранено в Фото" : "Нет доступа к Фото. Фото лежит в папке съёмки"
    }

    /// Видео из кадров: таймлапс, Starlapse или рилс «3 в 1» (таймлапс, средний след, длинный след друг под другом).
    /// denoise - убрать шум, сглаживая каждую точку по соседним кадрам
    private func renderMovie(_ shoot: Shoot, _ look: Look, _ trail: Trail, denoise: Bool, grade: Grade, deflicker: Bool) -> String {
        let urls = ShootStore.frameURLs(shoot.dir)
        guard let first = urls.first.flatMap({ ShootStore.full($0) }) else { return "Нет кадров" }
        let w = first.width, h = first.height
        let reel = look == .reel
        // Рилс: 1080×1920, три полосы по 636 с чёрными промежутками 6
        let geo = reel ? (w, h) : grade.outSize(w, h)
        let ow = reel ? 1080 : geo.0, oh = reel ? 1920 : geo.1
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
        let ex = FramePlan.excluded(shoot.dir)
        let flick = deflicker ? FramePlan.deflicker(shoot.dir, ex) : [:]
        let done = eachFrame(urls, w, h) { raw, i in
            if ex.contains(i + 1) { return }
            var cur = raw
            if let k = flick[i + 1] { cur.scale(k) }
            cur.apply(grade)
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
                src = (look == .timelapse ? cur : accA).geometry(grade)
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
        return ok ? (reel ? "Видео 3 в 1 сохранено в Фото" : "Видео сохранено в Фото") : "Нет доступа к Фото. Видео лежит в Файлы → NightLapse"
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
                    // Бережный уровень: только мелкое мерцание, звёзды и движение не трогаем
                    if d > -9 && d < 9 {
                        let v = UInt8(a + d / 3)
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
    /// Видео 3 в 1: вертикально, сверху как снято, ниже средний и длинный след
    @State private var stack3 = false
    /// Что собирать на самом деле: с «3 в 1» любое видео превращается в вертикальное из трёх полос
    private var eff: Look { stack3 && look.isVideo ? .reel : look }
    @State private var trail: Trail = .medium
    @AppStorage("denoise") private var denoise = true
    @State private var confirmDelete = false
    @State private var grade = Grade()
    @AppStorage("deflicker") private var deflicker = true
    @State private var excluded: Set<Int> = []
    @State private var showFrames = false
    @State private var reportURL: URL?
    @State private var reportBusy = false

    /// Собрано во время съёмки - сохранится мгновенно
    private var isReady: Bool {
        if denoise && look.isVideo { return false }
        if !grade.isNeutral || GapFill.needed(shoot.dir) || !excluded.isEmpty { return false }
        if deflicker && look.isVideo { return false }
        guard let u = ShootStore.liveURL(shoot.dir, eff, trail) else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    /// Ползунок -1...1 с подписью; двойное касание по подписи - вернуть как было
    private func gradeRow(_ title: String, _ v: Binding<Float>) -> some View {
        HStack {
            Text(title).font(.footnote).frame(width: 84, alignment: .leading)
                .onTapGesture(count: 2) { v.wrappedValue = 0 }
            Slider(value: v, in: -1...1)
            Text(String(format: "%+.0f", v.wrappedValue * 100))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(abs(v.wrappedValue) < 0.01 ? Color.secondary : Color.primary)
                .frame(width: 46, alignment: .trailing)
        }
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
                .aspectRatio(eff == .reel ? 0.75 : 16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Что собрать: видео отдельно, фото отдельно - пять вариантов в одну строку не помещаются
                VStack(alignment: .leading, spacing: 6) {
                    Text("Видео").font(.footnote).foregroundStyle(.secondary)
                    Picker("Видео", selection: $look) {
                        ForEach([Look.starlapse, .timelapse]) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Фото").font(.footnote).foregroundStyle(.secondary)
                    Picker("Фото", selection: $look) {
                        ForEach([Look.startrail, .deep]) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(r.busy)

                if look == .starlapse && !stack3 {
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
                    Toggle(isOn: $stack3) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("3 в 1 вертикально")
                            Text("Для сторис и коротких видео: сверху как снято, ниже средний и длинный след")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(r.busy)
                    Toggle("Убрать шум", isOn: $denoise)
                        .disabled(r.busy)
                    Toggle("Выровнять яркость (без мерцания)", isOn: $deflicker)
                        .disabled(r.busy)
                }

                Button {
                    showFrames = true
                } label: {
                    HStack {
                        Label("Кадры", systemImage: "film.stack")
                        Spacer()
                        Text(excluded.isEmpty ? "все \(shoot.frames) в деле" : "исключено \(excluded.count) из \(shoot.frames)")
                            .foregroundStyle(excluded.isEmpty ? Color.secondary : Color.orange)
                    }
                    .font(.footnote)
                }
                .disabled(r.busy)

                VStack(spacing: 6) {
                    HStack {
                        Text("Цвет").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        if !grade.isNeutral {
                            Button("Сбросить всё") { grade = Grade() }.font(.footnote)
                        }
                    }
                    HStack {
                        Image(systemName: "snowflake").foregroundStyle(.blue)
                        Slider(value: $grade.temp, in: -1...1)
                        Image(systemName: "sun.max.fill").foregroundStyle(.orange)
                    }
                    HStack {
                        Circle().fill(Color.green).frame(width: 14, height: 14)
                        Slider(value: $grade.tint, in: -1...1)
                        Circle().fill(Color.pink).frame(width: 14, height: 14)
                    }
                    HStack {
                        Image(systemName: "circle.lefthalf.filled").foregroundStyle(.gray)
                        Slider(value: $grade.sat, in: -1...1)
                        Image(systemName: "paintpalette.fill").foregroundStyle(.purple)
                    }
                    HStack {
                        Image(systemName: "circle.dotted").foregroundStyle(.gray)
                        Slider(value: $grade.contrast, in: -1...1)
                        Image(systemName: "circle.righthalf.filled").foregroundStyle(.white)
                    }

                    Text("Свет").font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                    gradeRow("Экспозиция", $grade.exposure)
                    gradeRow("Тени", $grade.shadows)
                    gradeRow("Света", $grade.highlights)
                    gradeRow("Виньетка", $grade.vignette)

                    if eff != .reel {
                        Text("Кадр").font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                        HStack {
                            Text("Горизонт").font(.footnote).frame(width: 84, alignment: .leading)
                            Slider(value: $grade.angle, in: -10...10, step: 0.1)
                            Text(String(format: "%+.1f°", grade.angle))
                                .font(.footnote.monospacedDigit())
                                .frame(width: 46, alignment: .trailing)
                                .onTapGesture { grade.angle = 0 }
                        }
                        Picker("Формат", selection: $grade.crop) {
                            ForEach(Grade.Crop.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .disabled(r.busy)

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
                        r.run(shoot, eff, trail, denoise: denoise, grade: grade, deflicker: deflicker)
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

                // Отчёт по этой съёмке: журнал, настройки и пара кадров. Его можно прислать в чат с Claude
                Group {
                    if let u = reportURL {
                        ShareLink(item: u) {
                            Label("Отправить отчёт", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                    } else {
                        Button {
                            reportBusy = true
                            Diag.makeReport { u in
                                reportURL = u
                                reportBusy = false
                            }
                        } label: {
                            HStack {
                                Label("Собрать отчёт для улучшения", systemImage: "doc.text.magnifyingglass")
                                if reportBusy { ProgressView() }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(reportBusy)
                    }
                }
                .buttonStyle(.bordered)

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
        .onAppear {
            excluded = FramePlan.excluded(shoot.dir)
            r.makePreview(shoot, eff, trail, grade)
        }
        .sheet(isPresented: $showFrames, onDismiss: {
            FramePlan.save(shoot.dir, excluded)
            r.makePreview(shoot, eff, trail, grade)
        }) {
            FramePicker(shoot: shoot, excluded: $excluded)
        }
        .onChange(of: look) { r.makePreview(shoot, eff, trail, grade) }
        .onChange(of: trail) { r.makePreview(shoot, eff, trail, grade) }
        .onChange(of: grade) { r.makePreview(shoot, eff, trail, grade) }
        .onChange(of: stack3) { r.makePreview(shoot, eff, trail, grade) }
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
    static let gx = 6, gy = 4
    private let gx = GapFill.gx, gy = GapFill.gy
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

    private init() { on = true }

    /// Сдвиг неба из кадра a в кадр b по частям кадра (gx×gy), или nil если звёзд не нашлось
    static func skyShift(_ a: Frame, _ b: Frame) -> [SIMD2<Float>]? {
        let g = GapFill()
        g.estimate(g.stars(a, g.blockMeans(a)), g.stars(b, g.blockMeans(b)))
        return g.shift
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


// MARK: - Выбор кадров

/// Пролистать кадры съёмки и убрать испорченные: вспышка фонаря, фары, толчок штатива.
/// Кадры с диска не удаляются - редактор их просто пропускает
struct FramePicker: View {
    let shoot: Shoot
    @Binding var excluded: Set<Int>
    @Environment(\.dismiss) private var dismiss
    @State private var idx: Double = 1
    @State private var img: UIImage?
    @State private var urls: [URL] = []

    private var n: Int { Int(idx.rounded()) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ZStack {
                    Color(white: 0.08)
                    if let i = img { Image(uiImage: i).resizable().scaledToFit() }
                    if excluded.contains(n) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(Color.red.opacity(0.85))
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if urls.count > 1 {
                    Slider(value: $idx, in: 1...Double(urls.count), step: 1)
                }
                HStack {
                    Button { idx = max(1, idx - 1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text("Кадр \(n) из \(urls.count)").monospacedDigit()
                    Spacer()
                    Button { idx = min(Double(urls.count), idx + 1) } label: { Image(systemName: "chevron.right") }
                }
                .font(.headline)

                Toggle("Использовать этот кадр", isOn: Binding(
                    get: { !excluded.contains(n) },
                    set: { on in if on { excluded.remove(n) } else { excluded.insert(n) } }
                ))

                // Быстрый переход к исключённым кадрам
                if !excluded.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(excluded).sorted(), id: \.self) { f in
                                Button("\(f)") { idx = Double(f) }
                                    .buttonStyle(.bordered)
                                    .tint(f == n ? .yellow : .orange)
                            }
                        }
                    }
                }

                Text("Вспышки и тёмные кадры приложение находит само и сразу исключает. Здесь можно вернуть их или убрать другие: смазанные, с фарами, с человеком в кадре")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Вернуть все") { excluded = [] }
                    Spacer()
                    Button("Найти заново") { excluded = FramePlan.autoExclude(shoot.dir) }
                }
                .font(.footnote)
                Spacer()
            }
            .padding()
            .navigationTitle("Кадры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
            .onAppear {
                urls = ShootStore.frameURLs(shoot.dir)
                if let f = excluded.min() { idx = Double(f) }
            }
            .task(id: n) {
                guard n >= 1, n <= urls.count else { return }
                let u = urls[n - 1]
                let t = await Task.detached { ShootStore.thumb(u, maxPixel: 1000) }.value
                img = t.map { UIImage(cgImage: $0) }
            }
        }
    }
}
