// ignore_for_file: curly_braces_in_flow_control_structures, unnecessary_cast
library;

import 'dart:io';
import '../../ai/provider_config.dart';
import '../../ai/model_catalog.dart';
import '../../ai/provider_api.dart';
import '../../core/ulid.dart';
import '../../platform/workspace_guard.dart';
import '../../state/app_settings.dart';
import '../tool.dart';
import '../workspace/mutation_queue.dart';
import 'openai_image_client.dart';

abstract class _ImageToolBase extends Tool {
  const _ImageToolBase();
  String modelKey(ToolContext context);
  Future<OpenAiImageResult> call(
    ModelSpec model,
    ProviderConfig provider,
    ToolContext context,
    Map<String, Object?> args,
  );
  String get outputLabel;

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async {
    final Object? promptRaw = arguments['prompt'];
    if (promptRaw is! String || promptRaw.trim().isEmpty)
      return ToolResult.error('参数 prompt 必须是非空字符串');
    final AppSettings? settings = context.settings;
    if (settings == null) return ToolResult.error('图片工具缺少应用配置');
    final String key = modelKey(context);
    final ModelSpec? model = settings.modelByKey(key);
    if (model == null) return ToolResult.error('未配置图片模型，请在设置页选择图片生成/编辑模型');
    final ProviderConfig? provider = settings.providerOf(model.providerId);
    if (provider == null || provider.apiKey.isEmpty)
      return ToolResult.error('图片模型的提供商未配置 API Key');
    try {
      final OpenAiImageResult result = await call(
        model,
        provider,
        context,
        arguments,
      );
      final List<String> paths = <String>[];
      for (final List<int> bytes in result.images) {
        final String relative =
            'images/${_stamp()}-${Ulid.generate().substring(0, 8)}.png';
        final PathCheck check = context.workspace.check(relative);
        if (check is! PathAllowed) return ToolResult.error('生成文件路径不在工作区内');
        await MutationQueue.instance.run(context.workspace.root, () async {
          File(check.absolute).parent.createSync(recursive: true);
          File(check.absolute).writeAsBytesSync(bytes, flush: true);
        });
        paths.add(relative);
      }
      return ToolResult.ok(
        '$outputLabel完成，已保存：${paths.join('、')}',
        uiPayload: <String, Object?>{'paths': paths, 'count': paths.length},
      );
    } on Object catch (e) {
      return ToolResult.error('$outputLabel失败：$e');
    }
  }

  static String _stamp() {
    final DateTime d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}-${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }
}

class GenImageTool extends _ImageToolBase {
  const GenImageTool();
  @override
  String get permissionId => 'gen_image';
  @override
  ToolDefinition get definition => const ToolDefinition(
    name: 'gen_image',
    description:
        '根据提示词从零生成一张或多张新图片并保存到当前工作区。它不读取已有图片；如果要基于工作区图片进行修改，请使用 edit_image。',
    schema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'prompt': <String, Object?>{'type': 'string'},
        'size': <String, Object?>{'type': 'string'},
        'count': <String, Object?>{'type': 'integer'},
      },
      'required': <String>['prompt'],
    },
  );
  @override
  String modelKey(ToolContext context) =>
      context.settings?.imageGenModelKey ??
      _firstImageModel(context.settings) ??
      context.settings?.resolvedDefaultModelKey ??
      '';
  @override
  Future<OpenAiImageResult> call(
    ModelSpec model,
    ProviderConfig provider,
    ToolContext context,
    Map<String, Object?> args,
  ) => OpenAiImageClient(apiKey: provider.apiKey, baseUrl: provider.baseUrl)
      .generate(
        model: model.id,
        prompt: args['prompt'] as String,
        size: args['size'] as String?,
        count: args['count'] is int
            ? ((args['count'] as int).clamp(1, 4) as int)
            : 1,
        token: context.token,
      );
  @override
  String get outputLabel => '图片生成';
}

class EditImageTool extends _ImageToolBase {
  const EditImageTool();
  @override
  String get permissionId => 'edit_image';
  @override
  ToolDefinition get definition => const ToolDefinition(
    name: 'edit_image',
    description:
        '读取当前工作区中的已有图片，按提示词生成编辑后的新图片；原图只读且绝不覆盖。它适合“把这张图的背景改成夜晚”等修改，不是从零创作。',
    schema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'image_file': <String, Object?>{
          'type': 'string',
          'description': '工作区内源图片相对路径',
        },
        'prompt': <String, Object?>{'type': 'string'},
        'size': <String, Object?>{'type': 'string'},
      },
      'required': <String>['image_file', 'prompt'],
    },
  );
  @override
  String modelKey(ToolContext context) =>
      context.settings?.imageEditModelKey ??
      _firstImageModel(context.settings) ??
      context.settings?.resolvedDefaultModelKey ??
      '';
  @override
  Future<OpenAiImageResult> call(
    ModelSpec model,
    ProviderConfig provider,
    ToolContext context,
    Map<String, Object?> args,
  ) async {
    final Object? raw = args['image_file'];
    if (raw is! String || raw.trim().isEmpty)
      throw ArgumentError('image_file 必须是非空字符串');
    final PathCheck check = context.workspace.check(raw);
    if (check is! PathAllowed)
      throw ArgumentError((check as PathRejected).reason);
    final File file = File(check.absolute);
    if (!file.existsSync() || file.statSync().type != FileSystemEntityType.file)
      throw ArgumentError('源图片不存在：${check.relative}');
    return OpenAiImageClient(
      apiKey: provider.apiKey,
      baseUrl: provider.baseUrl,
    ).edit(
      model: model.id,
      image: file,
      prompt: args['prompt'] as String,
      size: args['size'] as String?,
      token: context.token,
    );
  }

  @override
  String get outputLabel => '图片编辑';
}

String? _firstImageModel(AppSettings? settings) {
  if (settings == null) return null;
  for (final ModelSpec model in settings.models) {
    if (model.id.startsWith('gpt-image')) return model.key;
  }
  return null;
}
