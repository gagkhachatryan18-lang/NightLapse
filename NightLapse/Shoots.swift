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
    /// Сдвинуть небо: по частям кадра (сдвиг за интервал × k), с плавным переходом между частями
    func shifted(_ sh: [SIMD2<Float>], by k: Float) -> Frame {
        let gx = GapFill.gx, gy = GapFill.gy
        let w = self.w, h = self.h
        var out = Frame(w: w, h: h)
        out.ok = ok
        px.withUnsafeBufferPointer { p in
            out.px.withUnsafeMutableBufferPointer { d in
                DispatchQueue.concurrentPerform(iterations: 8) { part in
                    for y in (part * h / 8)..<((part + 1) * h / 8) {
                        let fy = min(max(Float(y) * Float(gy) / Float(h) - 0.5, 0), Float(gy - 1))
                        let ty0 = Int(fy), ty1 = min(ty0 + 1, gy - 1), wy = fy - Float(ty0)
                        for x in 0..<w {
                            let fx = min(max(Float(x) * Float(gx) / Float(w) - 0.5, 0), Float(gx - 1))
                            let tx0 = Int(fx), tx1 = min(tx0 + 1, gx - 1), wx = fx - Float(tx0)
                            let d0 = sh[ty0 * gx + tx0] * (1 - wx) + sh[ty0 * gx + tx1] * wx
                            let d1 = sh[ty1 * gx + tx0] * (1 - wx) + sh[ty1 * gx + tx1] * wx
                            let dd = (d0 * (1 - wy) + d1 * wy) * k
                            // Звезда из точки p уходит в p + dd, значит сюда приходит то, что было в x - dd
                            let sx = min(max(Int((Float(x) - dd.x).rounded()), 0), w - 1)
                            let sy = min(max(Int((Float(y) - dd.y).rounded()), 0), h - 1)
                            let o = (y * w + x) * 4, q = (sy * w + sx) * 4
                            d[o] = p[q]; d[o + 1] = p[q + 1]; d[o + 2] = p[q + 2]; d[o + 3] = 255
                        }
                    }
                }
            }
        }
        return out
    }

    /// Плавный переход: a при t = 0, b при t = 1
    static func mix(_ a: Frame, _ b: Frame, _ t: Float) -> Frame {
        guard a.w == b.w, a.h == b.h else { return a }
        var out = a
        let k = Int(t * 256)
        b.px.withUnsafeBufferPointer { q in
            out.px.withUnsafeMutableBufferPointer { d in
                for i in 0..<d.count { d[i] = UInt8((Int(d[i]) * (256 - k) + Int(q[i]) * k) >> 8) }
            }
        }
        return out
    }
}

extension Frame {
    /// Таблицы на каждый канал (порядок в памяти: синий, зелёный, красный)
    mutating func applyLUTs(_ t: [[UInt8]]) {
        guard t.count == 3 else { return }
        px.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i + 2 < p.count {
                p[i] = t[0][Int(p[i])]; p[i + 1] = t[1][Int(p[i + 1])]; p[i + 2] = t[2][Int(p[i + 2])]
                i += 4
            }
        }
    }

    /// Авто-цвет по одному кадру: чёрный без засветки и нейтральный (не цветной) фон неба
    static func autoColorLUTs(_ f: Frame) -> [[UInt8]] {
        var hist = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        f.px.withUnsafeBufferPointer { p in
            var i = 0
            while i + 2 < p.count {
                hist[0][Int(p[i])] += 1; hist[1][Int(p[i + 1])] += 1; hist[2][Int(p[i + 2])] += 1
                i += 16
            }
        }
        func pct(_ h: [Int], _ q: Double) -> Float {
            let total = h.reduce(0, +)
            var acc = 0
            for v in 0..<256 {
                acc += h[v]
                if Double(acc) >= Double(total) * q { return Float(v) }
            }
            return 255
        }
        let lo = (0..<3).map { pct(hist[$0], 0.005) }
        let med = (0..<3).map { pct(hist[$0], 0.5) }
        let m = med.reduce(0, +) / 3
        let l = lo.reduce(0, +) / 3
        return (0..<3).map { c in
            let k = (m - l) / max(med[c] - lo[c], 1)
            return (0..<256).map { v in UInt8(min(255, max(0, ((Float(v) - lo[c]) * min(max(k, 0.5), 2) + l * 0.4).rounded()))) }
        }
    }

    /// Подпись в правом нижнем углу
    mutating func stamp(_ text: String) {
        guard !text.isEmpty else { return }
        let w = self.w, h = self.h
        px.withUnsafeMutableBytes { buf in
            guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(ctx)
            let size = CGFloat(min(w, h)) * 0.035
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = size * 0.15
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
                .shadow: shadow
            ]
            let str = text as NSString
            let sz = str.size(withAttributes: attrs)
            let pad = size * 0.8
            str.draw(at: CGPoint(x: CGFloat(w) - sz.width - pad, y: CGFloat(h) - sz.height - pad), withAttributes: attrs)
            UIGraphicsPopContext()
        }
    }
}

// MARK: - Настройки экспорта

/// Как экспортировать: куда, размер, частота кадров, качество. Готовые наборы под площадки
struct ExportOpts: Equatable {
    enum Res: Int, CaseIterable, Identifiable {
        case p720 = 720, p1080 = 1080, p1440 = 1440, full = 0
        var id: Int { rawValue }
        var title: String { self == .full ? "Как снято" : "\(rawValue)p" }
    }
    enum Quality: Int, CaseIterable, Identifiable {
        case normal, high, max
        var id: Int { rawValue }
        var title: String { ["Обычное", "Высокое", "Максимум"][rawValue] }
        /// Битрейт на пиксель кадра (при 30 к/с)
        var bpp: Int { [4, 10, 18][rawValue] }
    }
    enum Preset: String, CaseIterable, Identifiable {
        case original, instagram, youtube, telegram, whatsapp
        var id: String { rawValue }
        var title: String {
            switch self {
            case .original: return "Как снято"
            case .instagram: return "Instagram"
            case .youtube: return "YouTube"
            case .telegram: return "Telegram"
            case .whatsapp: return "WhatsApp"
            }
        }
        var icon: String {
            switch self {
            case .original: return "sparkles"
            case .instagram: return "camera"
            case .youtube: return "play.rectangle"
            case .telegram: return "paperplane"
            case .whatsapp: return "message"
            }
        }
    }

    var toPhotos = true
    var res: Res = .full
    /// 0 - как в настройках съёмки
    var fps = 0
    var quality: Quality = .high
    /// H.264 - для соцсетей, которые не любят HEVC
    var h264 = false
    /// Подпись в углу: 0 - нет, 1 - дата и время кадра, 2 - свой текст
    var mark = 0
    var markText = ""
    /// Авто-цвет: нейтральный фон неба и чистый чёрный, без засветки
    var autoColor = false

    /// Битрейт видео, Мбит/с, для кадра w×h
    func mbps(_ w: Int, _ h: Int) -> Int {
        let (ow, oh) = fit(w, h)
        return max(1, min(ow * oh * quality.bpp, 160_000_000) / 1_000_000)
    }

    static func preset(_ p: Preset) -> ExportOpts {
        var o = ExportOpts()
        switch p {
        case .original: break
        case .instagram: o.res = .p1080; o.fps = 30; o.quality = .high; o.h264 = true
        case .youtube: o.res = .full; o.fps = 30; o.quality = .max
        case .telegram: o.res = .p1080; o.fps = 30; o.quality = .normal; o.h264 = true
        case .whatsapp: o.res = .p720; o.fps = 30; o.quality = .normal; o.h264 = true
        }
        return o
    }

    /// Размер кадра на выходе: короткая сторона не больше выбранной, чётные стороны
    func fit(_ w: Int, _ h: Int) -> (Int, Int) {
        guard res != .full else { return (w, h) }
        let k = min(1, Double(res.rawValue) / Double(min(w, h)))
        return (max(2, Int(Double(w) * k) & ~1), max(2, Int(Double(h) * k) & ~1))
    }

    /// Коротко для журнала
    var summary: String {
        "\(toPhotos ? "в галерею" : "в приложение"), \(res.title), \(fps == 0 ? "к/с как снято" : "\(fps) к/с"), \(quality.title)\(h264 ? ", H.264" : "")"
    }
}

extension Frame {
    /// Уменьшить кадр (качественно, через Accelerate)
    func scaled(_ nw: Int, _ nh: Int) -> Frame {
        guard nw != w || nh != h else { return self }
        var out = Frame(w: nw, h: nh)
        out.ok = ok
        let sw = w, sh = h
        px.withUnsafeBytes { sp in
            out.px.withUnsafeMutableBytes { dp in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: sp.baseAddress!), height: vImagePixelCount(sh),
                                        width: vImagePixelCount(sw), rowBytes: sw * 4)
                var dst = vImage_Buffer(data: dp.baseAddress!, height: vImagePixelCount(nh), width: vImagePixelCount(nw), rowBytes: nw * 4)
                vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        return out
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
    /// Последний экспорт в приложение - его можно отправить через «Поделиться»
    @Published var lastFile: URL?
    /// Куда экспорт: в галерею (Фото) или в приложение (Файлы → NightLapse → Экспорт)
    private var toPhotos = true
    private var exportName = ""
    private var opts = ExportOpts()

    private var cancelled = false
    private var previewToken = 0
    private let q = DispatchQueue(label: "nightlapse.render", qos: .userInitiated)

    func cancel() { cancelled = true }

    /// Быстрый просмотр на маленьких кадрах (не больше 150 кадров)
    // Последний собранный просмотр без цвета: при движении ползунков цвета пересобирать его не нужно
    private var baseKey = ""
    private var base: CGImage?

    // MARK: Просмотр видео в редакторе

    /// Короткий черновик видео для просмотра прямо в редакторе: до 120 кадров, маленьких.
    /// Цвет и кадр применяются на лету при показе, поэтому ползунки видно сразу во время просмотра
    @Published var clip: [Frame] = []
    @Published var clipBusy = false
    private var clipKey = ""
    private var clipToken = 0
    private let cq = DispatchQueue(label: "nightlapse.clip", qos: .userInitiated)

    func makeClip(_ shoot: Shoot, _ look: Look, _ trail: Trail) {
        guard look.isVideo else {
            clip = []
            clipKey = ""
            return
        }
        let key = "\(shoot.id)|\(look.rawValue)|\(trail.rawValue)|\(FramePlan.excluded(shoot.dir).count)"
        if key == clipKey && !clip.isEmpty { return }
        clipKey = key
        clipToken += 1
        let token = clipToken
        clipBusy = true
        cq.async {
            let urls = ShootStore.frameURLs(shoot.dir)
            let ex = FramePlan.excluded(shoot.dir)
            let idx = (0..<urls.count).filter { !ex.contains($0 + 1) }
            let step = max(1, idx.count / 120)
            let nm = nightMap(shoot.dir)
            var out: [Frame] = []
            var acc: Frame?
            let lut = decayLUT(pow(trail.decay, Float(step)))
            for k in stride(from: 0, to: idx.count, by: step) {
                if token != self.clipToken { return }
                let i = idx[k]
                guard let c = ShootStore.thumb(urls[i], maxPixel: 480) else { continue }
                var cur = Frame(w: c.width, h: c.height)
                cur.draw(c)
                if look == .starlapse {
                    let night = nm.isEmpty ? cur.meanLuma() < 170 : (nm[i + 1] ?? true)
                    if var a = acc, a.w == cur.w, night {
                        a.trail(with: cur, lut: lut)
                        acc = a
                    } else {
                        acc = cur
                    }
                    out.append(acc ?? cur)
                } else {
                    out.append(cur)
                }
            }
            DispatchQueue.main.async {
                guard token == self.clipToken else { return }
                self.clip = out
                self.clipBusy = false
            }
        }
    }

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

    func run(_ shoot: Shoot, _ look: Look, _ trail: Trail, denoise: Bool, grade: Grade = Grade(), deflicker: Bool = true,
             opts: ExportOpts = ExportOpts()) {
        guard !busy else { return }
        busy = true
        self.toPhotos = opts.toPhotos
        self.opts = opts
        lastFile = nil
        exportName = shoot.dir.lastPathComponent.replacingOccurrences(of: "_frames", with: "") + "_" + look.rawValue
            + (look == .starlapse ? "_" + trail.rawValue : "")
        cancelled = false
        progress = 0
        message = look == .deep ? "Выравниваю кадры по звёздам..." : (look == .startrail ? "Накладываю кадры..." : "Собираю видео...")
        UIApplication.shared.isIdleTimerDisabled = true
        // Если ненадолго свернуть приложение, сборка ещё несколько минут продолжится
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "NightLapseExport") {
            UIApplication.shared.endBackgroundTask(bg)
            bg = .invalid
        }
        let t0 = Date()
        q.async {
            let r: String
            // Готовый Starlapse из съёмки - без шумодава, поэтому с «Убрать шум» собираем заново
            // Если между кадрами были паузы, готовые следы из съёмки пунктирные - собираем заново с дорисовкой
            if let ready = ShootStore.liveURL(shoot.dir, look, trail), FileManager.default.fileExists(atPath: ready.path),
               !(denoise && look.isVideo), !GapFill.needed(shoot.dir), grade.isNeutral,
               !(deflicker && look.isVideo), FramePlan.excluded(shoot.dir).isEmpty,
               self.opts.res == .full, self.opts.fps == 0, !self.opts.h264, self.opts.mark == 0, !self.opts.autoColor {
                r = self.saveReady(ready, isVideo: look.isVideo)
            } else if look == .startrail {
                r = self.renderPhoto(shoot, grade)
            } else if look == .deep {
                r = self.renderDeep(shoot, grade)
            } else {
                r = self.renderMovie(shoot, look, trail, denoise: denoise, grade: grade, deflicker: deflicker)
            }
            Diag.event("Редактор: \(look.title) \(look == .starlapse ? trail.title : "")\(denoise && look.isVideo ? " без шума" : "") для \(shoot.id), \(shoot.frames) кадров, "
                + "\(Int(Date().timeIntervalSince(t0))) с: \(r). Экспорт: \(opts.summary)"
                + (grade.isNeutral ? "" : String(format: ". Правка: тепло %.2f оттенок %.2f насыщ %.2f контраст %.2f яркость %.2f тени %.2f света %.2f виньетка %.2f наклон %.1f° формат %@",
                                                  grade.temp, grade.tint, grade.sat, grade.contrast, grade.exposure, grade.shadows,
                                                  grade.highlights, grade.vignette, grade.angle, grade.crop.title)))
            DispatchQueue.main.async {
                self.busy = false
                self.message = r
                UIApplication.shared.isIdleTimerDisabled = false
                if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
            }
        }
    }

    /// Уже собрано во время съёмки: просто копия в Фото, файл остаётся в папке съёмки
    private func saveReady(_ url: URL, isVideo: Bool) -> String {
        DispatchQueue.main.async { self.progress = 1 }
        if !toPhotos { return keepInApp(url, move: false) }
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
        return ok ? "Сохранено в галерее телефона" : "Нет доступа к галерее телефона. Файл лежит в папке съёмки"
    }

    /// Экспорт в приложение: файл кладётся в Файлы → На iPhone → NightLapse → Экспорт
    private func keepInApp(_ src: URL, move: Bool) -> String {
        let fm = FileManager.default
        let dir = ShootStore.docs().appendingPathComponent("Экспорт", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(exportName + "." + src.pathExtension)
        try? fm.removeItem(at: dest)
        do {
            if move { try fm.moveItem(at: src, to: dest) } else { try fm.copyItem(at: src, to: dest) }
        } catch {
            return "Не удалось сохранить в приложении: \(error.localizedDescription)"
        }
        DispatchQueue.main.async { self.lastFile = dest }
        return "Сохранено в приложении: Файлы → На iPhone → NightLapse → Экспорт"
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

    // MARK: Склейка съёмок

    /// Склеить оборванную съёмку с продолжением в новую съёмку. Кадры не копируются (жёсткие ссылки,
    /// места почти не занимает), а разрыв между ними дорисовывается: небо сдвигается так, как двигались
    /// звёзды в конце первой съёмки, и плавно переходит во вторую. Земля - плавный переход
    func merge(_ a: Shoot, _ b: Shoot, done: @escaping (Bool) -> Void) {
        guard !busy else { return }
        busy = true
        cancelled = false
        progress = 0
        message = "Склеиваю..."
        q.async {
            let r = self.mergeNow(a, b)
            Diag.event("Склейка \(a.id) + \(b.id): \(r.1)")
            DispatchQueue.main.async {
                self.busy = false
                self.message = r.1
                done(r.0)
            }
        }
    }

    private func mergeNow(_ a: Shoot, _ b: Shoot) -> (Bool, String) {
        let fm = FileManager.default
        let ua = ShootStore.frameURLs(a.dir), ub = ShootStore.frameURLs(b.dir)
        guard let la = ua.last, let fb = ub.first,
              let ia = ShootStore.full(la), let ib = ShootStore.full(fb) else { return (false, "Нет кадров для склейки") }
        let w = ia.width, h = ia.height
        guard ib.width == w, ib.height == h else { return (false, "У съёмок разный размер кадра - склеить нельзя") }
        let name = a.dir.lastPathComponent.replacingOccurrences(of: "_frames", with: "") + "_склейка_frames"
        let dir = ShootStore.docs().appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: dir)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return (false, "Не удалось создать папку") }

        // Сколько кадров пропало: по времени файлов и интервалу
        let info = ShootStore.readInfo(a.dir)
        let interval = max(1, (info["interval"] as? Double) ?? 8)
        func mtime(_ u: URL) -> Date? { (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
        var missing = 0
        if let t1 = mtime(la), let t2 = mtime(fb) {
            missing = min(120, max(0, Int((t2.timeIntervalSince(t1) / interval).rounded()) - 1))
        }

        var n = 0
        func next() -> URL {
            n += 1
            return dir.appendingPathComponent(String(format: "frame_%05d.jpg", n))
        }
        let total = ua.count + missing + ub.count
        for u in ua {
            if cancelled { return (false, "Остановлено") }
            let d = next()
            if (try? fm.linkItem(at: u, to: d)) == nil { try? fm.copyItem(at: u, to: d) }
        }
        report(n, total)

        // Дорисовка разрыва
        if missing > 0 {
            var fa = Frame(w: w, h: h), fbF = Frame(w: w, h: h)
            fa.draw(ia)
            fbF.draw(ib)
            // Сдвиг неба за один интервал - по последним кадрам первой съёмки
            var step: [SIMD2<Float>]?
            let k = min(ua.count - 1, max(1, Int((90 / interval).rounded())))
            if k >= 1, let ic = ShootStore.full(ua[ua.count - 1 - k]) {
                var fc = Frame(w: w, h: h)
                fc.draw(ic)
                step = GapFill.skyShift(fc, fa).map { arr in arr.map { v in v / Float(k) } }
            }
            let sample = Array(ua.suffix(6))
            let mask = SkyMask.build(sample, w: w, h: h)
            for j in 1...missing {
                if cancelled { return (false, "Остановлено") }
                let t = Float(j) / Float(missing + 1)
                let skyA = step.map { fa.shifted($0, by: Float(j)) } ?? fa
                let skyB = step.map { fbF.shifted($0, by: -Float(missing + 1 - j)) } ?? fbF
                let sky = Frame.mix(skyA, skyB, t)
                let ground = Frame.mix(fa, fbF, t)
                let out = mask?.blend(sky: sky, ground: ground) ?? sky
                if let cg = out.cgImage(), let jpg = ShootStore.jpeg(cg) { try? jpg.write(to: next()) }
                report(n, total)
            }
        }
        for u in ub {
            if cancelled { return (false, "Остановлено") }
            let d = next()
            if (try? fm.linkItem(at: u, to: d)) == nil { try? fm.copyItem(at: u, to: d) }
        }
        // Журнал первой съёмки, дальше второй с новыми номерами кадров
        var log = (try? String(contentsOf: a.dir.appendingPathComponent("log.csv"), encoding: .utf8)) ?? ""
        if let lb = try? String(contentsOf: b.dir.appendingPathComponent("log.csv"), encoding: .utf8) {
            let off = ua.count + missing
            for line in lb.split(separator: "\n").dropFirst() {
                var c = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                if c.count > 1, let f = Int(c[1]) { c[1] = String(f + off) }
                log += (log.hasSuffix("\n") || log.isEmpty ? "" : "\n") + c.joined(separator: ",")
            }
        }
        try? log.write(to: dir.appendingPathComponent("log.csv"), atomically: true, encoding: .utf8)
        var ni = info
        ni["done"] = true
        ni["merged"] = [a.id, b.id]
        ShootStore.writeInfo(dir, ni)
        report(total, total)
        return (true, missing > 0
                ? "Склейка готова: \(total) кадров, дорисовано \(missing). Она в списке съёмок"
                : "Склейка готова: \(total) кадров. Она в списке съёмок")
    }

    private static let markFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM.yyyy HH:mm"
        return f
    }()

    /// Текст подписи для кадра: дата и время снимка или свой текст
    private func markText(_ u: URL?) -> String {
        switch opts.mark {
        case 1:
            guard let u, let d = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date else { return "" }
            return Self.markFmt.string(from: d)
        case 2: return opts.markText
        default: return ""
        }
    }

    /// Таблицы авто-цвета по кадру из середины ночи (nil - выключено)
    private func autoLUTs(_ urls: [URL], _ nm: [Int: Bool]) -> [[UInt8]]? {
        guard opts.autoColor, !urls.isEmpty else { return nil }
        let night = (0..<urls.count).filter { nm.isEmpty || (nm[$0 + 1] ?? true) }
        let i = night.isEmpty ? urls.count / 2 : night[night.count / 2]
        guard let c = ShootStore.thumb(urls[i], maxPixel: 800) else { return nil }
        var f = Frame(w: c.width, h: c.height)
        f.draw(c)
        return Frame.autoColorLUTs(f)
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
        let w = first.width, h = first.height
        // Земля без следов и без точек шума: на земле берём среднее по кадрам, следы только на небе
        let nightIdx = (0..<urls.count).filter { !ex.contains($0 + 1) && (nm.isEmpty || (nm[$0 + 1] ?? true)) }
        let sample = stride(from: 0, to: nightIdx.count, by: max(1, nightIdx.count / 12)).map { urls[nightIdx[$0]] }
        let mask = SkyMask.build(sample, w: w, h: h)
        let every = max(1, nightIdx.count / 60)
        var gsum = [UInt16](repeating: 0, count: mask == nil ? 0 : w * h * 3)
        var gcnt = 0
        var used = 0
        let auto = autoLUTs(urls, nm)
        let done = eachFrame(urls, w, h) { raw, i in
            if ex.contains(i + 1) { return }
            // Номер кадра в журнале = номер файла frame_00001 → 1
            // Без журнала (старые съёмки) пересвеченный кадр рассвета узнаётся по яркости
            guard nm.isEmpty ? raw.meanLuma() < 170 : (nm[i + 1] ?? true) else { return }
            var cur = raw
            if let a = auto { cur.applyLUTs(a) }
            cur.apply(grade)
            if mask != nil && used % every == 0 && gcnt < 250 {
                gsum.withUnsafeMutableBufferPointer { s in
                    cur.px.withUnsafeBufferPointer { p in
                        for k in 0..<(w * h) {
                            s[k * 3] &+= UInt16(p[k * 4]); s[k * 3 + 1] &+= UInt16(p[k * 4 + 1]); s[k * 3 + 2] &+= UInt16(p[k * 4 + 2])
                        }
                    }
                }
                gcnt += 1
            }
            gap.apply(&cur)
            acc.trail(with: cur, lut: lut)
            used += 1
        }
        if !done { return "Остановлено" }
        if used == 0 { return "Все кадры сняты днём или в сумерках. Фото со следами получается только в темноте" }
        if let mk = mask, gcnt > 0 {
            var ground = Frame(w: w, h: h)
            ground.ok = true
            for k in 0..<(w * h) {
                ground.px[k * 4] = UInt8(Int(gsum[k * 3]) / gcnt)
                ground.px[k * 4 + 1] = UInt8(Int(gsum[k * 3 + 1]) / gcnt)
                ground.px[k * 4 + 2] = UInt8(Int(gsum[k * 3 + 2]) / gcnt)
                ground.px[k * 4 + 3] = 255
            }
            acc = mk.blend(sky: acc, ground: ground)
        }
        let accOut = acc.geometry(grade)
        let pf = opts.fit(accOut.w, accOut.h)
        var photo = accOut.scaled(pf.0, pf.1)
        if opts.mark != 0 { photo.stamp(markText(nightIdx.isEmpty ? urls.first : urls[nightIdx[nightIdx.count / 2]])) }
        guard let img = photo.cgImage(), let jpg = ShootStore.jpeg(img) else { return "Не удалось собрать фото" }
        // Копия рядом с исходниками, на случай если в Фото нет доступа
        try? jpg.write(to: shoot.dir.appendingPathComponent("startrail.jpg"))
        if !toPhotos { return keepInApp(shoot.dir.appendingPathComponent("startrail.jpg"), move: false) }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpg, options: nil)
        }) { s, _ in
            ok = s
            sem.signal()
        }
        sem.wait()
        return ok ? "Фото со следами сохранено в галерее телефона" : "Нет доступа к галерее телефона. Фото лежит в папке съёмки"
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
        var sky_ = [UInt16](repeating: 0, count: n * 3)
        var cnt = [UInt8](repeating: 0, count: n)
        var flat = [UInt16](repeating: 0, count: n * 3)
        let pick = night.map { urls[$0] }
        var used = 0
        let auto = autoLUTs(urls, nm)
        let done = eachFrame(pick, w, h) { raw, k in
            var cur = raw
            if let a = auto { cur.applyLUTs(a) }
            cur.apply(grade)
            let t = Float(night[k] - ref)
            sky_.withUnsafeMutableBufferPointer { sb in
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
        // Горизонт по столбцам снизу вверх: так затемнённые углы неба не путаются с землёй
        let sky = SkyMask.fromBlocks(bg, bw: bw, bh: bh, blk: blk, w: w, h: h)
        let hasMask = sky != nil
        let mk = sky?.m ?? []
        var out = Frame(w: w, h: h)
        out.ok = true
        out.px.withUnsafeMutableBufferPointer { d in
            DispatchQueue.concurrentPerform(iterations: 16) { part in
                for y in (part * h / 16)..<((part + 1) * h / 16) {
                    for x in 0..<w {
                        let o = y * w + x
                        let t = hasMask ? Float(mk[o]) / 255 : 1
                        let c = Float(cnt[o])
                        for ch in 0..<3 {
                            let g = Float(flat[o * 3 + ch]) / Float(used * 4)
                            let sv = c > 0 ? Float(sky_[o * 3 + ch]) / (c * 4) : g
                            d[o * 4 + ch] = UInt8(min(255, max(0, (sv * t + g * (1 - t)).rounded())))
                        }
                        d[o * 4 + 3] = 255
                    }
                }
            }
        }
        let deepOut = out.geometry(grade)
        let df = opts.fit(deepOut.w, deepOut.h)
        var photo = deepOut.scaled(df.0, df.1)
        if opts.mark != 0 { photo.stamp(markText(urls[ref])) }
        guard let img = photo.cgImage(), let jpg = ShootStore.jpeg(img) else { return "Не удалось собрать фото" }
        try? jpg.write(to: shoot.dir.appendingPathComponent("stars_deep.jpg"))
        if !toPhotos { return keepInApp(shoot.dir.appendingPathComponent("stars_deep.jpg"), move: false) }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpg, options: nil)
        }) { s, _ in
            ok = s
            sem.signal()
        }
        sem.wait()
        return ok ? "Фото «Звёзды» из \(used) кадров сохранено в галерее телефона" : "Нет доступа к галерее телефона. Фото лежит в папке съёмки"
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
        let fitted = reel ? (1080, 1920) : opts.fit(geo.0, geo.1)
        let ow = fitted.0, oh = fitted.1
        let name = shoot.dir.lastPathComponent.replacingOccurrences(of: "_frames", with: "")
        let out = ShootStore.docs().appendingPathComponent(name + "_" + look.rawValue + ".mov")
        try? FileManager.default.removeItem(at: out)
        guard let writer = try? AVAssetWriter(outputURL: out, fileType: .mov) else { return "Не удалось начать запись" }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            // Рилс - H.264, его без перекодирования принимают все соцсети
            AVVideoCodecKey: reel || opts.h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: ow,
            AVVideoHeightKey: oh,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: reel ? 20_000_000 : min(ow * oh * opts.quality.bpp, 160_000_000)]
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

        let fps = Int32(max(opts.fps > 0 ? opts.fps : shoot.fps, 1))
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
        // Следы только на небе, земля - текущий кадр: без точек шума и без «размазанных» деревьев
        var mask: SkyMask?
        if look != .timelapse {
            let nightIdx = (0..<urls.count).filter { !ex.contains($0 + 1) && (nm.isEmpty || (nm[$0 + 1] ?? true)) }
            let sample = stride(from: 0, to: nightIdx.count, by: max(1, nightIdx.count / 12)).map { urls[nightIdx[$0]] }
            mask = SkyMask.build(sample, w: w, h: h)
        }
        let auto = autoLUTs(urls, nm)
        let done = eachFrame(urls, w, h) { raw, i in
            if writer.status == .failed { return }   // запись уже сломалась - не тратим время
            if ex.contains(i + 1) { return }
            var cur = raw
            if let k = flick[i + 1] { cur.scale(k) }
            if let a = auto { cur.applyLUTs(a) }
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
            let mk = night ? mask : nil
            if reel {
                reelFrame.drawPanel(cur, y0: 0, w: 1080, h: 636)
                reelFrame.drawPanel(mk?.blend(sky: accA, ground: cur) ?? accA, y0: 642, w: 1080, h: 636)
                reelFrame.drawPanel(mk?.blend(sky: accB, ground: cur) ?? accB, y0: 1284, w: 1080, h: 636)
                src = reelFrame
            } else if look == .timelapse {
                src = cur.geometry(grade)
            } else {
                src = (mk?.blend(sky: accA, ground: cur) ?? accA).geometry(grade)
            }
            var pbo: CVPixelBuffer?
            if let pool = ad.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbo)
            } else {
                CVPixelBufferCreate(nil, ow, oh, kCVPixelFormatType_32BGRA, nil, &pbo)
            }
            guard let pb = pbo else { return }
            var outF = src.w == ow && src.h == oh ? src : src.scaled(ow, oh)
            if opts.mark != 0 && !reel { outF.stamp(markText(urls[i])) }
            outF.copy(to: pb)
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
        guard writer.status == .completed, idx > 0 else {
            let why = writer.error?.localizedDescription ?? "неизвестно"
            Diag.event("Ошибка записи видео: \(why), записано кадров \(idx), статус \(writer.status.rawValue)")
            return "Ошибка записи видео. Если приложение сворачивалось во время сборки - собери ещё раз, не сворачивая"
        }
        if !toPhotos { return keepInApp(out, move: true) }
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
        return ok ? (reel ? "Видео 3 в 1 сохранено в галерее телефона" : "Видео сохранено в галерее телефона") : "Нет доступа к галерее телефона. Видео лежит в Файлы → NightLapse"
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
    /// Съёмка, которая только что закончилась: для неё сначала простой экран «Ночь готова»
    @State private var quickID: String?

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
                    VStack(spacing: 12) {
                        Image(systemName: "moon.stars")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(Pal(night: false).accent)
                        Text("Пока нет съёмок").font(.headline)
                        Text("Поставь телефон на штатив, нажми красную кнопку, а утром - «Стоп». Съёмка появится здесь, и откроется редактор")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Вернуться к съёмке") { dismiss() }
                            .buttonStyle(.borderedProminent)
                            .tint(Pal(night: false).accent)
                            .foregroundStyle(Color.black)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .listRowBackground(Color.clear)
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
                ShootEditor(shoot: s, quick: s.id == quickID) { reload() }
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
                quickID = s.id
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
    /// Простой экран «Ночь готова»: видео и одна кнопка «Экспорт». «Настроить» открывает редактор
    @State private var simple: Bool
    @State private var tab: EditTab = .adjust
    @State private var tool: Tool = .exposure
    /// «Авто» включено: ползунки выставлены автоматически
    @State private var autoOn = false

    init(shoot: Shoot, quick: Bool = false, onDeleted: @escaping () -> Void = {}) {
        self.shoot = shoot
        self.onDeleted = onDeleted
        _simple = State(initialValue: quick)
    }

    enum EditTab: String, CaseIterable, Identifiable {
        case look, adjust, crop
        var id: String { rawValue }
        var title: String { ["Вид", "Коррекция", "Обрезать"][Self.allCases.firstIndex(of: self)!] }
        var icon: String { ["film", "dial.medium", "crop.rotate"][Self.allCases.firstIndex(of: self)!] }
    }

    /// Инструменты коррекции, как в редакторе Фото: круг, под ним шкала
    enum Tool: String, CaseIterable, Identifiable {
        case exposure, shadows, highlights, contrast, sat, temp, tint, vignette
        var id: String { rawValue }
        var title: String {
            switch self {
            case .exposure: return "Яркость"
            case .shadows: return "Тени"
            case .highlights: return "Света"
            case .contrast: return "Контраст"
            case .sat: return "Насыщенность"
            case .temp: return "Тепло"
            case .tint: return "Оттенок"
            case .vignette: return "Виньетка"
            }
        }
        var icon: String {
            switch self {
            case .exposure: return "sun.max"
            case .shadows: return "circle.lefthalf.filled"
            case .highlights: return "circle.righthalf.filled"
            case .contrast: return "circle.lefthalf.striped.horizontal"
            case .sat: return "drop"
            case .temp: return "thermometer.medium"
            case .tint: return "eyedropper"
            case .vignette: return "circle.dashed"
            }
        }
        var key: WritableKeyPath<Grade, Float> {
            switch self {
            case .exposure: return \.exposure
            case .shadows: return \.shadows
            case .highlights: return \.highlights
            case .contrast: return \.contrast
            case .sat: return \.sat
            case .temp: return \.temp
            case .tint: return \.tint
            case .vignette: return \.vignette
            }
        }
    }
    @Environment(\.dismiss) private var dismiss
    @StateObject private var r = Renderer()
    @State private var look: Look = .starlapse
    /// Видео 3 в 1: вертикально, сверху как снято, ниже средний и длинный след
    @State private var stack3 = false
    @State private var askExport = false
    /// Просмотр черновика видео
    @State private var playing = false
    @State private var clipIdx = 0
    private let ticker = Timer.publish(every: 1.0 / 15, on: .main, in: .common).autoconnect()
    @State private var exportOpts = ExportOpts()
    /// Размер исходных кадров - для подсказки, сколько займёт файл
    @State private var srcSize = (3840, 2160)
    /// Съёмка, начатая вскоре после этой (до 12 часов), - кандидат на склейку
    @State private var nextShoot: Shoot?
    /// Если эта съёмка сама продолжила оборванную - та, оборванная
    @State private var prevShoot: Shoot?
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

    /// Текущий кадр черновика с цветом и кадрированием - ползунки видны сразу
    private var clipImage: UIImage? {
        guard !r.clip.isEmpty else { return nil }
        var f = r.clip[min(clipIdx, r.clip.count - 1)]
        f.apply(grade)
        return f.geometry(grade).cgImage().map { UIImage(cgImage: $0) }
    }

    /// Сколько прошло от конца этой съёмки до начала следующей
    private func gapText(_ nx: Shoot) -> String {
        let fm = FileManager.default
        var sec = nx.date.timeIntervalSince(shoot.date)
        if let last = ShootStore.frameURLs(shoot.dir).last,
           let t = (try? fm.attributesOfItem(atPath: last.path))?[.modificationDate] as? Date {
            sec = nx.date.timeIntervalSince(t)
        }
        let m = max(0, Int((sec / 60).rounded()))
        return m < 60 ? "\(m) мин" : "\(m / 60) ч \(m % 60) мин"
    }

    // MARK: Части экрана

    /// Просмотр: кадр или черновик видео с кнопкой ▶ и перемоткой
    private var previewBox: some View {
        ZStack {
            Color(white: 0.08)
            if (playing || clipIdx > 0), let img = clipImage {
                Image(uiImage: img).resizable().scaledToFit()
            } else if let p = r.preview {
                Image(uiImage: p).resizable().scaledToFit()
            }
            if r.previewBusy && !playing { ProgressView() }
            if look.isVideo {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Button {
                            if r.clip.isEmpty { r.makeClip(shoot, eff, trail) }
                            playing.toggle()
                        } label: {
                            Group {
                                if r.clipBusy && playing { ProgressView().tint(.white) }
                                else { Image(systemName: playing ? "pause.fill" : "play.fill") }
                            }
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.55), in: Circle())
                        }
                        if !r.clip.isEmpty {
                            Slider(value: Binding(get: { Double(clipIdx) }, set: { clipIdx = Int($0) }),
                                   in: 0...Double(max(r.clip.count - 1, 1)))
                        }
                    }
                    .padding(10)
                }
            }
        }
        .aspectRatio(eff == .reel ? 0.75 : 16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onReceive(ticker) { _ in
            guard playing, !r.clip.isEmpty else { return }
            clipIdx = (clipIdx + 1) % r.clip.count
        }
    }

    /// Ход экспорта, результат, «Поделиться», готовый отчёт
    @ViewBuilder private var statusArea: some View {
        if r.busy {
            VStack(spacing: 8) {
                ProgressView(value: r.progress)
                Text("\(r.message) \(Int(r.progress * 100))%. Не сворачивай приложение")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Остановить") { r.cancel() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal)
        } else {
            VStack(spacing: 8) {
                if !r.message.isEmpty {
                    Text(r.message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    if let f = r.lastFile {
                        ShareLink(item: f) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.bordered)
                    }
                    if let u = reportURL {
                        ShareLink(item: u) { Label("Отправить отчёт", systemImage: "doc.text") }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    /// Сколько длилась съёмка: от первого до последнего кадра
    private var durationText: String {
        let urls = ShootStore.frameURLs(shoot.dir)
        func t(_ u: URL?) -> Date? {
            guard let u else { return nil }
            return (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
        }
        guard let a = t(urls.first), let b = t(urls.last) else { return "" }
        let m = Int(b.timeIntervalSince(a) / 60)
        return m < 60 ? "\(m) мин" : "\(m / 60) ч \(m % 60) мин"
    }

    /// Утром после «Стоп»: одно видео и одна кнопка
    private var readyView: some View {
        ScrollView {
            VStack(spacing: 16) {
                previewBox
                VStack(spacing: 4) {
                    Text("Ночь готова").font(.title2.bold())
                    Text("\(durationText) · \(shoot.frames) кадров").font(.subheadline).foregroundStyle(.secondary)
                }
                Picker("Вид", selection: $look) {
                    ForEach([Look.starlapse, .timelapse]) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(r.busy)
                Button { askExport = true } label: {
                    Text("Экспорт").font(.headline).frame(maxWidth: .infinity).frame(height: 52)
                        .foregroundStyle(Color.black)
                        .background(Pal(night: false).accent, in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(r.busy)
                Button("Настроить") {
                    playing = false
                    withAnimation(.easeInOut(duration: 0.25)) { simple = false }
                }
                .font(.body.weight(.semibold))
                .disabled(r.busy)
                statusArea
            }
            .padding()
        }
        .onAppear {
            // Видео сразу крутится
            if r.clip.isEmpty { r.makeClip(shoot, eff, trail) }
            playing = true
        }
    }

    /// Редактор как в Фото: сверху просмотр, снизу инструменты выбранной вкладки и сами вкладки
    private var editorView: some View {
        VStack(spacing: 12) {
            previewBox.padding(.horizontal)
            statusArea
            Spacer(minLength: 0)
            Group {
                switch tab {
                case .look: lookTab
                case .adjust: adjustTab
                case .crop: cropTab
                }
            }
            .disabled(r.busy)
            .transition(.opacity)
            tabBar
        }
        .padding(.top, 8)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(EditTab.allCases) { t in
                let on = tab == t
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { tab = t }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 18, weight: on ? .semibold : .regular))
                        Text(t.title).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(on ? Pal(night: false).accent : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
            }
        }
        .padding(6)
        .background(Color(white: 0.14), in: Capsule())
        .padding(.horizontal, 40)
        .padding(.bottom, 6)
    }

    /// Вкладка «Вид»: что собирать, длина следа, кадры, склейка
    private var lookTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
                if look == .starlapse {
                    Text("Длина следа").font(.footnote).foregroundStyle(.secondary)
                    Picker("Длина следа", selection: $trail) {
                        ForEach(Trail.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Button { showFrames = true } label: {
                    HStack {
                        Label("Кадры", systemImage: "film.stack")
                        Spacer()
                        Text(excluded.isEmpty ? "все \(shoot.frames) в деле" : "исключено \(excluded.count) из \(shoot.frames)")
                            .foregroundStyle(excluded.isEmpty ? Color.secondary : Color.orange)
                    }
                    .font(.footnote)
                }
                Text(look.hint).font(.footnote).foregroundStyle(.secondary)
                if let pv = prevShoot {
                    mergeCard("Эта съёмка продолжила оборванную. Их можно склеить в одну: пропущенные кадры дорисуются по движению звёзд",
                              "Склеить с началом") { r.merge(pv, shoot) { ok in if ok { onDeleted() } } }
                }
                if let nx = nextShoot {
                    mergeCard("Через \(gapText(nx)) началась следующая съёмка. Если камера не двигалась, их можно склеить в одну",
                              "Склеить со следующей съёмкой") { r.merge(shoot, nx) { ok in if ok { onDeleted() } } }
                }
            }
            .padding(.horizontal)
        }
        .frame(maxHeight: 300)
    }

    private func mergeCard(_ text: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.footnote).foregroundStyle(.secondary)
            Button(action: action) { Label(title, systemImage: "link") }
                .buttonStyle(.bordered)
        }
    }

    /// Вкладка «Коррекция»: название и значение, круги инструментов, шкала
    private var adjustTab: some View {
        let v = grade[keyPath: tool.key]
        return VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(tool.title.uppercased()).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Text(String(format: "%+.0f", v * 100)).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                if !grade.isNeutral {
                    Button("Сбросить всё") { grade = Grade() }.font(.footnote)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    // Авто, как волшебная палочка в Фото: подбирает яркость и цвет, ползунки потом можно подправить
                    ToolCircle(icon: "wand.and.stars", value: 0, on: autoOn)
                        .onTapGesture { toggleAuto() }
                    ForEach(Tool.allCases) { t in
                        ToolCircle(icon: t.icon, value: grade[keyPath: t.key], on: tool == t)
                            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { tool = t } }
                    }
                }
                .padding(.horizontal)
            }
            Ruler(value: Binding(get: { grade[keyPath: tool.key] }, set: { grade[keyPath: tool.key] = $0 }), range: -1...1)
                .frame(height: 36)
                .padding(.horizontal)
        }
    }

    private func toggleAuto() {
        if autoOn {
            var g = Grade()
            g.vignette = grade.vignette
            g.angle = grade.angle
            g.crop = grade.crop
            grade = g
            autoOn = false
            return
        }
        let urls = ShootStore.frameURLs(shoot.dir)
        guard !urls.isEmpty, let c = ShootStore.thumb(urls[urls.count / 2], maxPixel: 400) else { return }
        var f = Frame(w: c.width, h: c.height)
        f.draw(c)
        let a = Grade.auto(f)
        withAnimation(.easeOut(duration: 0.25)) {
            grade.exposure = a.exposure
            grade.temp = a.temp
            grade.tint = a.tint
            grade.shadows = a.shadows
            grade.contrast = a.contrast
            grade.sat = a.sat
            autoOn = true
        }
    }

    /// Вкладка «Обрезать»: горизонт шкалой и формат
    private var cropTab: some View {
        VStack(spacing: 12) {
            Text("ГОРИЗОНТ \(String(format: "%+.1f°", grade.angle))")
                .font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
            Ruler(value: $grade.angle, range: -10...10)
                .frame(height: 36)
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Grade.Crop.allCases) { c in
                        let on = grade.crop == c
                        Button { grade.crop = c } label: {
                            Text(c.title)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .foregroundStyle(on ? Color.black : Color.primary)
                                .background(on ? Pal(night: false).accent : Color(white: 0.18), in: Capsule())
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// «…»: отчёт и удаление исходников
    private var moreMenu: some View {
        Menu {
            Button {
                reportBusy = true
                Diag.makeReport { u in
                    reportURL = u
                    reportBusy = false
                }
            } label: { Label("Собрать отчёт для улучшения", systemImage: "doc.text.magnifyingglass") }
            Section("Исходники: \(shoot.frames) кадров, \(sizeText(shoot.bytes)). Файлы → NightLapse") {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Удалить исходники", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: reportBusy ? "hourglass" : "ellipsis.circle")
        }
        .disabled(r.busy)
    }

    var body: some View {
        Group {
            if simple { readyView } else { editorView }
        }
        .toolbar {
            if !simple {
                ToolbarItem(placement: .topBarTrailing) { moreMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Экспорт") { askExport = true }
                        .fontWeight(.semibold)
                        .disabled(r.busy)
                }
            }
        }
        .sheet(isPresented: $askExport) {
            ExportSheet(isVideo: eff.isVideo, frames: shoot.frames, fps: shoot.fps, src: srcSize, opts: $exportOpts) {
                askExport = false
                r.run(shoot, eff, trail, denoise: denoise, grade: grade, deflicker: deflicker, opts: exportOpts)
            }
            .presentationDetents([.medium, .large])
        }
        .navigationTitle(simple ? "" : "Коррекция")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(r.busy)
        .interactiveDismissDisabled(r.busy)
        .onAppear {
            excluded = FramePlan.excluded(shoot.dir)
            r.makePreview(shoot, eff, trail, grade)
            if let u = ShootStore.frameURLs(shoot.dir).first, let src = CGImageSourceCreateWithURL(u as CFURL, nil),
               let pr = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let pw = pr[kCGImagePropertyPixelWidth] as? Int, let ph = pr[kCGImagePropertyPixelHeight] as? Int {
                srcSize = (pw, ph)
            }
            let me = shoot
            if let c = ShootStore.readInfo(shoot.dir)["continues"] as? String, !c.isEmpty {
                prevShoot = ShootStore.list().first { $0.id == c }
            }
            nextShoot = ShootStore.list()
                .filter { $0.date > me.date && $0.date.timeIntervalSince(me.date) < 12 * 3600 && !$0.id.contains("склейка") }
                .min { $0.date < $1.date }
        }
        .sheet(isPresented: $showFrames, onDismiss: {
            FramePlan.save(shoot.dir, excluded)
            r.clip = []
            clipIdx = 0
            playing = false
            r.makePreview(shoot, eff, trail, grade)
        }) {
            FramePicker(shoot: shoot, excluded: $excluded)
        }
        .onChange(of: look) {
            r.makePreview(shoot, eff, trail, grade)
            clipIdx = 0
            r.clip = []
            if !look.isVideo { playing = false }
            if playing { r.makeClip(shoot, eff, trail) }
        }
        .onChange(of: trail) {
            r.makePreview(shoot, eff, trail, grade)
            clipIdx = 0
            r.clip = []
            if playing { r.makeClip(shoot, eff, trail) }
        }
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
            Text("\(shoot.frames) кадров будут удалены навсегда. Видео и фото, уже сохранённые в галерее телефона, останутся")
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

// MARK: - Где небо, а где земля

/// Маска неба: 255 - небо, 0 - земля. Горизонт ищем по столбцам снизу вверх: земля ночью темнее неба.
/// Так угол кадра, затемнённый широким объективом, не путается с землёй - он выше горизонта.
/// Если земля светлая (луна, снег, город), всё считается небом - как было раньше
struct SkyMask {
    let w: Int, h: Int
    var m: [UInt8]

    /// По средней яркости зелёного блоками blk×blk (bw×bh блоков)
    static func fromBlocks(_ bm: [Float], bw: Int, bh: Int, blk: Int, w: Int, h: Int) -> SkyMask? {
        guard bw > 2, bh > 4 else { return nil }
        var hz = [Float](repeating: 0, count: bw)   // граница неба в пикселях по каждому столбцу блоков
        for x in 0..<bw {
            let col = (0..<bh).map { bm[$0 * bw + x] }
            let lv = col.sorted()[bh * 9 / 10]
            let thr = 0.5 * lv
            var y = bh - 1
            // Снизу вверх, пока не встретим два блока неба подряд
            while y > 0 && !(col[y] >= thr && col[y - 1] >= thr) { y -= 1 }
            hz[x] = lv < 3 ? Float(h) : Float(y + 1) * Float(blk)   // совсем тёмный столбец - не трогаем
        }
        // Сгладить: медиана по 5 столбцам убирает одиночные просветы между деревьями
        let raw = hz
        for x in 0..<bw {
            let win = (max(0, x - 2)...min(bw - 1, x + 2)).map { raw[$0] }.sorted()
            hz[x] = win[win.count / 2]
        }
        let groundPx = hz.reduce(0) { $0 + max(0, Float(h) - $1) } / Float(bw)
        guard groundPx > Float(h) * 0.02 else { return nil }   // земли почти нет - маска не нужна
        let edges = hz
        var out = SkyMask(w: w, h: h, m: [UInt8](repeating: 255, count: w * h))
        let ramp = Float(blk)
        out.m.withUnsafeMutableBufferPointer { d in
            DispatchQueue.concurrentPerform(iterations: 8) { part in
                for x in stride(from: part, to: w, by: 8) {
                    let fx = min(max(Float(x) / Float(blk) - 0.5, 0), Float(bw - 1))
                    let x0 = Int(fx), x1 = min(x0 + 1, bw - 1), wx = fx - Float(x0)
                    let edge = edges[x0] * (1 - wx) + edges[x1] * wx
                    let y0 = max(0, Int(edge - ramp)), y1 = min(h, Int(edge + ramp) + 1)
                    if y0 < h {
                        for y in y0..<y1 {
                            let t = min(max((edge - Float(y)) / (2 * ramp) + 0.5, 0), 1)
                            d[y * w + x] = UInt8(t * 255)
                        }
                    }
                    if y1 < h { for y in y1..<h { d[y * w + x] = 0 } }
                }
            }
        }
        return out
    }

    /// По нескольким кадрам съёмки
    static func build(_ urls: [URL], w: Int, h: Int) -> SkyMask? {
        let blk = 8
        let bw = w / blk, bh = h / blk
        guard bw > 2, bh > 4, !urls.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: bw * bh)
        var n = 0
        var f = Frame(w: w, h: h)
        for u in urls {
            guard let c = ShootStore.full(u), c.width == w, c.height == h else { continue }
            f.draw(c)
            f.px.withUnsafeBufferPointer { p in
                for by in 0..<bh {
                    for bx in 0..<bw {
                        var s: Float = 0
                        for yy in stride(from: by * blk, to: by * blk + blk, by: 2) {
                            for xx in stride(from: bx * blk, to: bx * blk + blk, by: 2) { s += Float(p[(yy * w + xx) * 4 + 1]) }
                        }
                        sum[by * bw + bx] += s / Float(blk * blk / 4)
                    }
                }
            }
            n += 1
        }
        guard n > 0 else { return nil }
        return fromBlocks(sum.map { $0 / Float(n) }, bw: bw, bh: bh, blk: blk, w: w, h: h)
    }

    /// Небо из sky, земля из ground
    func blend(sky: Frame, ground: Frame) -> Frame {
        guard sky.w == w, sky.h == h, ground.w == w, ground.h == h else { return sky }
        var out = sky
        let w = self.w, h = self.h
        ground.px.withUnsafeBufferPointer { g in
            m.withUnsafeBufferPointer { mk in
                out.px.withUnsafeMutableBufferPointer { d in
                    DispatchQueue.concurrentPerform(iterations: 8) { part in
                        for i in (part * w * h / 8)..<((part + 1) * w * h / 8) {
                            let a = Int(mk[i])
                            if a == 255 { continue }
                            let o = i * 4
                            for c in 0..<3 { d[o + c] = UInt8((Int(d[o + c]) * a + Int(g[o + c]) * (255 - a) + 127) / 255) }
                        }
                    }
                }
            }
        }
        return out
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
                        guard e1 > 10, x >= 5, y >= 5, x < w - 5, y < h - 5 else { continue }
                        // Тянем только точки: заметно ярче соседей в 5 пикселях со всех сторон.
                        // Край неба у деревьев ярче среднего по блоку, но не ярче неба рядом - его не трогаем
                        let gc = Int(p[o + 1])
                        let nb = max(max(Int(p[o + 1 - 20]), Int(p[o + 1 + 20])), max(Int(p[o + 1 - w * 20]), Int(p[o + 1 + w * 20])))
                        guard gc > nb + 10 else { continue }
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


extension Grade {
    /// Автоподбор по кадру: яркость к нормальной для ночи или дня, нейтральный цвет фона, чуть теней и контраста
    static func auto(_ f: Frame) -> Grade {
        var hb = [Int](repeating: 0, count: 256), hg = hb, hr = hb
        f.px.withUnsafeBufferPointer { p in
            var i = 0
            while i + 2 < p.count {
                hb[Int(p[i])] += 1; hg[Int(p[i + 1])] += 1; hr[Int(p[i + 2])] += 1
                i += 8
            }
        }
        func med(_ h: [Int]) -> Float {
            let half = h.reduce(0, +) / 2
            var acc = 0
            for v in 0..<256 { acc += h[v]; if acc >= half { return Float(max(v, 1)) } }
            return 128
        }
        let mb = med(hb), mg = med(hg), mr = med(hr)
        let luma = 0.11 * mb + 0.59 * mg + 0.3 * mr
        let target: Float = luma < 80 ? 45 : 115
        var g = Grade()
        g.exposure = min(max(log2(target / luma) / 1.5, -1), 1)
        g.temp = min(max((mb - mr) / (0.3 * (mb + mr)), -1), 1)
        g.tint = min(max((1 - (mb + mr) / 2 / mg) / 0.18, -1), 1)
        g.shadows = 0.15
        g.contrast = 0.1
        g.sat = 0.1
        return g
    }
}

// MARK: - Круг инструмента и шкала, как в редакторе Фото

/// Круг с значком; дуга показывает, насколько инструмент сдвинут от нуля
struct ToolCircle: View {
    let icon: String
    let value: Float
    let on: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(on ? 0.5 : 0.18), lineWidth: 1.5)
            if abs(value) > 0.005 {
                Circle()
                    .trim(from: 0, to: CGFloat(min(abs(value), 1)))
                    .stroke(Pal(night: false).accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .scaleEffect(x: value < 0 ? -1 : 1, y: 1)
            }
            Image(systemName: icon)
                .font(.system(size: 18, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.7))
        }
        .frame(width: 52, height: 52)
        .background(Color.white.opacity(on ? 0.1 : 0), in: Circle())
        .contentShape(Circle())
    }
}

/// Шкала с рисками: тянешь пальцем вбок - значение меняется. Двойное касание - ноль
struct Ruler: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    @State private var start: Float?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let span = range.upperBound - range.lowerBound
            // Вся шкала - две ширины экрана, середина - текущее значение
            let pxPer = Float(w) * 2 / span
            let offset = CGFloat((value - (range.lowerBound + range.upperBound) / 2) * pxPer)
            ZStack {
                Canvas { ctx, size in
                    let n = 60
                    for i in 0...n {
                        let x = size.width / 2 - offset + (CGFloat(i) / CGFloat(n) - 0.5) * size.width * 2
                        guard x >= 0, x <= size.width else { continue }
                        let major = i % 10 == 0
                        let hgt: CGFloat = major ? 18 : 10
                        let rect = CGRect(x: x - 0.5, y: (size.height - hgt) / 2, width: 1, height: hgt)
                        ctx.fill(Path(rect), with: .color(Color.white.opacity(major ? 0.6 : 0.3)))
                    }
                }
                Rectangle().fill(Pal(night: false).accent).frame(width: 2, height: 30)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { d in
                    if start == nil { start = value }
                    let v = (start ?? value) - Float(d.translation.width) / pxPer
                    value = min(max(v, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in start = nil })
            .onTapGesture(count: 2) { value = 0 }
        }
    }
}

// MARK: - Окно экспорта

/// Экспорт: готовый набор под площадку или свои настройки, и куда сохранить
struct ExportSheet: View {
    let isVideo: Bool
    var frames = 0
    var fps = 30
    var src = (3840, 2160)
    @Binding var opts: ExportOpts
    @AppStorage("denoise") private var denoise = true
    @AppStorage("deflicker") private var deflicker = true
    let onExport: () -> Void
    @State private var preset: ExportOpts.Preset? = .original
    private let pal = Pal(night: false)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("Для чего") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(ExportOpts.Preset.allCases) { p in
                                    let on = preset == p
                                    Button {
                                        preset = p
                                        let dest = opts.toPhotos
                                        opts = ExportOpts.preset(p)
                                        opts.toPhotos = dest
                                    } label: {
                                        Label(p.title, systemImage: p.icon)
                                            .font(.subheadline.weight(.semibold))
                                            .padding(.horizontal, 14)
                                            .frame(height: 40)
                                            .foregroundStyle(on ? Color.black : Color.primary)
                                            .background(on ? pal.accent : Color.secondary.opacity(0.15), in: Capsule())
                                    }
                                }
                            }
                        }
                    }
                    section("Размер") {
                        Picker("Размер", selection: custom(\.res)) {
                            ForEach(ExportOpts.Res.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if isVideo {
                        section("Кадров в секунду") {
                            Picker("Кадров в секунду", selection: custom(\.fps)) {
                                Text("Как снято").tag(0)
                                Text("24").tag(24)
                                Text("25").tag(25)
                                Text("30").tag(30)
                                Text("60").tag(60)
                            }
                            .pickerStyle(.segmented)
                        }
                        section("Качество") {
                            Picker("Качество", selection: custom(\.quality)) {
                                ForEach(ExportOpts.Quality.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            Text(sizeLine).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        }
                        section("Чистота") {
                            Toggle("Убрать шум", isOn: $denoise)
                            Toggle("Без мерцания", isOn: $deflicker)
                        }
                    }
                    section("Цвет") {
                        Toggle("Авто-цвет", isOn: $opts.autoColor)
                    }
                    section("Подпись в углу") {
                        Picker("Подпись", selection: $opts.mark) {
                            Text("Нет").tag(0)
                            Text("Дата и время").tag(1)
                            Text("Свой текст").tag(2)
                        }
                        .pickerStyle(.segmented)
                        if opts.mark == 2 {
                            TextField("Например, @имя или место", text: $opts.markText)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    section("Куда") {
                        Picker("Куда", selection: $opts.toPhotos) {
                            Text("Галерея телефона").tag(true)
                            Text("Приложение").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                    Button(action: onExport) {
                        Text("Экспорт")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .foregroundStyle(Color.black)
                            .background(pal.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(16)
            }
            .navigationTitle("Экспорт")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Битрейт и примерный размер файла
    private var sizeLine: String {
        let mb = opts.mbps(src.0, src.1)
        let rate = Double(opts.fps > 0 ? opts.fps : max(fps, 1))
        let sec = Double(frames) / rate
        let size = Double(mb) * sec / 8
        let (ow, oh) = opts.fit(src.0, src.1)
        let sizeText = size >= 1000 ? String(format: "%.1f ГБ", size / 1000) : String(format: "%.0f МБ", max(size, 1))
        return "\(ow)×\(oh) · \(mb) Мбит/с · видео \(String(format: "%.0f", sec)) с · около \(sizeText)"
    }

    /// Ручная правка снимает выбор готового набора
    private func custom<T>(_ kp: WritableKeyPath<ExportOpts, T>) -> Binding<T> {
        Binding(get: { opts[keyPath: kp] }, set: { v in
            opts[keyPath: kp] = v
            preset = nil
        })
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
