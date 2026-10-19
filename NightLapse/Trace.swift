import SwiftUI
import UIKit
import MetricKit
import ObjectiveC

// MARK: - Самозапись и самопроверка
// Каждое касание: на что нажато, на каком экране, как быстро ответил интерфейс.
// Плюс вылеты, подвисания, нагрев. Всё пишется в тот же журнал app.log, по порядку с остальными событиями.
// Самопроверка собирает из журнала короткую сводку проблем - видна в Настройках и лежит в отчёте (audit.txt).
// Ничего никуда не отправляется.

enum Trace {
    private static var started = false
    private static var screens: [String] = []
    static var screen: String { screens.last ?? "Камера" }
    private static var downs: [ObjectIdentifier: (CGPoint, TimeInterval, String)] = [:]
    private static var recent: [(CGPoint, TimeInterval)] = []
    private static var lastTap = ("", 0.0)
    private static var active = true
    private static var dog: DispatchSourceTimer?
    private static let sub = SystemReports()

    static func start() {
        guard !started else { return }
        started = true
        let d = UserDefaults.standard
        // Новая сборка: файл приложения поменялся - это не вылет, а установка
        let exe = Bundle.main.executableURL
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }?
            .timeIntervalSince1970 ?? 0
        let updated = abs(d.double(forKey: "trace.exe") - exe) > 1
        d.set(exe, forKey: "trace.exe")
        // Приложение было на экране и не ушло в фон - значит прошлый запуск оборвался
        if updated {
            Diag.event("Установлена новая сборка")
        } else if d.string(forKey: "trace.phase") == "active" {
            Diag.event("Вылет: прошлый запуск оборвался на экране «\(d.string(forKey: "trace.screen") ?? "?")», "
                + "последнее нажатие \(d.string(forKey: "trace.tap") ?? "-")")
        }
        d.set("active", forKey: "trace.phase")
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            d.set("background", forKey: "trace.phase")
            Diag.event("Ушло в фон [\(screen)]")
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            d.set("active", forKey: "trace.phase")
            Diag.event("Снова на экране [\(screen)]")
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in active = false }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in active = true }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            Diag.event("Нагрев: \(Diag.thermal())")
        }
        if let a = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
           let b = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.nl_sendEvent(_:))) {
            method_exchangeImplementations(a, b)
        }
        watchdog()
        MXMetricManager.shared.add(sub)
    }

    /// Что поменялось после нажатия: вкладка, инструмент, параметр, зум...
    static func state(_ s: String) {
        Diag.event("→ " + s)
    }

    // MARK: Экраны

    static func enter(_ n: String) {
        screens.removeAll { $0 == n }
        screens.append(n)
        Diag.event("Экран: \(n)")
    }

    static func leave(_ n: String) {
        screens.removeAll { $0 == n }
    }

    // MARK: Касания

    static func touch(_ e: UIEvent, _ w: UIWindow) {
        guard e.type == .touches, let ts = e.allTouches else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for t in ts {
            let id = ObjectIdentifier(t)
            let p = t.location(in: w)
            switch t.phase {
            case .began:
                // Название берём в момент касания - пока экран ещё не поменялся
                downs[id] = (p, now, label(at: p, in: w))
            case .ended:
                guard let s = downs.removeValue(forKey: id) else { continue }
                let dx = p.x - s.0.x, dy = p.y - s.0.y
                let dist = (dx * dx + dy * dy).squareRoot()
                let what = s.2.isEmpty ? spot(s.0, w) : "«\(s.2)»"
                if dist < 15 {
                    tap(what, at: p, now: now, long: now - s.1 > 0.5)
                } else if dist > 60 {
                    let dir = abs(dx) > abs(dy) ? (dx > 0 ? "вправо" : "влево") : (dy > 0 ? "вниз" : "вверх")
                    Diag.event("Свайп \(dir) от \(what) [\(screen)]")
                }
            case .cancelled:
                downs.removeValue(forKey: id)
            default:
                break
            }
        }
    }

    private static func tap(_ what: String, at p: CGPoint, now: TimeInterval, long: Bool) {
        lastTap = (what, now)
        UserDefaults.standard.set(what, forKey: "trace.tap")
        UserDefaults.standard.set(screen, forKey: "trace.screen")
        Diag.event("\(long ? "Долгое нажатие" : "Нажатие") \(what) [\(screen)]")
        // Отклик: сколько интерфейс был занят этим нажатием
        DispatchQueue.main.async {
            let lag = ProcessInfo.processInfo.systemUptime - now
            if lag > 0.3 { Diag.event("Медленный ответ на \(what): \(String(format: "%.1f", lag)) с") }
        }
        recent = recent.filter { now - $0.1 < 1.5 } + [(p, now)]
        if recent.filter({ hypot($0.0.x - p.x, $0.0.y - p.y) < 40 }).count >= 3 {
            Diag.event("Частые нажатия в одно место: похоже, \(what) не откликается")
            recent = []
        }
    }

    /// Место касания, если у элемента нет названия
    private static func spot(_ p: CGPoint, _ w: UIWindow) -> String {
        let b = w.bounds
        guard b.width > 0, b.height > 0 else { return "точка" }
        return "точка \(Int(p.x / b.width * 100))%×\(Int(p.y / b.height * 100))%"
    }

    /// Название кнопки под пальцем - из подписей для VoiceOver, самый маленький элемент, в который попал палец
    private static func label(at p: CGPoint, in w: UIWindow) -> String {
        guard var v = w.hitTest(p, with: nil) else { return "" }
        let sp = w.convert(p, to: w.screen.coordinateSpace)
        var best = ""
        var bestArea = CGFloat.greatestFiniteMagnitude
        var seen = 0
        func visit(_ o: NSObject, _ depth: Int) {
            seen += 1
            if depth > 30 || seen > 2000 { return }
            let f = o.accessibilityFrame
            if o.isAccessibilityElement, f.contains(sp), let l = o.accessibilityLabel, !l.isEmpty {
                let a = f.width * f.height
                if a < bestArea {
                    var s = l
                    if let val = o.accessibilityValue, !val.isEmpty, val.count < 20 { s += ": " + val }
                    best = String(s.prefix(48))
                    bestArea = a
                }
            }
            if let els = o.accessibilityElements {
                for case let c as NSObject in els { visit(c, depth + 1) }
            } else {
                let n = o.accessibilityElementCount()
                if n > 0 && n != NSNotFound {
                    for i in 0..<min(n, 300) {
                        if let c = o.accessibilityElement(at: i) as? NSObject { visit(c, depth + 1) }
                    }
                }
                if let view = o as? UIView {
                    for s in view.subviews where !s.isHidden && s.alpha > 0.01 {
                        if s.convert(s.bounds, to: w.screen.coordinateSpace).contains(sp) { visit(s, depth + 1) }
                    }
                }
            }
        }
        // От вида под пальцем вверх, пока не найдём подпись
        for _ in 0..<8 {
            visit(v, 0)
            if !best.isEmpty { break }
            guard let sv = v.superview else { break }
            v = sv
        }
        return best.replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: Подвисания

    private static func watchdog() {
        let q = DispatchQueue(label: "nightlapse.watchdog", qos: .utility)
        var waiting = false
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 3, repeating: 0.5)
        t.setEventHandler {
            if waiting { return }
            waiting = true
            let t0 = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                let now = ProcessInfo.processInfo.systemUptime
                let lag = now - t0
                // Недавнее нажатие уже отмечено как медленный ответ
                if lag > 0.6 && lag < 60 && active && now - lastTap.1 > lag + 1.5 {
                    Diag.event("Подвисание интерфейса \(String(format: "%.1f", lag)) с [\(screen)]")
                }
                q.async { waiting = false }
            }
        }
        t.resume()
        dog = t
    }

    // MARK: Самопроверка

    /// Сводка за последние сутки: short - одна строка для Настроек, full - подробно для отчёта
    static func audit() -> (short: String, full: String) {
        let url = Diag.dir.appendingPathComponent("app.log")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return ("Журнал пока пуст", "Журнал пока пуст") }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let since = Date().addingTimeInterval(-24 * 3600)
        let lines = s.split(separator: "\n").map(String.init).filter { l in
            guard l.count > 19, let d = f.date(from: String(l.prefix(19))) else { return false }
            return d > since
        }
        func has(_ l: String, _ keys: [String]) -> Bool { keys.contains { l.contains($0) } }

        var crashes: [String] = []
        for (i, l) in lines.enumerated() where has(l, ["Вылет:", "отчёт о вылете"]) {
            crashes.append(l)
            crashes += lines[max(0, i - 6)..<i].map { "      перед этим: " + $0 }
        }
        let hangs = lines.filter { has($0, ["Подвисание", "Медленный ответ", "о зависании"]) }
        let errors = lines.filter { has($0, ["Ошибка", "ошибка", "не собрался", "не запустилась"]) }
        let rage = lines.filter { $0.contains("Частые нажатия") }
        let heat = lines.filter { has($0, ["serious", "critical"]) }
        let slow = lines.filter { l in
            guard l.contains("Редактор:"), let r = l.range(of: #", (\d+) с:"#, options: .regularExpression) else { return false }
            let n = Int(l[r].filter(\.isNumber)) ?? 0
            return n >= 60
        }
        let launches = lines.filter { $0.contains("Найтлапс открыт") }.count
        let taps = lines.filter { $0.contains("Нажатие ") }
        let unnamed = taps.filter { $0.contains("Нажатие точка") }.count

        let crashCount = lines.filter { has($0, ["Вылет:", "отчёт о вылете"]) }.count
        var parts: [String] = []
        if crashCount > 0 { parts.append("вылетов \(crashCount)") }
        if !hangs.isEmpty { parts.append("подвисаний \(hangs.count)") }
        if !errors.isEmpty { parts.append("ошибок \(errors.count)") }
        if !rage.isEmpty { parts.append("неотзывчивых кнопок \(rage.count)") }
        if !slow.isEmpty { parts.append("долгих экспортов \(slow.count)") }
        if !heat.isEmpty { parts.append("перегревов \(heat.count)") }
        let short = parts.isEmpty ? "За сутки проблем не найдено" : "За сутки: " + parts.joined(separator: ", ")

        var out = ["Самопроверка за последние сутки", short,
                   "Запусков \(launches), нажатий \(taps.count), из них без названия \(unnamed)", ""]
        func section(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            out.append(title)
            out += items.suffix(40).map { "  " + $0 }
            out.append("")
        }
        section("Вылеты (и что было перед ними):", crashes)
        section("Подвисания и медленные ответы:", hangs)
        section("Ошибки:", errors)
        section("Кнопки, которые не откликались:", rage)
        section("Экспорт дольше минуты:", slow)
        section("Перегрев:", heat)
        return (short, out.joined(separator: "\n"))
    }
}

extension UIWindow {
    @objc func nl_sendEvent(_ e: UIEvent) {
        Trace.touch(e, self)
        nl_sendEvent(e)   // после подмены здесь вызывается системный sendEvent
    }
}

extension View {
    /// Отмечает экран в журнале: нажатия пишутся с его названием
    func traceScreen(_ name: String) -> some View {
        onAppear { Trace.enter(name) }
            .onDisappear { Trace.leave(name) }
    }
}

/// Отчёты iOS о вылетах и зависаниях (приходят при следующем запуске) - кладём в папку журнала
final class SystemReports: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        for p in payloads {
            let crashes = p.crashDiagnostics ?? []
            let hangs = p.hangDiagnostics ?? []
            guard !crashes.isEmpty || !hangs.isEmpty else { continue }
            let u = Diag.dir.appendingPathComponent("system_\(f.string(from: p.timeStampEnd)).json")
            try? p.jsonRepresentation().write(to: u)
            for c in crashes {
                Diag.event("iOS прислал отчёт о вылете: сигнал \(c.signal?.intValue ?? 0), \(c.terminationReason ?? "")")
            }
            for h in hangs {
                Diag.event("iOS прислал отчёт о зависании на \(String(format: "%.1f", h.hangDuration.converted(to: .seconds).value)) с")
            }
        }
    }
}

/// Камера: что меняется от нажатий - открытый параметр, зум, режим, значения
struct CameraTrace: ViewModifier {
    @ObservedObject var e: LapseEngine
    let open: String

    func body(content: Content) -> some View {
        content
            .onChange(of: open) { Trace.state("Открыто: \(open)") }
            .onChange(of: e.zoom) { Trace.state("Зум: \(e.zoom)") }
            .onChange(of: e.scene) { Trace.state("Режим: \(e.scene)") }
            .onChange(of: e.intervalSeconds) { Trace.state("Интервал: \(e.intervalSeconds) с") }
            .onChange(of: e.evComp) { Trace.state("Яркость: \(String(format: "%.1f", e.evComp))") }
            .onChange(of: e.autoStopMin) { Trace.state("Длительность: \(e.autoStopMin) мин") }
            .onChange(of: e.focusAuto) { Trace.state("Фокус: \(e.focusAuto ? "авто" : "вручную")") }
            .onChange(of: e.phase) { Trace.state("Состояние: \(e.phase)") }
    }
}

/// Редактор: вкладка, инструмент, вид, длина следа
struct EditorTrace: ViewModifier {
    let tab: String, tool: String, look: String, trail: String

    func body(content: Content) -> some View {
        content
            .onChange(of: tab) { Trace.state("Вкладка: \(tab)") }
            .onChange(of: tool) { Trace.state("Инструмент: \(tool)") }
            .onChange(of: look) { Trace.state("Вид: \(look)") }
            .onChange(of: trail) { Trace.state("След: \(trail)") }
    }
}
