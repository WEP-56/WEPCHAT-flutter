import 'package:flutter_test/flutter_test.dart';

import 'package:wepchat/models/content.dart';
import 'package:wepchat/models/markdown_blocks.dart';

/// 块级 Markdown 解析。
///
/// 只覆盖模型真会吐出来的形状。行内样式（`**粗体**`）不在这里 —— 那是
/// 渲染期的事，解析器原样留在段落文本里。
void main() {
  group('段落', () {
    test('空文本得到空列表', () {
      expect(parseMarkdownBlocks(''), isEmpty);
      expect(parseMarkdownBlocks('   \n\n  '), isEmpty);
    });

    test('连续行合并成一段，空行分段', () {
      final List<ContentBlock> blocks = parseMarkdownBlocks(
        '第一行\n第二行\n\n第二段',
      );

      expect(blocks.length, equals(2));
      expect((blocks[0] as ParagraphBlock).text, equals('第一行\n第二行'));
      expect((blocks[1] as ParagraphBlock).text, equals('第二段'));
    });
  });

  group('标题', () {
    test('# 数量决定层级', () {
      final List<ContentBlock> blocks = parseMarkdownBlocks(
        '# 一级\n## 二级\n### 三级',
      );

      expect(blocks.length, equals(3));
      expect((blocks[0] as HeadingBlock).level, equals(1));
      expect((blocks[0] as HeadingBlock).text, equals('一级'));
      expect((blocks[1] as HeadingBlock).level, equals(2));
      expect((blocks[2] as HeadingBlock).level, equals(3));
    });

    test('四级以上压到三级：界面只有三档字号', () {
      final List<ContentBlock> blocks = parseMarkdownBlocks('#### 四级');

      expect((blocks.single as HeadingBlock).level, equals(3));
    });

    test('# 后面没空格不是标题', () {
      final List<ContentBlock> blocks = parseMarkdownBlocks('#hashtag');

      expect(blocks.single, isA<ParagraphBlock>());
    });
  });

  group('代码块', () {
    test('围栏内容原样保留，语言进 lang', () {
      final List<ContentBlock> blocks = parseMarkdownBlocks(
        '```dart\nvoid main() {\n  print(1);\n}\n```',
      );

      final CodeBlock code = blocks.single as CodeBlock;
      expect(code.lang, equals('dart'));
      expect(code.code, equals('void main() {\n  print(1);\n}'));
    });

    test('未闭合的围栏也当代码块', () {
      // 流式生成时最后一块必然是未闭合的。显示成字面 ``` 会让人以为坏了。
      final List<ContentBlock> blocks = parseMarkdownBlocks(
        '说明\n\n```python\nprint(1)',
      );

      expect(blocks.length, equals(2));
      final CodeBlock code = blocks[1] as CodeBlock;
      expect(code.lang, equals('python'));
      expect(code.code, equals('print(1)'));
    });

    test('代码块里的 # 和 - 不被当成标题或列表', () {
      final List<ContentBlock> blocks = parseMarkdownBlocks(
        '```sh\n# 注释\n- 不是列表\n```',
      );

      expect(blocks.single, isA<CodeBlock>());
      expect((blocks.single as CodeBlock).code, equals('# 注释\n- 不是列表'));
    });

    test('没写语言时 lang 为空串', () {
      final List<ContentBlock> blocks = parseMarkdownBlocks('```\nplain\n```');

      expect((blocks.single as CodeBlock).lang, isEmpty);
    });
  });

  group('列表', () {
    test('- 开头的连续行是一个无序列表', () {
      final List<ContentBlock> blocks = parseMarkdownBlocks(
        '- 苹果\n- 香蕉\n- 橘子',
      );

      final BulletListBlock list = blocks.single as BulletListBlock;
      expect(list.ordered, isFalse);
      expect(list.items, equals(<String>['苹果', '香蕉', '橘子']));
    });

    test('数字. 开头的是有序列表', () {
      final List<ContentBlock> blocks = parseMarkdownBlocks(
        '1. 第一步\n2. 第二步\n10. 第十步',
      );

      final BulletListBlock list = blocks.single as BulletListBlock;
      expect(list.ordered, isTrue);
      expect(list.items, equals(<String>['第一步', '第二步', '第十步']));
    });

    test('破折号后面没空格不是列表', () {
      // 用户打的 "-3 度" 不该变成列表项。
      final List<ContentBlock> blocks = parseMarkdownBlocks('-3 度');

      expect(blocks.single, isA<ParagraphBlock>());
    });

    test('列表后面接段落，两者分开', () {
      final List<ContentBlock> blocks = parseMarkdownBlocks(
        '- 一\n- 二\n\n收尾的话',
      );

      expect(blocks.length, equals(2));
      expect(blocks[0], isA<BulletListBlock>());
      expect(blocks[1], isA<ParagraphBlock>());
    });
  });

  group('引用', () {
    test('> 开头的连续行合并成一个引用块', () {
      final List<ContentBlock> blocks = parseMarkdownBlocks(
        '> 第一行\n> 第二行',
      );

      expect((blocks.single as QuoteBlock).text, equals('第一行\n第二行'));
    });
  });

  group('表格', () {
    test('表头 + 分隔行 + 数据行', () {
      final List<ContentBlock> blocks = parseMarkdownBlocks(
        '| 名称 | 数量 |\n| --- | ---: |\n| 苹果 | 3 |\n| 香蕉 | 5 |',
      );

      final TableBlock table = blocks.single as TableBlock;
      expect(table.head, equals(<String>['名称', '数量']));
      expect(table.rows.length, equals(2));
      expect(table.rows[0].cells, equals(<String>['苹果', '3']));
    });

    test('没有分隔行就当普通文本', () {
      final List<ContentBlock> blocks = parseMarkdownBlocks(
        '| 这不是 | 表格 |\n| 只是竖线 | 而已 |',
      );

      expect(blocks.single, isA<ParagraphBlock>());
    });

    test('流式生成时单个竖线不炸（RangeError 修复）', () {
      // 修复前：trimmed.substring(1, trimmed.length - 1) 在 length=1 时炸。
      expect(parseMarkdownBlocks('|'), isA<List<ContentBlock>>());
      expect(parseMarkdownBlocks('|\n一段话'), isA<List<ContentBlock>>());
      // 表格打到一半也不该炸。
      expect(parseMarkdownBlocks('| 列 |\n|'), isA<List<ContentBlock>>());
    });
  });

  test('混合文档：各块按出现顺序排好', () {
    final List<ContentBlock> blocks = parseMarkdownBlocks('''
## 结论

先说要点：

- 快
- 稳

代码如下：

```dart
final x = 1;
```

> 注意兼容性。
''');

    expect(blocks.map((ContentBlock b) => b.runtimeType).toList(), equals(
      <Type>[
        HeadingBlock,
        ParagraphBlock,
        BulletListBlock,
        ParagraphBlock,
        CodeBlock,
        QuoteBlock,
      ],
    ));
  });
}
