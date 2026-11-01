import SwiftUI
import Photos
import ImageIO

/// Пробные кадры: сохраняются в Файлы → NightLapse → Тесты (последние 30), чтобы до старта
/// можно было сравнить, увеличить и при желании экспортировать
enum TestStore {
    static var dir: URL {
        let d = ShootStore.docs().appendingPathComponent("Тесты", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    static func save(_ img: CGImage, label: String = "", meta: [String: Any] = [:]) {
        // Оценка кадра (фокус, звёзды, небо) - вместе с настройками
        var meta = meta
        for (k, v) in FrameQuality.of(img).dict { meta[k] = v }
        let json = (try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard let data = jpeg(img, comment: json) else { return }
        let tail = label.isEmpty ? "" : "_" + label.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent("test_\(fmt.string(from: Date()))\(tail).jpg")
        try? data.write(to: url)
        // Все настройки снимка - и в самом файле (EXIF, комментарий), и строкой в журнале тестов
        if !json.isEmpty { log(url.lastPathComponent + " " + json) }
        // Храним только последние 150 (полный тест даёт около 30 за раз)
        let all = list()
        if all.count > 150 { for u in all.dropFirst(150) { try? FileManager.default.removeItem(at: u) } }
    }

    static func log(_ line: String) {
        let u = dir.appendingPathComponent("tests_log.txt")
        let l = line + "\n"
        if let h = try? FileHandle(forWritingTo: u) {
            h.seekToEndOfFile()
            h.write(Data(l.utf8))
            try? h.close()
        } else {
            try? l.write(to: u, atomically: true, encoding: .utf8)
        }
    }

    /// JPEG с текстом настроек в EXIF (UserComment) - его видно в любом просмотрщике метаданных
    static func jpeg(_ img: CGImage, comment: String) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if !comment.isEmpty {
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: comment]
            props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFImageDescription: comment, kCGImagePropertyTIFFSoftware: "NightLapse"]
        }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Подпись способа из имени файла (для сравнения), у обычного теста - пусто
    static func label(_ u: URL) -> String {
        let parts = u.deletingPathExtension().lastPathComponent.split(separator: "_", maxSplits: 3)
        return parts.count > 3 ? String(parts[3]) : ""
    }

    /// Новые первыми
    static func list() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

/// Просмотр пробных кадров: листать, увеличивать двумя пальцами или двойным касанием, экспорт в Фото
struct TestViewer: View {
    var pal = Pal(night: false)
    @Environment(\.dismiss) private var dismiss
    @State private var urls: [URL] = []
    @State private var idx = 0
    @State private var message = ""
    @State private var quality: [Int: FrameQuality] = [:]

    init(pal: Pal = Pal(night: false)) { self.pal = pal }

    private func loadQuality(_ i: Int) {
        guard i < urls.count, quality[i] == nil else { return }
        let u = urls[i]
        DispatchQueue.global(qos: .userInitiated).async {
            let q = FrameQuality.of(url: u) ?? FrameQuality()
            DispatchQueue.main.async { quality[i] = q }
        }
    }

    /// Твоя оценка кадра - в журнал тестов: по ней Claude сверяет свою оценку с твоим глазом
    private func rate(_ good: Bool) {
        guard idx < urls.count else { return }
        let q = quality[idx].map { String(format: " (звёзд %d, размер %.2f, вытянутость %.2f, небо %.0f)", $0.stars, $0.fwhm, $0.elong, $0.sky) } ?? ""
        TestStore.log("ОЦЕНКА " + urls[idx].lastPathComponent + ": " + (good ? "хороший" : "плохой") + q)
        Diag.event("Оценка теста: " + (good ? "хороший" : "плохой") + q)
        message = good ? "Отмечен как хороший" : "Отмечен как плохой"
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if urls.isEmpty {
                Text("Пока нет пробных кадров").foregroundStyle(pal.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TabView(selection: $idx) {
                    ForEach(urls.indices, id: \.self) { i in
                        ZoomImage(url: urls[i]).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }
            VStack(spacing: 0) {
                HStack {
                    Button("Закрыть") { dismiss() }
                    Spacer()
                    if !urls.isEmpty {
                        VStack(spacing: 2) {
                            Text("\(idx + 1) из \(urls.count)").monospacedDigit().foregroundStyle(pal.dim)
                            if idx < urls.count, !TestStore.label(urls[idx]).isEmpty {
                                Text(TestStore.label(urls[idx])).font(.footnote).foregroundStyle(pal.text)
                            }
                        }
                        Spacer()
                        Button("Экспорт") { exportCurrent() }
                    }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(pal.text)
                .padding(16)
                .background(Color.black.opacity(0.55))
                Spacer()
                VStack(spacing: 8) {
                    if let v = verdict {
                        Label(v.0, systemImage: v.1 ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(v.1 ? pal.text : pal.warn)
                    }
                    if let q = quality[idx] {
                        ForEach(Array(q.verdict.enumerated()), id: \.offset) { _, v in
                            Label(v.0, systemImage: v.1 ? "checkmark.circle" : "exclamationmark.triangle")
                                .foregroundStyle(v.1 ? pal.text : pal.warn)
                        }
                    } else if !urls.isEmpty {
                        Text("Оцениваю фокус...").foregroundStyle(pal.dim)
                    }
                    if !urls.isEmpty {
                        HStack(spacing: 24) {
                            Button { rate(true) } label: { Label("Хороший", systemImage: "hand.thumbsup") }
                            Button { rate(false) } label: { Label("Плохой", systemImage: "hand.thumbsdown") }
                        }
                        .foregroundStyle(pal.text)
                        .padding(.top, 4)
                    }
                    if !message.isEmpty { Text(message).foregroundStyle(pal.dim) }
                }
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(12)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                .padding(.bottom, 24)
                .padding(.horizontal, 16)
            }
        }
        .presentationDragIndicator(.visible)
        .onAppear {
            urls = TestStore.list()
            idx = 0
            loadQuality(0)
        }
        .onChange(of: idx) {
            message = ""
            loadQuality(idx)
        }
        .traceScreen("Тесты")
    }

    /// Оценка яркости кадра простыми словами
    private var verdict: (String, Bool)? {
        guard idx < urls.count, let cg = ShootStore.thumb(urls[idx], maxPixel: 64),
              let ctx = CGContext(data: nil, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 128,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 32, height: 18))
        guard let d = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var sum = 0, clip = 0
        for i in 0..<(32 * 18) {
            sum += (Int(d[i * 4]) * 77 + Int(d[i * 4 + 1]) * 150 + Int(d[i * 4 + 2]) * 29) >> 8
            if max(d[i * 4], d[i * 4 + 1], d[i * 4 + 2]) >= 245 { clip += 1 }
        }
        let m = sum / (32 * 18)
        if m < 10 { return ("Кадр может быть тёмным", false) }
        // Даже если в среднем темно: белое пятно больше 3% кадра - это пересвет (луна, облака под луной)
        if m > 150 || clip * 100 > 32 * 18 * 3 { return ("Кадр может быть пересвечен", false) }
        return ("Яркость в норме", true)
    }

    private func exportCurrent() {
        guard idx < urls.count, let data = try? Data(contentsOf: urls[idx]) else { return }
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }) { ok, _ in
            DispatchQueue.main.async { message = ok ? "Сохранено в галерее телефона" : "Нет доступа к галерее телефона" }
        }
    }
}

/// Картинка с увеличением: щипок двумя пальцами, перетаскивание, двойное касание - 1× / 3×
struct ZoomImage: View {
    let url: URL
    @State private var img: UIImage?
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var start: CGSize = .zero

    var body: some View {
        GeometryReader { g in
            Group {
                if let img {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: g.size.width, height: g.size.height)
                } else {
                    ProgressView().frame(width: g.size.width, height: g.size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(MagnifyGesture()
                .onChanged { v in scale = min(max(base * v.magnification, 1), 8) }
                .onEnded { _ in
                    base = scale
                    if scale <= 1.01 { reset() }
                })
            .simultaneousGesture(scale > 1.01 ? DragGesture()
                .onChanged { v in offset = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height) }
                .onEnded { _ in start = offset } : nil)
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if scale > 1.01 { reset() } else { scale = 3; base = 3 }
                }
            }
        }
        .task(id: url) {
            let u = url
            img = await Task.detached {
                ShootStore.thumb(u, maxPixel: 3000).map { UIImage(cgImage: $0) }
            }.value
        }
    }

    private func reset() {
        scale = 1
        base = 1
        offset = .zero
        start = .zero
    }
}
