// Оценка кадра: резкость звёзд (фокус), форма звёзд (смаз), яркость и цвет неба, зерно.
// Размеры звёзд - в точках картинки с длинной стороной 1000: у разных кадров числа сравнимы.
// Пороги взяты из полного теста 01.11: фокус 0.80 - звёзды 3.5 точки, 0.50 и 1.00 - около 6 (кружки)

import Foundation
import CoreGraphics
import CoreVideo
import ImageIO

struct FrameQuality {
    var stars = 0          // сколько звёзд нашлось
    var fwhm = 0.0         // размер звезды на половине яркости, медиана
    var elong = 0.0        // вытянутость звезды: 1 - круг, больше 1.8 - черточка
    var sky = 0.0          // яркость неба (медиана, 0...255)
    var skyR = 0.0, skyG = 0.0, skyB = 0.0
    var noise = 0.0        // зерно на тёмном (разница соседних точек)

    /// Число для подбора фокуса: больше звёзд и меньше их размер - лучше
    var focusScore: Double { stars < 3 || fwhm <= 0 ? 0 : Double(stars) * 10 / (fwhm * fwhm) }

    enum Focus { case sharp, soft, off, unknown }
    var focus: Focus {
        if stars < 15 { return .unknown }
        if fwhm <= 4.2 { return .sharp }
        if fwhm <= 5.2 { return .soft }
        return .off
    }

    /// Коротко, по-русски: что с кадром
    var verdict: [(String, Bool)] {
        var v: [(String, Bool)] = []
        switch focus {
        case .sharp: v.append((String(format: "Фокус резкий: звёзды %.1f точки, нашлось %d", fwhm, stars), true))
        case .soft: v.append((String(format: "Фокус мягкий: звёзды %.1f точки (резко - до 4.2)", fwhm), false))
        case .off: v.append((String(format: "Мимо фокуса: звёзды %.1f точки - кружки", fwhm), false))
        case .unknown: v.append(("Звёзд мало - фокус не оценить", true))
        }
        if stars >= 15 && elong > 1.8 { v.append((String(format: "Звёзды вытянуты (%.1f): смаз или выдержка длинная", elong), false)) }
        if sky > 95 { v.append((String(format: "Небо светлое: %.0f (хорошо около 58)", sky), false)) }
        else if sky < 25 { v.append((String(format: "Небо тёмное: %.0f (хорошо около 58)", sky), false)) }
        if skyG > 5 {
            if skyR > skyG * 1.08 && skyB > skyG * 1.0 { v.append(("Небо уходит в фиолетовый", false)) }
            else if skyG > skyR * 1.15 && skyG > skyB * 1.05 { v.append(("Небо уходит в зелёный", false)) }
        }
        return v
    }

    var csv: [String] {
        [String(stars), String(format: "%.2f", fwhm), String(format: "%.2f", elong), String(format: "%.1f", sky), String(format: "%.2f", noise)]
    }

    var dict: [String: Any] {
        ["q_stars": stars, "q_fwhm": fwhm, "q_elong": elong, "q_sky": sky, "q_sky_rgb": [skyR, skyG, skyB], "q_noise": noise]
    }

    // MARK: Вход

    static func of(_ cg: CGImage) -> FrameQuality {
        let s = 1000.0 / Double(max(cg.width, cg.height))
        let w = max(16, Int(Double(cg.width) * s)), h = max(16, Int(Double(cg.height) * s))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return FrameQuality() }
        px.withUnsafeMutableBytes { b in
            if let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.interpolationQuality = .medium
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        // RGBX
        return analyze(px, w, h, r: 0, g: 1, b: 2)
    }

    static func of(url: URL) -> FrameQuality? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1000,
              ] as CFDictionary) else { return nil }
        return of(cg)
    }

    /// Кадр камеры (BGRA): уменьшаем средним по блокам до длинной стороны около 1000
    static func of(_ pb: CVPixelBuffer) -> FrameQuality {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return FrameQuality() }
        let W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        let k = max(1, Int((Double(max(W, H)) / 1000).rounded()))
        let w = W / k, h = H / k
        guard w > 16, h > 16 else { return FrameQuality() }
        let p = base.assumingMemoryBound(to: UInt8.self)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let kk = k * k
        for y in 0..<h {
            for x in 0..<w {
                var b = 0, g = 0, r = 0
                for dy in 0..<k {
                    let row = (y * k + dy) * rb + x * k * 4
                    for dx in 0..<k {
                        let o = row + dx * 4
                        b += Int(p[o]); g += Int(p[o + 1]); r += Int(p[o + 2])
                    }
                }
                let o = (y * w + x) * 4
                px[o] = UInt8(b / kk); px[o + 1] = UInt8(g / kk); px[o + 2] = UInt8(r / kk)
            }
        }
        // BGRA
        return analyze(px, w, h, r: 2, g: 1, b: 0)
    }

    // MARK: Разбор

    static func analyze(_ px: [UInt8], _ w: Int, _ h: Int, r ri: Int, g gi: Int, b bi: Int) -> FrameQuality {
        var q = FrameQuality()
        let n = w * h
        var L = [Float](repeating: 0, count: n)
        var hist = [Int](repeating: 0, count: 256)
        for i in 0..<n {
            let l = 0.299 * Float(px[i * 4 + ri]) + 0.587 * Float(px[i * 4 + gi]) + 0.114 * Float(px[i * 4 + bi])
            L[i] = l
            hist[min(255, max(0, Int(l)))] += 1
        }
        var acc = 0, med = 0
        for (v, c) in hist.enumerated() { acc += c; if acc >= n / 2 { med = v; break } }
        q.sky = Double(med)
        // Цвет неба: средние каналов у точек около медианы (без звёзд, деревьев и облаков)
        var sr = 0.0, sg = 0.0, sb = 0.0, sc = 0.0
        var ns = 0.0, nn = 0.0
        for i in stride(from: 0, to: n - 1, by: 3) {
            if abs(L[i] - Float(med)) <= 6 {
                sr += Double(px[i * 4 + ri]); sg += Double(px[i * 4 + gi]); sb += Double(px[i * 4 + bi]); sc += 1
            }
            if L[i] <= Float(med) && (i + 1) % w != 0 { ns += Double(abs(L[i] - L[i + 1])); nn += 1 }
        }
        if sc > 0 { q.skyR = sr / sc; q.skyG = sg / sc; q.skyB = sb / sc }
        q.noise = nn > 0 ? ns / nn : 0

        // Фон рядом: среднее в окне 15×15 (через сумму по площади)
        let k = 7, s = 2 * k + 1
        var I = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0.0
            for x in 0..<w {
                row += Double(L[y * w + x])
                I[(y + 1) * (w + 1) + x + 1] = I[y * (w + 1) + x + 1] + row
            }
        }
        func box(_ x: Int, _ y: Int) -> Float {
            let x0 = max(0, x - k), y0 = max(0, y - k), x1 = min(w, x + k + 1), y1 = min(h, y + k + 1)
            let a = Double((x1 - x0) * (y1 - y0))
            let v = I[y1 * (w + 1) + x1] - I[y0 * (w + 1) + x1] - I[y1 * (w + 1) + x0] + I[y0 * (w + 1) + x0]
            return Float(v / max(a, 1))
        }
        _ = s
        let thr = max(Float(q.noise * 1.4 + 0.5) * 6, 4)
        // Кандидаты: точка ярче фона на порог и самая яркая в окне 5×5
        var cand: [(Float, Int, Int)] = []
        var d = [Float](repeating: 0, count: n)
        for y in 0..<h { for x in 0..<w { d[y * w + x] = L[y * w + x] - box(x, y) } }
        for y in 6..<(h - 6) {
            for x in 6..<(w - 6) {
                let v = d[y * w + x]
                if v <= thr { continue }
                var isMax = true
                for dy in -2...2 {
                    for dx in -2...2 where (dy != 0 || dx != 0) {
                        if d[(y + dy) * w + x + dx] > v { isMax = false; break }
                    }
                    if !isMax { break }
                }
                if isMax { cand.append((v, x, y)) }
            }
        }
        q.stars = cand.count
        cand.sort { $0.0 > $1.0 }
        var sizes: [Double] = [], elongs: [Double] = []
        for c in cand {
            if sizes.count >= 80 { break }
            let p = c.0, x = c.1, y = c.2
            var sat = 0, area = 0
            var ws = 0.0, cy = 0.0, cx = 0.0
            for dy in -5...5 {
                for dx in -5...5 {
                    let v = max(0, d[(y + dy) * w + x + dx])
                    if v >= 0.98 * p { sat += 1 }
                    if v >= 0.5 * p { area += 1 }
                    ws += Double(v); cy += Double(v) * Double(dy); cx += Double(v) * Double(dx)
                }
            }
            // Плоская вершина - выбитое пятно (фонарь, край облака), не звезда
            if sat > 6 || ws <= 0 { continue }
            cy /= ws; cx /= ws
            var syy = 0.0, sxx = 0.0, sxy = 0.0
            for dy in -5...5 {
                for dx in -5...5 {
                    let v = Double(max(0, d[(y + dy) * w + x + dx]))
                    let ey = Double(dy) - cy, ex = Double(dx) - cx
                    syy += v * ey * ey; sxx += v * ex * ex; sxy += v * ey * ex
                }
            }
            syy /= ws; sxx /= ws; sxy /= ws
            let tr = syy + sxx, det = syy * sxx - sxy * sxy
            let disc = max(tr * tr / 4 - det, 0).squareRoot()
            let l1 = tr / 2 + disc, l2 = max(tr / 2 - disc, 1e-3)
            sizes.append(2 * (Double(area) / Double.pi).squareRoot())
            elongs.append((l1 / l2).squareRoot())
        }
        func median(_ a: [Double]) -> Double {
            guard !a.isEmpty else { return 0 }
            let s = a.sorted()
            return s[s.count / 2]
        }
        q.fwhm = median(sizes)
        q.elong = median(elongs)
        return q
    }
}
