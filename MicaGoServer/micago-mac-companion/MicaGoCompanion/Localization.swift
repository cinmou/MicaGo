import Foundation

enum L10n {
    static func tr(_ key: String) -> String {
        let lang = Locale.preferredLanguages.first?.lowercased() ?? "en"
        let table: [String: String]
        if lang.hasPrefix("zh-hant") || lang.hasPrefix("zh-tw") || lang.hasPrefix("zh-hk") {
            table = zhHant
        } else if lang.hasPrefix("zh") {
            table = zhHans
        } else {
            table = en
        }
        return table[key] ?? en[key] ?? key
    }

    private static let en = [
        "sidebar.dashboard": "Dashboard",
        "sidebar.connections": "Connections",
        "sidebar.syncControl": "Sync Control",
        "sidebar.notifications": "Notifications",
        "sidebar.tutorials": "Tutorials",
        "sidebar.advanced": "Advanced",
        "sidebar.debug": "Debug",
        "sidebar.log": "Log",
        "menu.running": "micaGO backend is running",
        "menu.external": "micaGO backend is reachable but not managed by Companion",
        "menu.notRunning": "micaGO backend is not running",
        "menu.openDashboard": "Open Dashboard",
        "menu.startServer": "Start Server",
        "menu.stopServer": "Stop Server",
        "menu.keepAwake": "Keep Awake",
        "menu.quit": "Quit micaGO Companion",
    ]

    private static let zhHans = [
        "sidebar.dashboard": "仪表盘",
        "sidebar.connections": "连接",
        "sidebar.syncControl": "同步控制",
        "sidebar.notifications": "通知",
        "sidebar.tutorials": "教程",
        "sidebar.advanced": "高级",
        "sidebar.debug": "调试",
        "sidebar.log": "日志",
        "menu.running": "micaGO 后端正在运行",
        "menu.external": "micaGO 后端可访问，但不由 Companion 管理",
        "menu.notRunning": "micaGO 后端未运行",
        "menu.openDashboard": "打开仪表盘",
        "menu.startServer": "启动服务器",
        "menu.stopServer": "停止服务器",
        "menu.keepAwake": "保持唤醒",
        "menu.quit": "退出 micaGO Companion",
    ]

    private static let zhHant = [
        "sidebar.dashboard": "儀表板",
        "sidebar.connections": "連線",
        "sidebar.syncControl": "同步控制",
        "sidebar.notifications": "通知",
        "sidebar.tutorials": "教學",
        "sidebar.advanced": "進階",
        "sidebar.debug": "除錯",
        "sidebar.log": "日誌",
        "menu.running": "micaGO 後端正在執行",
        "menu.external": "micaGO 後端可連線，但不由 Companion 管理",
        "menu.notRunning": "micaGO 後端未執行",
        "menu.openDashboard": "開啟儀表板",
        "menu.startServer": "啟動伺服器",
        "menu.stopServer": "停止伺服器",
        "menu.keepAwake": "保持喚醒",
        "menu.quit": "結束 micaGO Companion",
    ]
}
