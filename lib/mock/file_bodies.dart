import '../models/content.dart';
import '../models/workspace.dart';

/// 工作区文件预览内容（mock）。真实实现由 `read_file` 工具结果填充。
const Map<String, FileBody> kFileBodies = <String, FileBody>{
  'sales_q2.csv': CsvFileBody(
    <String>['month', 'region', 'revenue', 'orders'],
    <List<String>>[
      <String>['2026-04', '华东', '1284300', '3120'],
      <String>['2026-04', '华南', '962400', '2481'],
      <String>['2026-05', '华东', '1401250', '3388'],
      <String>['2026-05', '华南', '874900', '2205'],
      <String>['2026-06', '华东', '1512780', '3671'],
      <String>['2026-06', '华南', '803150', '1994'],
    ],
  ),
  'summarize_sales.py': CodeFileBody('python', '''
import csv
from collections import defaultdict

def summarize(path):
    total = defaultdict(float)
    with open(path, newline="", encoding="utf-8") as fp:
        for row in csv.DictReader(fp):
            total[row["region"]] += float(row["revenue"])
    grand = sum(total.values())
    return [(r, v, v / grand) for r, v in sorted(total.items())]

if __name__ == "__main__":
    for region, revenue, share in summarize("sales_q2.csv"):
        print(f"{region}\\t{revenue:.0f}\\t{share:.1%}")
'''),
  'sales_summary_q2.csv': CsvFileBody(
    <String>['region', 'revenue', 'share', 'qoq'],
    <List<String>>[
      <String>['华东', '4198330', '61.0%', '+11.4%'],
      <String>['华南', '2640450', '38.4%', '-8.2%'],
      <String>['其他', '41220', '0.6%', '+1.1%'],
    ],
  ),
  'report_q2.md': BlocksFileBody(<ContentBlock>[
    HeadingBlock('Q2 销售数据汇总', level: 1),
    ParagraphBlock(
      '统计区间 **2026-04 ~ 2026-06**，数据来源 `sales_q2.csv`，由 `run_js` 脚本汇总。',
    ),
    HeadingBlock('区域表现'),
    TableBlock(
      <String>['区域', '营收', '占比', '环比'],
      <TableRowData>[
        TableRowData(<String>['华东', '419.8 万', '61.0%', '+11.4%']),
        TableRowData(<String>['华南', '264.0 万', '38.4%', '-8.2%'], neg: true),
      ],
    ),
    HeadingBlock('结论'),
    BulletListBlock(<String>[
      '华东连续三个月增长，6 月创区间新高。',
      '华南 5 月起下滑，需要核对渠道口径。',
      '订单量与营收同向，客单价基本稳定。',
    ]),
    QuoteBlock('下一步：补齐 7 月数据后重跑同一脚本即可增量更新。'),
  ]),
  'vector_db_comparison.md': BlocksFileBody(<ContentBlock>[
    HeadingBlock('向量数据库选型对比', level: 1),
    ParagraphBlock('面向本地优先的轻量应用，优先考虑 **嵌入式部署** 与跨平台可用性。'),
    TableBlock(
      <String>['方案', '部署形态', '跨平台', '适用规模'],
      <TableRowData>[
        TableRowData(<String>['sqlite-vec', '嵌入式', 'Android / Windows', '十万级']),
        TableRowData(<String>['Qdrant', '独立服务', '需服务端', '百万级']),
        TableRowData(<String>[
          'Chroma',
          'Python 进程',
          '不适合移动端',
          '十万级',
        ], neg: true),
      ],
    ),
    BulletListBlock(<String>[
      '嵌入式方案不引入后台进程，符合 local-first 边界。',
      '独立服务方案留给后续可选高级扩展。',
    ], ordered: true),
  ]),
  'sources.json': CodeFileBody('json', '''
{
  "query": "本地优先 向量数据库 嵌入式 2026",
  "results": [
    { "source_id": "s1", "title": "sqlite-vec 0.3 发布说明", "host": "github.com" },
    { "source_id": "s2", "title": "Qdrant 部署形态对比", "host": "qdrant.tech" },
    { "source_id": "s3", "title": "移动端向量检索实践", "host": "infoq.cn" }
  ],
  "fetched_at": "2026-08-30T10:12:00Z"
}
'''),
  'camping_checklist.html': HtmlFileBody(),
  'checklist_style.css': CodeFileBody('css', '''
:root {
  --leaf: #2f7d5d;
  --paper: #f6f4ee;
}

body {
  margin: 0;
  font-family: system-ui, sans-serif;
  background: var(--paper);
}

.card {
  max-width: 520px;
  margin: 32px auto;
  border-radius: 16px;
  background: #fff;
  box-shadow: 0 6px 24px rgb(0 0 0 / 8%);
}

.item.done label {
  color: #9aa0a6;
  text-decoration: line-through;
}
'''),
  'Bedienungsanleitung.pdf': BinaryFileBody('PDF · 12 页 · 已提取前 8 页可读文本'),
  'translation_de.md': BlocksFileBody(<ContentBlock>[
    HeadingBlock('咖啡机使用说明（中译）', level: 1),
    ParagraphBlock('原文：`Bedienungsanleitung.pdf` 第 1–8 页。术语表见文末。'),
    HeadingBlock('首次使用'),
    BulletListBlock(<String>[
      '取下水箱，注入不超过 **1.2 L** 的冷水。',
      '首次通电后执行一次空冲洗程序。',
      '指示灯由橙色转为白色即表示预热完成。',
    ], ordered: true),
    QuoteBlock('Achtung：除水垢期间请勿断电，否则程序需要重新开始。'),
  ]),
};
