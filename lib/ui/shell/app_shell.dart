import 'package:flutter/material.dart';

import '../../app/responsive.dart';
import 'compact_shell.dart';
import 'expanded_shell.dart';

/// 应用外壳。按可用宽度在三栏与抽屉两种布局之间切换，不看运行平台，
/// 所以窄窗口的 Windows 也会得到移动端布局。
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return switch (formFactorFor(constraints.maxWidth)) {
          FormFactor.expanded => const ExpandedShell(),
          FormFactor.compact => const CompactShell(),
        };
      },
    );
  }
}
