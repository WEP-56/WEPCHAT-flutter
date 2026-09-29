import 'package:flutter_test/flutter_test.dart';

import 'package:wepchat/models/chat.dart';

/// `SessionGroup` 的契约测试。
///
/// 这里锁的是侧边栏曾经丢会话的那条不变量：会话分组标签和"界面会渲染哪些
/// 分组"必须来自同一份定义。先前标签由 `session_projection` 产出、分组顺序
/// 由另一份白名单给出，2～29 天这一段的标签不在白名单里，整组会话就从侧边栏
/// 静默消失——库里还在，用户看到的是空列表。
void main() {
  test('天数区间无空档，任何天数都落在某个分组里', () {
    SessionGroup? previous;
    for (int days = 0; days <= 400; days++) {
      final SessionGroup group = SessionGroup.fromDays(days);
      // 分组随天数单调后退：界面按声明顺序渲染，跳档会让列表顺序错乱。
      if (previous != null) {
        expect(
          group.index,
          greaterThanOrEqualTo(previous.index),
          reason: '$days 天时分组回退了',
        );
      }
      previous = group;
    }
  });

  test('分组边界', () {
    expect(SessionGroup.fromDays(0), SessionGroup.today);
    expect(SessionGroup.fromDays(1), SessionGroup.yesterday);
    expect(SessionGroup.fromDays(2), SessionGroup.pastWeek);
    expect(SessionGroup.fromDays(6), SessionGroup.pastWeek);
    expect(SessionGroup.fromDays(7), SessionGroup.pastMonth);
    expect(SessionGroup.fromDays(29), SessionGroup.pastMonth);
    expect(SessionGroup.fromDays(30), SessionGroup.earlier);
    // 时钟偏差导致 updatedAt 落在未来时按"今天"处理，而不是抛错或落到更早。
    expect(SessionGroup.fromDays(-3), SessionGroup.today);
  });

  test('每个分组都能被日期推算命中，不存在永远不出现的孤儿分组', () {
    final Set<SessionGroup> reached = <SessionGroup>{
      for (int days = 0; days <= 400; days++) SessionGroup.fromDays(days),
    };
    expect(reached, SessionGroup.values.toSet());
  });

  test('标签唯一、非空，且按显示顺序排列', () {
    final List<String> labels = SessionGroup.values
        .map((SessionGroup g) => g.label)
        .toList();

    expect(labels, <String>['今天', '昨天', '过去 7 天', '过去 30 天', '更早']);
    expect(labels.toSet().length, labels.length);
    expect(labels.every((String label) => label.trim().isNotEmpty), isTrue);
  });
}
