import Foundation

enum L10n {
    static let isRussian = Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") == true

    static var waiting: String { text("Ожидание токенов", "Waiting for tokens") }
    static var displayFields: String { text("Показатели в строке меню", "Menu bar fields") }
    static var lockTask: String { text("Закрепить текущий чат", "Lock current task") }
    static var lockedTask: String { text("Текущий чат закреплён", "Current task locked") }
    static var launchAtLogin: String { text("Запускать при входе в систему", "Launch at login") }
    static var openSessions: String { text("Открыть папку журналов сессий", "Open session log folder") }
    static var openProject: String { text("Открыть страницу проекта", "Open project page") }
    static var quit: String { text("Выйти", "Quit") }
    static var noTokenSnapshot: String { text("Для текущего чата пока нет данных о токенах", "No token data for the current task") }
    static var ipcConnected: String { text("Подключено к Codex", "Task tracking: connected to Codex") }
    static var ipcFallback: String { text("Последняя сессия из журнала", "Task tracking: recent-session fallback") }
    static var currentTask: String { text("Текущий чат", "Current task") }
    static var launchAtLoginFailed: String { text("Не удалось изменить настройку запуска при входе", "Unable to change launch-at-login setting") }
    static var confirmSource: String {
        text("Убедитесь, что приложение запущено из стандартного пакета .app. Если проблема не исчезнет, управляйте этим параметром в «Системные настройки → Основные → Объекты входа».",
             "Make sure the app is running from a standard .app bundle. You can also manage it in System Settings under General → Login Items.")
    }

    static func fieldName(_ field: DisplayField) -> String {
        switch field {
        case .total: return text("Всего токенов", "Total")
        case .input: return text("Входные токены", "Input")
        case .output: return text("Выходные токены", "Output")
        case .cacheHit: return text("Токены из кэша", "Cache hit")
        case .cacheMiss: return text("Токены вне кэша", "Cache miss")
        case .context: return text("Контекст", "Context")
        case .contextPercent: return text("Использовано контекста (%)", "Context percent")
        case .reasoning: return text("Токены рассуждения", "Reasoning")
        case .thread: return text("ID чата", "Task ID")
        default: return text("Неизвестно", "Unknown")
        }
    }

    static func fieldValue(_ field: DisplayField, _ value: String) -> String {
        let prefix: String
        switch field {
        case .total: prefix = text("Всего", "Total")
        case .input: prefix = text("Вход", "In")
        case .output: prefix = text("Выход", "Out")
        case .cacheHit: prefix = text("Кэш", "Hit")
        case .cacheMiss: prefix = text("Вне кэша", "Miss")
        case .context: prefix = text("Контекст", "Ctx")
        case .reasoning: prefix = text("Рассужд.", "Reason")
        case .thread: prefix = text("Чат", "Task")
        default: prefix = ""
        }
        return prefix.isEmpty ? value : "\(prefix) \(value)"
    }

    static func text(_ russian: String, _ english: String) -> String {
        isRussian ? russian : english
    }
}
