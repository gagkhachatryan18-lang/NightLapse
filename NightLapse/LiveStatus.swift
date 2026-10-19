// Обновление плашки Live Activity из приложения: старт, кадры, пауза, конец съёмки
import Foundation
import ActivityKit

final class LiveStatus {
    static let shared = LiveStatus()
    private var activity: Activity<LapseActivityAttributes>?
    private var st = LapseActivityAttributes.ContentState(frames: 0, started: Date(), battery: -1, hot: false, state: "rec", note: "")

    /// main
    func start(mode: String, battery: Int) {
        end(note: "")
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Diag.event("Плашка на экране блокировки выключена в настройках iPhone")
            return
        }
        st = .init(frames: 0, started: Date(), battery: battery, hot: false, state: "rec", note: "")
        do {
            activity = try Activity.request(attributes: LapseActivityAttributes(mode: mode),
                                            content: .init(state: st, staleDate: nil))
        } catch {
            Diag.event("Плашка не запустилась: \(error.localizedDescription)")
        }
    }

    /// main. Обновляем не чаще, чем нужно: при новом кадре, паузе, смене батареи или нагрева
    func update(frames: Int? = nil, battery: Int? = nil, hot: Bool? = nil, state: String? = nil, note: String? = nil) {
        guard let a = activity else { return }
        var s = st
        if let v = frames { s.frames = v }
        if let v = battery { s.battery = v }
        if let v = hot { s.hot = v }
        if let v = state { s.state = v }
        if let v = note { s.note = v }
        guard s != st else { return }
        st = s
        // Если кадров нет дольше 2 минут, плашка сама покажет, что данные устарели
        let content = ActivityContent(state: s, staleDate: Date().addingTimeInterval(120))
        Task { await a.update(content) }
    }

    /// main
    func end(note: String) {
        guard let a = activity else { return }
        activity = nil
        var s = st
        s.state = "done"
        s.note = note
        let content = ActivityContent(state: s, staleDate: nil)
        Task { await a.end(content, dismissalPolicy: .after(Date().addingTimeInterval(3600))) }
    }
}
