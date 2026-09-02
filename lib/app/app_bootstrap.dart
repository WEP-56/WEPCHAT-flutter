import '../platform/app_paths.dart';
import '../platform/settings_store.dart';
import '../platform/workspace_paths.dart';
import '../state/app_settings.dart';
import '../state/session_store.dart';
import '../storage/storage.dart';

/// 应用启动时的异步初始化任务。
///
/// 在 `main()` 里 `await AppBootstrap.init()`，再把结果传给 `WepChatApp`。
/// 会话列表在这里就装载完，所以首帧渲染时 `SessionStore.active` 已经有值
/// ——界面不用处理"加载中"分支，接存储这件事对 UI 代码是透明的
/// （实施 TODO §1-1、§9-12）。
class AppBootstrap {
  AppBootstrap._({
    required this.storage,
    required this.settings,
    required this.sessions,
    required this.interruptedSessionIds,
  });

  final WepStorage storage;
  final AppSettings settings;
  final SessionStore sessions;

  /// 启动时发现未正常结束的会话 id（实施 TODO §6.2）。
  ///
  /// 界面据此显示"上次回复被中断，可重试"。M0 只是取到手，接 agent 之后才用。
  final List<String> interruptedSessionIds;

  /// 打开存储、标记中断的 run、装载会话列表。
  ///
  /// [rootOverride] 仅用于测试——生产代码传 null，让它调 `path_provider`。
  static Future<AppBootstrap> init({String? rootOverride}) async {
    final AppPaths paths = rootOverride == null
        ? await AppPaths.resolve()
        : AppPaths.fromPath(rootOverride);

    final WepStorage storage = await WepStorage.open(
      dbPath: paths.databasePath,
      blobRoot: paths.blobRoot,
    );

    // 顺序有讲究：先把上次没结束的 run 标成中断，再读会话列表，
    // 否则列表里会带着已经不可能完成的"生成中"状态。
    final List<String> interrupted = await storage.reconcileInterruptedRuns();

    final AppSettings settings = AppSettings.load(
      SettingsStore.atPath(paths.settingsPath),
    );

    // 测试给了 rootOverride 时工作区也放到那个临时目录下，别去动用户主目录。
    final WorkspaceRoots workspaces = WorkspaceRoots.resolve(
      rootOverride == null ? settings.workspaceRoot : '',
      fallback: paths.workspaceRoot,
    );

    final SessionStore sessions = await SessionStore.load(
      storage: storage,
      workspaces: workspaces,
      settings: settings,
    );

    return AppBootstrap._(
      storage: storage,
      settings: settings,
      sessions: sessions,
      interruptedSessionIds: interrupted,
    );
  }

  Future<void>? _disposal;

  /// 反向拆除：先停界面状态，最后关存储连接。
  ///
  /// 调用方通常是 `State.dispose()`，那是同步的，拿不到这个 future——所以
  /// 结果缓存下来由 [disposed] 暴露：测试要等存储真的松开文件句柄才能删
  /// 临时目录，否则 Windows 会报 errno 32。重复调用返回同一个 future。
  Future<void> dispose() {
    return _disposal ??= _dispose();
  }

  /// [dispose] 已经启动的拆除过程；没启动过则为 null。
  Future<void>? get disposed => _disposal;

  Future<void> _dispose() async {
    sessions.dispose();
    settings.dispose();
    await storage.close();
  }
}
