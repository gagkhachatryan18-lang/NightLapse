// Плашка «идёт съёмка» на экране блокировки, в Dynamic Island и на Apple Watch (Live Activity).
// Этот файл общий для приложения и расширения с плашкой
import Foundation
import ActivityKit

struct LapseActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Снято кадров
        var frames: Int
        /// Когда началась съёмка - время на плашке идёт само, без обновлений
        var started: Date
        /// Заряд, %; -1 если неизвестно
        var battery: Int
        /// Телефон перегрет
        var hot: Bool
        /// rec - идёт, paused - пауза, done - закончена
        var state: String
        /// Короткая подпись: причина паузы или итог
        var note: String
    }

    /// Режим: Найтлапс или Таймлапс
    var mode: String
}
