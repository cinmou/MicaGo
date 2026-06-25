import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class MicaLocalizations {
  final Locale locale;
  const MicaLocalizations(this.locale);

  static const LocalizationsDelegate<MicaLocalizations> delegate =
      _MicaLocalizationsDelegate();

  static MicaLocalizations of(BuildContext context) =>
      Localizations.of<MicaLocalizations>(context, MicaLocalizations) ??
      const MicaLocalizations(Locale('en'));

  String get _table {
    if (locale.languageCode == 'zh' && locale.scriptCode == 'Hant') {
      return 'zhHant';
    }
    if (locale.languageCode == 'zh') return 'zhHans';
    return 'en';
  }

  String t(String key) {
    final table = _strings[_table] ?? _strings['en']!;
    return table[key] ?? _strings['en']![key] ?? key;
  }
}

class _MicaLocalizationsDelegate
    extends LocalizationsDelegate<MicaLocalizations> {
  const _MicaLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      locale.languageCode == 'en' || locale.languageCode == 'zh';

  @override
  Future<MicaLocalizations> load(Locale locale) =>
      SynchronousFuture(MicaLocalizations(locale));

  @override
  bool shouldReload(_MicaLocalizationsDelegate old) => false;
}

const _strings = {
  'en': {
    'settings.appearance': 'Appearance',
    'nav.chats': 'Chats',
    'nav.settings': 'Settings',
    'settings.messaging': 'Messaging',
    'settings.notifications': 'Notifications',
    'settings.more': 'More',
    'settings.contacts': 'Contacts',
    'settings.messageDisplay': 'Message display',
    'settings.debugTools': 'Debug tools',
    'settings.about': 'About',
    'settings.editConnection': 'Edit connection',
    'settings.disconnect': 'Disconnect',
    'settings.disconnectTitle': 'Disconnect?',
    'settings.disconnectBody':
        'This removes the saved server and token from this device.',
    'settings.cancel': 'Cancel',
    'settings.route': 'Server route',
    'settings.autoRoute': 'Automatic',
    'settings.connected': 'Connected',
    'settings.collection': 'Collection',
    'settings.recentPerChat': 'Recent messages per chat',
    'settings.theme': 'Theme',
    'settings.system': 'System',
    'settings.light': 'Light',
    'settings.dark': 'Dark',
    'settings.color': 'Color',
    'settings.language': 'Language',
    'settings.systemLanguage': 'System language',
    'settings.english': 'English',
    'settings.zhHans': '简体中文',
    'settings.zhHant': '繁體中文',
    'settings.activeServerUrl': 'Active server URL',
    'settings.websocketUrl': 'WebSocket URL',
    'settings.bearerToken': 'Bearer token',
    'settings.privacy': 'Privacy',
    'settings.status': 'Status',
    'settings.preRelease': 'Pre-release client.',
    'settings.copyDebug': 'Copy debug report',
    'settings.connectionDiagnostics': 'Connection diagnostics',
    'settings.realtimeEvents': 'Realtime events',
    'settings.deviceRegistration': 'Device registration',
    'pair.connectToMicaGo': 'Connect to micaGO',
    'pair.scanQr': 'Scan QR code',
    'pair.pasteJson': 'Paste connection JSON',
    'pair.pasteJsonHint': 'Paste the connection JSON from the Mac app',
    'pair.connect': 'Connect',
    'pair.advancedSetup': 'Advanced manual setup',
    'pair.advancedSetupHint':
        'Enter origins only; WebSocket URLs are derived automatically.',
    'pair.publicUrl': 'Public URL (optional)',
    'pair.lanUrl': 'LAN URL (optional)',
    'pair.bearerToken': 'Bearer token',
    'pair.testAdvanced': 'Test advanced connection',
    'pair.saveAdvanced': 'Save advanced connection',
    'pair.headerSubtitle': 'Connect with QR or connection JSON',
    'pair.scanTitle': 'Scan pairing code',
    'pair.toggleTorch': 'Toggle torch',
    'pair.scanHint':
        'Scan the micaGO connection QR code\n(Mac app -> Dashboard -> Create Connection).',
    'pair.connecting': 'Connecting to the server...',
    'pair.failed': 'Pairing failed.',
    'pair.paired': 'Paired!',
    'pair.cameraUnavailable': 'Camera unavailable',
    'pair.cameraHelp':
        'micaGO needs camera access to scan the pairing code. Grant the Camera permission in Android Settings, then come back. You can also pair manually instead.',
    'pair.codeFound': 'Pairing code found',
    'pair.serverUrl': 'Server URL',
    'pair.websocket': 'WebSocket',
    'pair.token': 'Token',
    'pair.server': 'Server',
    'pair.useThisServer': 'Use this server',
    'pair.scanAgain': 'Scan again',
    'pair.tryAgain': 'Try again',
    'pair.scanDifferent': 'Scan a different code',
  },
  'zhHans': {
    'settings.appearance': '外观',
    'nav.chats': '聊天',
    'nav.settings': '设置',
    'settings.messaging': '消息',
    'settings.notifications': '通知',
    'settings.more': '更多',
    'settings.contacts': '联系人',
    'settings.messageDisplay': '消息显示',
    'settings.debugTools': '调试工具',
    'settings.about': '关于',
    'settings.editConnection': '编辑连接',
    'settings.disconnect': '断开连接',
    'settings.disconnectTitle': '断开连接？',
    'settings.disconnectBody': '这会从本设备移除已保存的服务器和令牌。',
    'settings.cancel': '取消',
    'settings.route': '服务器线路',
    'settings.autoRoute': '自动',
    'settings.connected': '已连接',
    'settings.collection': '收集',
    'settings.recentPerChat': '每个聊天的最近消息',
    'settings.theme': '主题',
    'settings.system': '跟随系统',
    'settings.light': '浅色',
    'settings.dark': '深色',
    'settings.color': '颜色',
    'settings.language': '语言',
    'settings.systemLanguage': '系统语言',
    'settings.english': 'English',
    'settings.zhHans': '简体中文',
    'settings.zhHant': '繁體中文',
    'settings.activeServerUrl': '当前服务器 URL',
    'settings.websocketUrl': 'WebSocket URL',
    'settings.bearerToken': 'Bearer 令牌',
    'settings.privacy': '隐私',
    'settings.status': '状态',
    'settings.preRelease': '预发布客户端。',
    'settings.copyDebug': '复制调试报告',
    'settings.connectionDiagnostics': '连接诊断',
    'settings.realtimeEvents': '实时事件',
    'settings.deviceRegistration': '设备注册',
    'pair.connectToMicaGo': '连接到 micaGO',
    'pair.scanQr': '扫描二维码',
    'pair.pasteJson': '粘贴连接 JSON',
    'pair.pasteJsonHint': '粘贴 Mac 应用中的连接 JSON',
    'pair.connect': '连接',
    'pair.advancedSetup': '高级手动设置',
    'pair.advancedSetupHint': '只输入 origin；WebSocket URL 会自动生成。',
    'pair.publicUrl': '公网 URL（可选）',
    'pair.lanUrl': '局域网 URL（可选）',
    'pair.bearerToken': 'Bearer 令牌',
    'pair.testAdvanced': '测试高级连接',
    'pair.saveAdvanced': '保存高级连接',
    'pair.headerSubtitle': '使用二维码或连接 JSON 连接',
    'pair.scanTitle': '扫描配对码',
    'pair.toggleTorch': '切换手电筒',
    'pair.scanHint': '扫描 micaGO 连接二维码\n（Mac 应用 -> 仪表盘 -> 创建连接）。',
    'pair.connecting': '正在连接服务器...',
    'pair.failed': '配对失败。',
    'pair.paired': '已配对！',
    'pair.cameraUnavailable': '相机不可用',
    'pair.cameraHelp': 'micaGO 需要相机权限来扫描配对码。请在 Android 设置中授予相机权限后返回。你也可以手动配对。',
    'pair.codeFound': '已找到配对码',
    'pair.serverUrl': '服务器 URL',
    'pair.websocket': 'WebSocket',
    'pair.token': '令牌',
    'pair.server': '服务器',
    'pair.useThisServer': '使用这个服务器',
    'pair.scanAgain': '重新扫描',
    'pair.tryAgain': '重试',
    'pair.scanDifferent': '扫描其他配对码',
  },
  'zhHant': {
    'settings.appearance': '外觀',
    'nav.chats': '聊天',
    'nav.settings': '設定',
    'settings.messaging': '訊息',
    'settings.notifications': '通知',
    'settings.more': '更多',
    'settings.contacts': '聯絡人',
    'settings.messageDisplay': '訊息顯示',
    'settings.debugTools': '除錯工具',
    'settings.about': '關於',
    'settings.editConnection': '編輯連線',
    'settings.disconnect': '中斷連線',
    'settings.disconnectTitle': '中斷連線？',
    'settings.disconnectBody': '這會從本裝置移除已儲存的伺服器和權杖。',
    'settings.cancel': '取消',
    'settings.route': '伺服器路線',
    'settings.autoRoute': '自動',
    'settings.connected': '已連線',
    'settings.collection': '收集',
    'settings.recentPerChat': '每個對話的最近訊息',
    'settings.theme': '主題',
    'settings.system': '跟隨系統',
    'settings.light': '淺色',
    'settings.dark': '深色',
    'settings.color': '顏色',
    'settings.language': '語言',
    'settings.systemLanguage': '系統語言',
    'settings.english': 'English',
    'settings.zhHans': '简体中文',
    'settings.zhHant': '繁體中文',
    'settings.activeServerUrl': '目前伺服器 URL',
    'settings.websocketUrl': 'WebSocket URL',
    'settings.bearerToken': 'Bearer 權杖',
    'settings.privacy': '隱私',
    'settings.status': '狀態',
    'settings.preRelease': '預發布用戶端。',
    'settings.copyDebug': '複製除錯報告',
    'settings.connectionDiagnostics': '連線診斷',
    'settings.realtimeEvents': '即時事件',
    'settings.deviceRegistration': '裝置註冊',
    'pair.connectToMicaGo': '連線到 micaGO',
    'pair.scanQr': '掃描 QR 碼',
    'pair.pasteJson': '貼上連線 JSON',
    'pair.pasteJsonHint': '貼上 Mac 應用程式中的連線 JSON',
    'pair.connect': '連線',
    'pair.advancedSetup': '進階手動設定',
    'pair.advancedSetupHint': '只輸入 origin；WebSocket URL 會自動產生。',
    'pair.publicUrl': '公開 URL（選填）',
    'pair.lanUrl': '區域網路 URL（選填）',
    'pair.bearerToken': 'Bearer 權杖',
    'pair.testAdvanced': '測試進階連線',
    'pair.saveAdvanced': '儲存進階連線',
    'pair.headerSubtitle': '使用 QR 碼或連線 JSON 連線',
    'pair.scanTitle': '掃描配對碼',
    'pair.toggleTorch': '切換手電筒',
    'pair.scanHint': '掃描 micaGO 連線 QR 碼\n（Mac 應用程式 -> 儀表板 -> 建立連線）。',
    'pair.connecting': '正在連線到伺服器...',
    'pair.failed': '配對失敗。',
    'pair.paired': '已配對！',
    'pair.cameraUnavailable': '相機無法使用',
    'pair.cameraHelp': 'micaGO 需要相機權限來掃描配對碼。請在 Android 設定中授予相機權限後返回。你也可以手動配對。',
    'pair.codeFound': '已找到配對碼',
    'pair.serverUrl': '伺服器 URL',
    'pair.websocket': 'WebSocket',
    'pair.token': '權杖',
    'pair.server': '伺服器',
    'pair.useThisServer': '使用這個伺服器',
    'pair.scanAgain': '重新掃描',
    'pair.tryAgain': '重試',
    'pair.scanDifferent': '掃描其他配對碼',
  },
};
