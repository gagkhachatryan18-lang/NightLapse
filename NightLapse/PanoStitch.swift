import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Склейка панорамы 360: геометрия и два варианта (A - быстрый набросок, B - чистовая)
//
// Система координат: мир - z вверх, x и y горизонтально (как у CoreMotion), панорама - равнопромежуточная:
//   направление = (cosφ·sinλ, cosφ·cosλ, sinφ), λ в [-π, π] слева направо, φ от +π/2 (верх) до -π/2.
// Камера: оси устройства x вправо, y вверх, z к человеку; смотрит вдоль -z. Снимок вертикальный.
// Поза снимка - матрица 3×3 по строкам. Какая это поза (мир->устройство или обратная) - решает проверка по картинке.

struct PanoImg {
    let w: Int
    let h: Int
    let px: [UInt8] // RGBA, 4 байта на пиксель
}

struct PanoPose {
    var file: URL
    var R: [Double] // 9 чисел по строкам, как отдали датчики
}

enum PanoMath {
    static func mul(_ a: [Double], _ b: [Double]) -> [Double] {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                var s = 0.0
                for k in 0..<3 { s += a[i * 3 + k] * b[k * 3 + j] }
                r[i * 3 + j] = s
            }
        }
        return r
    }

    static func transpose(_ a: [Double]) -> [Double] {
        [a[0], a[3], a[6], a[1], a[4], a[7], a[2], a[5], a[8]]
    }

    static func rotZ(_ a: Double) -> [Double] {
        let c = cos(a), s = sin(a)
        return [c, -s, 0, s, c, 0, 0, 0, 1]
    }

    /// Матрица мир->устройство при выбранном понимании позы
    static func world2dev(_ R: [Double], conv: Int) -> [Double] {
        conv == 0 ? R : transpose(R)
    }

    /// Куда смотрит камера в мире
    static func forward(_ M: [Double]) -> [Double] {
        [-M[6], -M[7], -M[8]]
    }

    static func angle(_ a: [Double], _ b: [Double]) -> Double {
        let d = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
        return acos(min(1, max(-1, d)))
    }

    /// Углы обзора: по длинной стороне задан, по короткой - из пропорции кадра
    static func fovShort(_ fovLong: Double, aspect: Double) -> Double {
        2 * atan(tan(fovLong / 2) * aspect)
    }

    /// Точки съёмки: кольца по высоте, в каждом - равномерно по кругу, плюс зенит и надир. Курс считается от начала
    static func targets(fovLong: Double, overlap: Double = 0.3) -> [(yaw: Double, pitch: Double)] {
        let fovS = fovShort(fovLong, aspect: 0.75)
        let stepP = fovLong * (1 - overlap)
        var pitches: [Double] = [0]
        var k = 1.0
        while k * stepP < Double.pi / 2 - 0.2 {
            pitches.append(k * stepP)
            pitches.append(-k * stepP)
            k += 1
        }
        var out: [(Double, Double)] = []
        for p in pitches {
            let cp = max(cos(p), 0.2)
            let stepY = fovS * (1 - overlap) / cp
            let n = max(1, Int(ceil(2 * Double.pi / stepY)))
            for i in 0..<n { out.append((2 * Double.pi * Double(i) / Double(n), p)) }
        }
        out.append((0, Double.pi / 2))
        out.append((0, -Double.pi / 2))
        return out
    }
}

// MARK: - Картинки

enum PanoIO {
    /// Снимок с учётом поворота, не больше maxSide по длинной стороне
    static func load(_ url: URL, maxSide: Int) -> PanoImg? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return rgba(cg)
    }

    static func rgba(_ cg: CGImage) -> PanoImg? {
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 255, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? PanoImg(w: w, h: h, px: px) : nil
    }

    static func cgImage(rgba: [UInt8], w: Int, h: Int) -> CGImage? {
        guard let prov = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func jpeg(_ cg: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// JPEG панорамы с метаданными Google Photo Sphere: Google Фото, Карты, Facebook и многие просмотрщики откроют как 360
    static func panoJPEG(rgba: [UInt8], w: Int, h: Int, quality: Double = 0.9) -> Data? {
        guard let cg = cgImage(rgba: rgba, w: w, h: h), let base = jpeg(cg, quality: quality) else { return nil }
        let xml = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"
            + "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description rdf:about=\"\" xmlns:GPano=\"http://ns.google.com/photos/1.0/panorama/\""
            + " GPano:UsePanoramaViewer=\"True\" GPano:ProjectionType=\"equirectangular\""
            + " GPano:CroppedAreaImageWidthPixels=\"\(w)\" GPano:CroppedAreaImageHeightPixels=\"\(h)\""
            + " GPano:FullPanoWidthPixels=\"\(w)\" GPano:FullPanoHeightPixels=\"\(h)\""
            + " GPano:CroppedAreaLeftPixels=\"0\" GPano:CroppedAreaTopPixels=\"0\""
            + " GPano:PoseHeadingDegrees=\"0\" GPano:InitialViewHeadingDegrees=\"0\" GPano:InitialViewPitchDegrees=\"0\""
            + " GPano:InitialViewRollDegrees=\"0\" GPano:StitchingSoftware=\"NightLapse\"/>"
            + "</rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"
        var seg = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
        seg.append(Data(xml.utf8))
        guard seg.count + 2 <= 65535 else { return base }
        var head = Data([0xFF, 0xE1])
        let len = seg.count + 2
        head.append(UInt8(len >> 8))
        head.append(UInt8(len & 0xFF))
        head.append(seg)
        // Вставка после SOI и после начальных APP0/APP1(Exif)
        let bytes = [UInt8](base)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return base }
        var pos = 2
        while pos + 4 <= bytes.count, bytes[pos] == 0xFF, bytes[pos + 1] == 0xE0 || bytes[pos + 1] == 0xE1 {
            let l = Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3])
            pos += 2 + l
        }
        guard pos <= bytes.count else { return base }
        var out = Data(bytes[0..<pos])
        out.append(head)
        out.append(Data(bytes[pos...]))
        return out
    }
}

// MARK: - Отрисовка снимка на сфере

struct PanoRaster {
    let w: Int
    let h: Int
    var data: [Float] // 4 числа на пиксель: r, g, b, вес
}

enum PanoRender {
    /// Рисует снимок в равнопромежуточную сетку W×H. N - матрица мир->устройство с поправкой на курс.
    /// mode 0: записать цвет и вес; 1: добавить цвет×вес; 2: добавить высокую полосу (цвет минус размытая версия) с узким весом
    static func run(img: PanoImg, N: [Double], fovLong: Double, W: Int, H: Int, offX: Double, offY: Double,
                    gain: (Float, Float, Float), mode: Int, out: UnsafeMutablePointer<Float>,
                    low: UnsafePointer<UInt8>? = nil, lowW: Int = 0, lowH: Int = 0, power: Int = 4) {
        let iw = img.w, ih = img.h
        let long = Double(max(iw, ih))
        let fpix = Float((long / 2) / tan(fovLong / 2))
        // Угол от оси камеры до угла кадра - дальше пиксель точно не в кадре
        let halfDiag = atan(hypot(Double(iw), Double(ih)) / 2 / Double(fpix))
        let cosLimit = Float(cos(min(halfDiag + 0.02, Double.pi / 2 - 0.01)))
        let n = N.map { Float($0) }
        // Таблицы по столбцам и строкам
        var sl = [Float](repeating: 0, count: W), cl = [Float](repeating: 0, count: W)
        for i in 0..<W {
            let lam = (Double(i) + 0.5 - offX) / Double(W) * 2 * Double.pi - Double.pi
            sl[i] = Float(sin(lam))
            cl[i] = Float(cos(lam))
        }
        var cp = [Float](repeating: 0, count: H), sp = [Float](repeating: 0, count: H)
        for j in 0..<H {
            let phi = Double.pi / 2 - (Double(j) + 0.5 - offY) / Double(H) * Double.pi
            cp[j] = Float(cos(phi))
            sp[j] = Float(sin(phi))
        }
        var colX = [Float](repeating: 0, count: W), colY = [Float](repeating: 0, count: W), colZ = [Float](repeating: 0, count: W)
        for i in 0..<W {
            colX[i] = n[0] * sl[i] + n[1] * cl[i]
            colY[i] = n[3] * sl[i] + n[4] * cl[i]
            colZ[i] = n[6] * sl[i] + n[7] * cl[i]
        }
        let fw = Float(iw), fh = Float(ih)
        let bands = (H + 15) / 16
        img.px.withUnsafeBufferPointer { ip in
            let base = ip.baseAddress!
            colX.withUnsafeBufferPointer { cx in colY.withUnsafeBufferPointer { cy in colZ.withUnsafeBufferPointer { cz in
            cp.withUnsafeBufferPointer { cpp in sp.withUnsafeBufferPointer { spp in
                DispatchQueue.concurrentPerform(iterations: bands) { b in
                    let j0 = b * 16, j1 = min(H, j0 + 16)
                    for j in j0..<j1 {
                        let c = cpp[j], s = spp[j]
                        let zAdd = n[8] * s, xAdd = n[2] * s, yAdd = n[5] * s
                        let row = out + j * W * 4
                        for i in 0..<W {
                            let vz = c * cz[i] + zAdd
                            let f = -vz
                            if f < cosLimit {
                                if mode == 0 { row[i * 4] = 0; row[i * 4 + 1] = 0; row[i * 4 + 2] = 0; row[i * 4 + 3] = 0 }
                                continue
                            }
                            let vx = c * cx[i] + xAdd
                            let vy = c * cy[i] + yAdd
                            let px = fw / 2 + vx / f * fpix
                            let py = fh / 2 - vy / f * fpix
                            if px < 0 || px >= fw || py < 0 || py >= fh {
                                if mode == 0 { row[i * 4] = 0; row[i * 4 + 1] = 0; row[i * 4 + 2] = 0; row[i * 4 + 3] = 0 }
                                continue
                            }
                            // Вес: чем ближе к краю кадра, тем меньше
                            let wx = 1 - abs(px / fw * 2 - 1)
                            let wy = 1 - abs(py / fh * 2 - 1)
                            let wt = wx * wy
                            // Билинейная выборка
                            let fx = px - 0.5, fy = py - 0.5
                            var x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
                            let tx = fx - Float(x0), ty = fy - Float(y0)
                            let x1 = min(x0 + 1, iw - 1), y1 = min(y0 + 1, ih - 1)
                            x0 = max(x0, 0); y0 = max(y0, 0)
                            let p00 = base + (y0 * iw + x0) * 4, p10 = base + (y0 * iw + x1) * 4
                            let p01 = base + (y1 * iw + x0) * 4, p11 = base + (y1 * iw + x1) * 4
                            let a = (1 - tx) * (1 - ty), bb = tx * (1 - ty), cc = (1 - tx) * ty, dd = tx * ty
                            var r = (Float(p00[0]) * a + Float(p10[0]) * bb + Float(p01[0]) * cc + Float(p11[0]) * dd) * gain.0
                            var g = (Float(p00[1]) * a + Float(p10[1]) * bb + Float(p01[1]) * cc + Float(p11[1]) * dd) * gain.1
                            var bl = (Float(p00[2]) * a + Float(p10[2]) * bb + Float(p01[2]) * cc + Float(p11[2]) * dd) * gain.2
                            let o = row + i * 4
                            if mode == 0 {
                                o[0] = r; o[1] = g; o[2] = bl; o[3] = wt
                            } else if mode == 1 {
                                o[0] += r * wt; o[1] += g * wt; o[2] += bl * wt; o[3] += wt
                            } else if let lw = low {
                                // Высокая полоса: цвет снимка минус его же размытая версия из малого разрешения
                                let lx = (Float(i) + 0.5) / Float(W) * Float(lowW) - 0.5
                                let ly = (Float(j) + 0.5) / Float(H) * Float(lowH) - 0.5
                                var lx0 = Int(lx.rounded(.down)), ly0 = Int(ly.rounded(.down))
                                let ltx = lx - Float(lx0), lty = ly - Float(ly0)
                                var lx1 = lx0 + 1
                                if lx0 < 0 { lx0 += lowW }
                                if lx1 >= lowW { lx1 -= lowW }
                                if lx0 >= lowW { lx0 -= lowW }
                                if lx1 < 0 { lx1 += lowW }
                                let ly1 = min(max(ly0 + 1, 0), lowH - 1)
                                ly0 = min(max(ly0, 0), lowH - 1)
                                let q00 = lw + (ly0 * lowW + lx0) * 4, q10 = lw + (ly0 * lowW + lx1) * 4
                                let q01 = lw + (ly1 * lowW + lx0) * 4, q11 = lw + (ly1 * lowW + lx1) * 4
                                let a2 = (1 - ltx) * (1 - lty), b2 = ltx * (1 - lty), c2 = (1 - ltx) * lty, d2 = ltx * lty
                                r -= Float(q00[0]) * a2 + Float(q10[0]) * b2 + Float(q01[0]) * c2 + Float(q11[0]) * d2
                                g -= Float(q00[1]) * a2 + Float(q10[1]) * b2 + Float(q01[1]) * c2 + Float(q11[1]) * d2
                                bl -= Float(q00[2]) * a2 + Float(q10[2]) * b2 + Float(q01[2]) * c2 + Float(q11[2]) * d2
                                var wn = wt
                                for _ in 1..<power { wn *= wt }
                                o[0] += r * wn; o[1] += g * wn; o[2] += bl * wn; o[3] += wn
                            }
                        }
                    }
                }
            } } } } }
        }
    }

    /// Малый рендер в массив: цвет и вес
    static func low(img: PanoImg, N: [Double], fovLong: Double, W: Int, H: Int, offX: Double = 0, offY: Double = 0,
                    gain: (Float, Float, Float) = (1, 1, 1)) -> PanoRaster {
        var data = [Float](repeating: 0, count: W * H * 4)
        data.withUnsafeMutableBufferPointer { p in
            run(img: img, N: N, fovLong: fovLong, W: W, H: H, offX: offX, offY: offY, gain: gain, mode: 0, out: p.baseAddress!)
        }
        return PanoRaster(w: W, h: H, data: data)
    }
}

// MARK: - Склейка

final class PanoStitcher {
    struct Result {
        var jpegA: Data?
        var jpegB: Data?
        var previewA: Data?
        var previewB: Data?
        var secondsA = 0.0
        var secondsB = 0.0
        var width = 0
        var log = ""
    }

    let poses: [PanoPose]
    let fovNominal: Double // радианы, по длинной стороне
    var liveConv: Int? // что показали датчики в момент съёмки
    var log = ""
    var progress: (String, Double) -> Void = { _, _ in }

    init(poses: [PanoPose], fovLongDegrees: Double) {
        self.poses = poses
        self.fovNominal = fovLongDegrees * Double.pi / 180
    }

    private func note(_ s: String) { log += s + "\n" }

    // Выбранное понимание позы, масштаб угла обзора, курс первого кадра
    private(set) var conv = 0
    private(set) var scale = 1.0
    private(set) var yaw0 = 0.0
    private var smalls: [PanoImg] = []

    private func N(_ k: Int) -> [Double] {
        PanoMath.mul(PanoMath.world2dev(poses[k].R, conv: conv), PanoMath.rotZ(-yaw0))
    }

    private func yawFor(conv c: Int) -> Double {
        let f = PanoMath.forward(PanoMath.world2dev(poses[0].R, conv: c))
        return atan2(f[0], f[1])
    }

    // MARK: Подбор: какая это поза и какой угол обзора. Правильный ответ даёт минимальную разницу в перекрытиях

    private func overlapCost(conv c: Int, scale s: Double, W: Int) -> (cost: Double, pairs: Int) {
        let H = W / 2
        let y0 = yawFor(conv: c)
        var luma: [[Float]] = [], wts: [[Float]] = []
        for k in 0..<poses.count {
            let M = PanoMath.world2dev(poses[k].R, conv: c)
            let Nk = PanoMath.mul(M, PanoMath.rotZ(-y0))
            let r = PanoRender.low(img: smalls[k], N: Nk, fovLong: fovNominal * s, W: W, H: H)
            var l = [Float](repeating: 0, count: W * H), w = [Float](repeating: 0, count: W * H)
            for i in 0..<(W * H) {
                l[i] = 0.299 * r.data[i * 4] + 0.587 * r.data[i * 4 + 1] + 0.114 * r.data[i * 4 + 2]
                w[i] = r.data[i * 4 + 3]
            }
            luma.append(l); wts.append(w)
        }
        var total = 0.0, cnt = 0
        let fwd = (0..<poses.count).map { PanoMath.forward(PanoMath.world2dev(poses[$0].R, conv: c)) }
        let fovS0 = PanoMath.fovShort(fovNominal * s, aspect: 0.75)
        let reach0 = 2 * atan(hypot(tan(fovNominal * s / 2), tan(fovS0 / 2))) * 0.95
        for i in 0..<poses.count {
            for j in (i + 1)..<max(poses.count, i + 1) {
                if PanoMath.angle(fwd[i], fwd[j]) > reach0 { continue }
                var sum: Float = 0
                var c2 = 0
                luma[i].withUnsafeBufferPointer { a in luma[j].withUnsafeBufferPointer { b in
                wts[i].withUnsafeBufferPointer { wa in wts[j].withUnsafeBufferPointer { wb in
                    for p in 0..<(W * H) where wa[p] > 0.15 && wb[p] > 0.15 {
                        sum += abs(a[p] - b[p])
                        c2 += 1
                    }
                } } } }
                if c2 >= 150 {
                    total += Double(sum)
                    cnt += c2
                }
            }
        }
        return (cnt > 0 ? total / Double(cnt) : 1e9, cnt)
    }

    private func calibrate() {
        progress("Подбираю угол обзора", 0.05)
        var best = (cost: 1e18, conv: 0, scale: 1.0)
        var table: [String] = []
        for c in 0..<2 {
            for s in [0.91, 0.94, 0.97, 1.0, 1.03, 1.06, 1.09] {
                let r = overlapCost(conv: c, scale: s, W: 512)
                table.append(String(format: "поза %d масштаб %.2f: %.2f (пикселей %d)", c, s, r.cost, r.pairs))
                if r.cost < best.cost { best = (r.cost, c, s) }
            }
        }
        // Уточнение масштаба вокруг лучшего
        var fine = best
        for d in [-0.02, -0.01, 0.01, 0.02] {
            let s = best.scale + d
            let r = overlapCost(conv: best.conv, scale: s, W: 512)
            table.append(String(format: "уточнение поза %d масштаб %.2f: %.2f", best.conv, s, r.cost))
            if r.cost < fine.cost { fine = (r.cost, best.conv, s) }
        }
        conv = fine.conv
        scale = fine.scale
        yaw0 = yawFor(conv: conv)
        note("Подбор позы и угла обзора (меньше - лучше):")
        for t in table { note("  " + t) }
        note(String(format: "Выбрано: поза %d, масштаб угла обзора %.3f (номинал %.1f°), курс первого кадра %.1f°",
                    conv, scale, fovNominal * 180 / Double.pi, yaw0 * 180 / Double.pi))
        if let l = liveConv { note("Датчики на съёмке показали позу \(l)\(l == conv ? " - совпало" : " - НЕ совпало")") }
    }

    // MARK: Поправки для B: сдвиги кадров по перекрытиям и выравнивание яркости

    private func refineOffsets(Wr: Int) -> [(Double, Double)] {
        let n = poses.count
        let Hr = Wr / 2
        progress("Подгоняю швы", 0.25)
        var lumas: [[Float]] = [], wts: [[Float]] = []
        for k in 0..<n {
            let r = PanoRender.low(img: smalls[k], N: N(k), fovLong: fovNominal * scale, W: Wr, H: Hr)
            var l = [Float](repeating: 0, count: Wr * Hr), w = [Float](repeating: 0, count: Wr * Hr)
            for i in 0..<(Wr * Hr) {
                l[i] = 0.299 * r.data[i * 4] + 0.587 * r.data[i * 4 + 1] + 0.114 * r.data[i * 4 + 2]
                w[i] = r.data[i * 4 + 3]
            }
            lumas.append(l); wts.append(w)
        }
        // Пары с перекрытием
        var pairIdx: [(Int, Int)] = []
        let fwd = (0..<n).map { PanoMath.forward(PanoMath.world2dev(poses[$0].R, conv: conv)) }
        let fovS = PanoMath.fovShort(fovNominal * scale, aspect: 0.75)
        let reach = 2 * atan(hypot(tan(fovNominal * scale / 2), tan(fovS / 2))) * 0.9
        for i in 0..<n {
            for j in (i + 1)..<max(n, i + 1) where PanoMath.angle(fwd[i], fwd[j]) < reach { pairIdx.append((i, j)) }
        }
        let R = 9
        var results = [(Int, Int, Double, Double, Double)?](repeating: nil, count: pairIdx.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: pairIdx.count) { pi in
            let (i, j) = pairIdx[pi]
            // Точки перекрытия (не больше 8000, равномерно)
            var all: [Int] = []
            for p in 0..<(Wr * Hr) where wts[i][p] > 0.08 && wts[j][p] > 0.08 { all.append(p) }
            if all.count < 700 { return }
            let step = max(1, all.count / 8000)
            var xs: [Int] = [], ys: [Int] = [], la: [Float] = []
            var q = 0
            while q < all.count {
                let p = all[q]
                xs.append(p % Wr); ys.append(p / Wr); la.append(lumas[i][p])
                q += step
            }
            let m = xs.count
            let lj = lumas[j], wj = wts[j]
            var bestV = Double.greatestFiniteMagnitude
            var vals = [Double](repeating: Double.greatestFiniteMagnitude, count: (2 * R + 1) * (2 * R + 1))
            var bi = 0
            lj.withUnsafeBufferPointer { ljp in wj.withUnsafeBufferPointer { wjp in
            for dy in -R...R {
                for dx in -R...R {
                    var sum = 0.0
                    var c = 0
                    for t in 0..<m {
                        let y2 = ys[t] - dy
                        if y2 < 0 || y2 >= Hr { continue }
                        var x2 = xs[t] - dx
                        if x2 < 0 { x2 += Wr }
                        if x2 >= Wr { x2 -= Wr }
                        let qq = y2 * Wr + x2
                        if wjp[qq] <= 0.08 { continue }
                        let d = Double(la[t] - ljp[qq])
                        sum += d * d
                        c += 1
                    }
                    let v = c >= 300 ? sum / Double(c) : Double.greatestFiniteMagnitude
                    let k = (dy + R) * (2 * R + 1) + (dx + R)
                    vals[k] = v
                    if v < bestV { bestV = v; bi = k }
                }
            }
            } }
            if bestV == Double.greatestFiniteMagnitude { return }
            let by = bi / (2 * R + 1) - R, bx = bi % (2 * R + 1) - R
            func par(_ f0: Double, _ f1: Double, _ f2: Double) -> Double {
                if f0 == Double.greatestFiniteMagnitude || f2 == Double.greatestFiniteMagnitude { return 0 }
                let d = f0 - 2 * f1 + f2
                return abs(d) < 1e-9 ? 0 : max(-0.5, min(0.5, 0.5 * (f0 - f2) / d))
            }
            func val(_ dy: Int, _ dx: Int) -> Double {
                if abs(dy) > R || abs(dx) > R { return Double.greatestFiniteMagnitude }
                return vals[(dy + R) * (2 * R + 1) + (dx + R)]
            }
            let sx = Double(bx) + par(val(by, bx - 1), bestV, val(by, bx + 1))
            let sy = Double(by) + par(val(by - 1, bx), bestV, val(by + 1, bx))
            lock.lock()
            results[pi] = (i, j, sx, sy, Double(all.count) / 1000)
            lock.unlock()
        }
        // Решение методом наименьших квадратов: o_j - o_i = s_ij, слабая привязка к нулю
        func solve(_ comp: Int) -> [Double] {
            var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var b = [Double](repeating: 0, count: n)
            for r in results.compactMap({ $0 }) {
                let (i, j, sx, sy, w) = r
                let s = comp == 0 ? sx : sy
                A[i][i] += w; A[j][j] += w; A[i][j] -= w; A[j][i] -= w
                b[j] += w * s; b[i] -= w * s
            }
            for k in 0..<n { A[k][k] += 0.02 }
            return PanoStitcher.gauss(A, b)
        }
        let ox = solve(0), oy = solve(1)
        let used = results.compactMap { $0 }.count
        var maxOff = 0.0
        for k in 0..<n { maxOff = max(maxOff, abs(ox[k]), abs(oy[k])) }
        note(String(format: "Подгонка швов: пар %d из %d, наибольший сдвиг %.1f пикс. на ширине %d (%.2f°)", used, pairIdx.count, maxOff, Wr, maxOff * 360 / Double(Wr)))
        // Сдвиги нужны со знаком "содержимое двигаем на o": равны отрицательным ошибкам
        return (0..<n).map { (ox[$0], oy[$0]) }
    }

    static func gauss(_ A0: [[Double]], _ b0: [Double]) -> [Double] {
        var A = A0, b = b0
        let n = b.count
        for c in 0..<n {
            var p = c
            for r in c..<n where abs(A[r][c]) > abs(A[p][c]) { p = r }
            if abs(A[p][c]) < 1e-12 { continue }
            A.swapAt(c, p); b.swapAt(c, p)
            for r in (c + 1)..<max(n, c + 1) {
                let f = A[r][c] / A[c][c]
                if f == 0 { continue }
                for k in c..<n { A[r][k] -= f * A[c][k] }
                b[r] -= f * b[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for k in (r + 1)..<max(n, r + 1) { s -= A[r][k] * x[k] }
            x[r] = abs(A[r][r]) < 1e-12 ? 0 : s / A[r][r]
        }
        return x
    }

    /// Усиление по каналам для каждого кадра: яркость соседей в перекрытии должна совпадать
    private func gains() -> [(Float, Float, Float)] {
        let n = poses.count
        let W = 512, H = 256
        var rasters: [PanoRaster] = []
        for k in 0..<n { rasters.append(PanoRender.low(img: smalls[k], N: N(k), fovLong: fovNominal * scale, W: W, H: H)) }
        var res = [(Float, Float, Float)](repeating: (1, 1, 1), count: n)
        var logs = [[Double]](repeating: [Double](repeating: 0, count: n), count: 3)
        var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        var bs = [[Double]](repeating: [Double](repeating: 0, count: n), count: 3)
        var cnt = 0
        for i in 0..<n {
            for j in (i + 1)..<max(n, i + 1) {
                var si = [Double](repeating: 0, count: 3), sj = [Double](repeating: 0, count: 3)
                var c = 0
                for p in 0..<(W * H) where rasters[i].data[p * 4 + 3] > 0.2 && rasters[j].data[p * 4 + 3] > 0.2 {
                    for ch in 0..<3 {
                        si[ch] += Double(rasters[i].data[p * 4 + ch])
                        sj[ch] += Double(rasters[j].data[p * 4 + ch])
                    }
                    c += 1
                }
                if c < 300 { continue }
                let w = Double(c) / 1000
                A[i][i] += w; A[j][j] += w; A[i][j] -= w; A[j][i] -= w
                for ch in 0..<3 {
                    let r = log(max(si[ch], 1) / max(sj[ch], 1)) // g_j - g_i = log(mean_i / mean_j)... gj*mj = gi*mi
                    bs[ch][j] += w * r
                    bs[ch][i] -= w * r
                }
                cnt += 1
            }
        }
        for k in 0..<n { A[k][k] += 0.5 }
        for ch in 0..<3 { logs[ch] = PanoStitcher.gauss(A, bs[ch]) }
        var maxG = 0.0
        for k in 0..<n {
            func g(_ v: Double) -> Float { Float(exp(min(0.2, max(-0.2, v)))) }
            res[k] = (g(logs[0][k]), g(logs[1][k]), g(logs[2][k]))
            maxG = max(maxG, abs(logs[0][k]), abs(logs[1][k]), abs(logs[2][k]))
        }
        note(String(format: "Выравнивание яркости: пар %d, наибольшая поправка %.1f%%", cnt, (exp(maxG) - 1) * 100))
        return res
    }

    // MARK: Заполнение дыр (зенит, надир): размытое продолжение краёв

    static func pullPush(rgb: [Float], wt: [Float], w: Int, h: Int) -> [Float] {
        // Пирамида вниз
        var levels: [(rgb: [Float], wt: [Float], w: Int, h: Int)] = [(rgb, wt.map { min(1, $0) }, w, h)]
        while let l = levels.last, l.w > 2, l.h > 2 {
            let cw = l.w / 2, ch = l.h / 2
            var crgb = [Float](repeating: 0, count: cw * ch * 3), cwt = [Float](repeating: 0, count: cw * ch)
            for y in 0..<ch {
                for x in 0..<cw {
                    var sr: Float = 0, sg: Float = 0, sb: Float = 0, sw: Float = 0
                    for dy in 0..<2 {
                        for dx in 0..<2 {
                            let p = (y * 2 + dy) * l.w + (x * 2 + dx)
                            let ww = l.wt[p]
                            sr += l.rgb[p * 3] * ww; sg += l.rgb[p * 3 + 1] * ww; sb += l.rgb[p * 3 + 2] * ww; sw += ww
                        }
                    }
                    let q = y * cw + x
                    if sw > 1e-6 { crgb[q * 3] = sr / sw; crgb[q * 3 + 1] = sg / sw; crgb[q * 3 + 2] = sb / sw }
                    cwt[q] = min(1, sw / 4 * 2)
                }
            }
            levels.append((crgb, cwt, cw, ch))
        }
        // Вверх: где вес мал, подмешиваем верхний уровень
        for li in stride(from: levels.count - 2, through: 0, by: -1) {
            let up = levels[li + 1]
            var cur = levels[li]
            for y in 0..<cur.h {
                for x in 0..<cur.w {
                    let p = y * cur.w + x
                    let a = cur.wt[p]
                    if a >= 1 { continue }
                    let ux = min(up.w - 1, x / 2), uy = min(up.h - 1, y / 2)
                    let q = uy * up.w + ux
                    for ch in 0..<3 { cur.rgb[p * 3 + ch] = cur.rgb[p * 3 + ch] * a + up.rgb[q * 3 + ch] * (1 - a) }
                    cur.wt[p] = 1
                }
            }
            levels[li] = cur
        }
        return levels[0].rgb
    }

    // MARK: Основной проход

    /// Ширина итога; nil - по памяти телефона
    var outputWidth: Int?

    private func outWidth() -> Int {
        if let w = outputWidth { return w }
        return ProcessInfo.processInfo.physicalMemory >= 6_000_000_000 ? 8192 : 6144
    }

    /// Загрузить малые копии и подобрать позу. Вызывается один раз перед A и B
    func prepare() -> Bool {
        smalls = []
        for (k, p) in poses.enumerated() {
            progress("Читаю кадры \(k + 1) из \(poses.count)", 0.02)
            guard let s = PanoIO.load(p.file, maxSide: 400) else { note("Не читается \(p.file.lastPathComponent)"); return false }
            smalls.append(s)
        }
        if let f = smalls.first { note("Кадров \(poses.count), малая копия \(f.w)×\(f.h)") }
        calibrate()
        return true
    }

    private func finalize(acc: UnsafeMutablePointer<Float>, W: Int, H: Int, holes: ((Int, Int) -> (Float, Float, Float))?) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: W * H * 4)
        out.withUnsafeMutableBufferPointer { o in
            DispatchQueue.concurrentPerform(iterations: (H + 15) / 16) { b in
                for j in (b * 16)..<min(H, b * 16 + 16) {
                    for i in 0..<W {
                        let a = acc + (j * W + i) * 4
                        let w = a[3]
                        var r: Float = 0, g: Float = 0, bl: Float = 0
                        if w > 1e-7 {
                            r = a[0] / w; g = a[1] / w; bl = a[2] / w
                        } else if let h = holes {
                            (r, g, bl) = h(i, j)
                        } else {
                            r = 0; g = 0; bl = 0
                        }
                        let p = (j * W + i) * 4
                        o[p] = UInt8(max(0, min(255, r + 0.5)))
                        o[p + 1] = UInt8(max(0, min(255, g + 0.5)))
                        o[p + 2] = UInt8(max(0, min(255, bl + 0.5)))
                        o[p + 3] = 255
                    }
                }
            }
        }
        return out
    }

    /// Вариант A: быстрый набросок. Кадры по датчикам, плавное перекрытие, дыры закрашены средним цветом строки
    func runA() -> (rgba: [UInt8], w: Int, h: Int)? {
        let W = outWidth(), H = W / 2
        let acc = UnsafeMutablePointer<Float>.allocate(capacity: W * H * 4)
        acc.initialize(repeating: 0, count: W * H * 4)
        defer { acc.deallocate() }
        for k in 0..<poses.count {
            progress("Набросок: кадр \(k + 1) из \(poses.count)", 0.1 + 0.8 * Double(k) / Double(poses.count))
            guard let img = PanoIO.load(poses[k].file, maxSide: 4096) else { note("A: не читается кадр \(k)"); continue }
            PanoRender.run(img: img, N: N(k), fovLong: fovNominal * scale, W: W, H: H, offX: 0, offY: 0,
                           gain: (1, 1, 1), mode: 1, out: acc)
        }
        // Средний цвет по строкам
        var rowMean = [(Float, Float, Float)?](repeating: nil, count: H)
        for j in 0..<H {
            var sr: Float = 0, sg: Float = 0, sb: Float = 0, c: Float = 0
            for i in stride(from: 0, to: W, by: 8) {
                let a = acc + (j * W + i) * 4
                if a[3] > 1e-7 { sr += a[0] / a[3]; sg += a[1] / a[3]; sb += a[2] / a[3]; c += 1 }
            }
            if c > 0 { rowMean[j] = (sr / c, sg / c, sb / c) }
        }
        var filled = rowMean
        var last: (Float, Float, Float)?
        for j in 0..<H { if let m = filled[j] { last = m } else { filled[j] = last } }
        last = nil
        for j in stride(from: H - 1, through: 0, by: -1) { if let m = filled[j] { last = m } else { filled[j] = last } }
        let rgba = finalize(acc: acc, W: W, H: H) { _, j in filled[j] ?? (128, 128, 128) }
        return (rgba, W, H)
    }

    /// Вариант B: чистовая. Подгонка швов по картинке, выравнивание яркости, двухполосное смешивание, плавное заполнение зенита и надира
    func runB() -> (rgba: [UInt8], w: Int, h: Int)? {
        let n = poses.count
        let W = outWidth(), H = W / 2
        let offs = refineOffsets(Wr: 1024)
        progress("Выравниваю яркость", 0.4)
        let g = gains()
        // Низкая полоса: кадры малого разрешения в сетке 1024×512 уже со сдвигами и усилением
        let lw = 1024, lh = 512
        var lowRGBA: [[UInt8]] = []
        var lowBlend = [Float](repeating: 0, count: lw * lh * 3)
        var lowWeight = [Float](repeating: 0, count: lw * lh)
        var lowAcc = [Float](repeating: 0, count: lw * lh * 4)
        for k in 0..<n {
            let sc = Double(lw) / Double(W)
            let r = PanoRender.low(img: smalls[k], N: N(k), fovLong: fovNominal * scale, W: lw, H: lh,
                                   offX: offs[k].0 * Double(lw) / 1024, offY: offs[k].1 * Double(lh) / 512, gain: g[k])
            _ = sc
            var q = [UInt8](repeating: 0, count: lw * lh * 4)
            for p in 0..<(lw * lh) {
                let w = r.data[p * 4 + 3]
                lowAcc[p * 4] += r.data[p * 4] * w
                lowAcc[p * 4 + 1] += r.data[p * 4 + 1] * w
                lowAcc[p * 4 + 2] += r.data[p * 4 + 2] * w
                lowAcc[p * 4 + 3] += w
                q[p * 4] = UInt8(max(0, min(255, r.data[p * 4] + 0.5)))
                q[p * 4 + 1] = UInt8(max(0, min(255, r.data[p * 4 + 1] + 0.5)))
                q[p * 4 + 2] = UInt8(max(0, min(255, r.data[p * 4 + 2] + 0.5)))
                q[p * 4 + 3] = 255
            }
            lowRGBA.append(q)
        }
        for p in 0..<(lw * lh) {
            let w = lowAcc[p * 4 + 3]
            lowWeight[p] = w
            if w > 1e-7 {
                lowBlend[p * 3] = lowAcc[p * 4] / w
                lowBlend[p * 3 + 1] = lowAcc[p * 4 + 1] / w
                lowBlend[p * 3 + 2] = lowAcc[p * 4 + 2] / w
            }
        }
        lowAcc = []
        // Закрытие дыр на низкой полосе
        let covered = lowWeight.map { $0 > 1e-3 ? Float(1) : Float(0) }
        let filledLow = PanoStitcher.pullPush(rgb: lowBlend, wt: covered, w: lw, h: lh)

        let acc = UnsafeMutablePointer<Float>.allocate(capacity: W * H * 4)
        acc.initialize(repeating: 0, count: W * H * 4)
        defer { acc.deallocate() }
        for k in 0..<n {
            progress("Чистовая: кадр \(k + 1) из \(n)", 0.45 + 0.45 * Double(k) / Double(n))
            guard let img = PanoIO.load(poses[k].file, maxSide: 4096) else { note("B: не читается кадр \(k)"); continue }
            lowRGBA[k].withUnsafeBufferPointer { lp in
                PanoRender.run(img: img, N: N(k), fovLong: fovNominal * scale, W: W, H: H,
                               offX: offs[k].0 * Double(W) / 1024, offY: offs[k].1 * Double(H) / 512, gain: g[k],
                               mode: 2, out: acc, low: lp.baseAddress!, lowW: lw, lowH: lh, power: 4)
            }
        }
        progress("Собираю итог", 0.92)
        // Итог: размытая основа плюс детали из кадров
        var out = [UInt8](repeating: 255, count: W * H * 4)
        lowBlend.withUnsafeBufferPointer { lb in filledLow.withUnsafeBufferPointer { fl in lowWeight.withUnsafeBufferPointer { lwp in
        out.withUnsafeMutableBufferPointer { o in
            func bil(_ buf: UnsafeBufferPointer<Float>, _ ch: Int, _ x: Float, _ y: Float, stride s: Int) -> Float {
                var x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
                let tx = x - Float(x0), ty = y - Float(y0)
                var x1 = x0 + 1
                if x0 < 0 { x0 += lw }
                if x1 >= lw { x1 -= lw }
                if x0 >= lw { x0 -= lw }
                if x1 < 0 { x1 += lw }
                let y1 = min(max(y0 + 1, 0), lh - 1)
                y0 = min(max(y0, 0), lh - 1)
                let a = buf[(y0 * lw + x0) * s + ch], b = buf[(y0 * lw + x1) * s + ch]
                let c = buf[(y1 * lw + x0) * s + ch], d = buf[(y1 * lw + x1) * s + ch]
                return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
            }
            DispatchQueue.concurrentPerform(iterations: (H + 15) / 16) { band in
                for j in (band * 16)..<min(H, band * 16 + 16) {
                    let ly = (Float(j) + 0.5) / Float(H) * Float(lh) - 0.5
                    for i in 0..<W {
                        let lx = (Float(i) + 0.5) / Float(W) * Float(lw) - 0.5
                        let a = acc + (j * W + i) * 4
                        let cov = min(1, bil(lwp, 0, lx, ly, stride: 1) * 20)
                        var rgb: (Float, Float, Float)
                        let base = (bil(lb, 0, lx, ly, stride: 3), bil(lb, 1, lx, ly, stride: 3), bil(lb, 2, lx, ly, stride: 3))
                        let fill = (bil(fl, 0, lx, ly, stride: 3), bil(fl, 1, lx, ly, stride: 3), bil(fl, 2, lx, ly, stride: 3))
                        if a[3] > 1e-9 {
                            rgb = (base.0 + a[0] / a[3], base.1 + a[1] / a[3], base.2 + a[2] / a[3])
                        } else {
                            rgb = base
                        }
                        rgb = (rgb.0 * cov + fill.0 * (1 - cov), rgb.1 * cov + fill.1 * (1 - cov), rgb.2 * cov + fill.2 * (1 - cov))
                        let p = (j * W + i) * 4
                        o[p] = UInt8(max(0, min(255, rgb.0 + 0.5)))
                        o[p + 1] = UInt8(max(0, min(255, rgb.1 + 0.5)))
                        o[p + 2] = UInt8(max(0, min(255, rgb.2 + 0.5)))
                        o[p + 3] = 255
                    }
                }
            }
        } } } }
        return (out, W, H)
    }

    /// Всё вместе: подбор, A, B, JPEG с метаданными 360 и превью
    func runAll() -> Result {
        var res = Result()
        let t0 = Date()
        guard prepare() else { res.log = log; return res }
        note(String(format: "Подготовка и подбор: %.1f с", Date().timeIntervalSince(t0)))
        let tA = Date()
        if let a = runA() {
            res.width = a.w
            res.jpegA = PanoIO.panoJPEG(rgba: a.rgba, w: a.w, h: a.h)
            res.previewA = preview(a.rgba, a.w, a.h)
        }
        res.secondsA = Date().timeIntervalSince(tA)
        note(String(format: "Вариант A (набросок): %.1f с, файл %.1f МБ", res.secondsA, Double(res.jpegA?.count ?? 0) / 1e6))
        let tB = Date()
        if let b = runB() {
            res.width = b.w
            res.jpegB = PanoIO.panoJPEG(rgba: b.rgba, w: b.w, h: b.h)
            res.previewB = preview(b.rgba, b.w, b.h)
        }
        res.secondsB = Date().timeIntervalSince(tB)
        note(String(format: "Вариант B (чистовая): %.1f с, файл %.1f МБ", res.secondsB, Double(res.jpegB?.count ?? 0) / 1e6))
        res.log = log
        return res
    }

    private func preview(_ rgba: [UInt8], _ w: Int, _ h: Int) -> Data? {
        guard let cg = PanoIO.cgImage(rgba: rgba, w: w, h: h) else { return nil }
        let pw = 2048, ph = 1024
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        guard let small = ctx.makeImage() else { return nil }
        return PanoIO.jpeg(small, quality: 0.8)
    }
}
