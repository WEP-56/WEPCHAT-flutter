import 'package:flutter/widgets.dart';

/// 布局形态。只按可用宽度判断，不按 `Platform.isAndroid` 判断，
/// 这样窄窗口的 Windows 也能得到移动端布局（AGENTS.md §7）。
enum FormFactor { compact, expanded }

/// 三栏布局需要的最小宽度。
const double kExpandedMinWidth = 900;

FormFactor formFactorFor(double width) {
  return width < kExpandedMinWidth ? FormFactor.compact : FormFactor.expanded;
}

/// 供 Navigator 全屏路由使用：路由不在外壳子树内，按窗口宽度判断。
FormFactor formFactorOf(BuildContext context) {
  return formFactorFor(MediaQuery.sizeOf(context).width);
}

bool isCompact(BuildContext context) {
  return formFactorOf(context) == FormFactor.compact;
}
