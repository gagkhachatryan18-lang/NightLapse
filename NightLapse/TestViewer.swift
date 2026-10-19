import SwiftUI
import Photos

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

    static func save(_ img: CGImage) {
        guard let data = ShootStore.jpeg(img) else { return }
        let url = dir.appendingPathComponent("test_\(fmt.string(from: Date())).jpg")
        try? data.write(to: url)
        // Храним только последние 30
        let all = list()
        if all.count > 30 { for u in all.dropFirst(30) { try? FileManager.default.removeItem(at: u) } }
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

    init(pal: Pal = Pal(night: false)) { self.pal = pal }

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
                        Text("\(idx + 1) из \(urls.count)").monospacedDigit().foregroundStyle(pal.dim)
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
                    if !message.isEmpty { Text(message).foregroundStyle(pal.dim) }
                    Text("Два пальца или двойное касание - увеличить. Листай - прошлые тесты")
                        .foregroundStyle(pal.dim)
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
        }
        .onChange(of: idx) { message = "" }
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
        var sum = 0
        for i in 0..<(32 * 18) { sum += (Int(d[i * 4]) * 77 + Int(d[i * 4 + 1]) * 150 + Int(d[i * 4 + 2]) * 29) >> 8 }
        let m = sum / (32 * 18)
        if m < 10 { return ("Темно: почти ничего не видно. Подними яркость", false) }
        if m > 150 { return ("Светло: может пересветить. Убавь яркость", false) }
        return ("Яркость нормальная, можно снимать", true)
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
