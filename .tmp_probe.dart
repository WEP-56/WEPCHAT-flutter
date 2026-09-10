import 'dart:io';
void main() {
  final p = Directory(r'C:\Users\14844\AppData\Local\Pub\Cache\hosted\pub.dev\mcp_dart-2.4.2');
  print(p.existsSync());
  try { print(p.listSync().map((e) => e.path).join('\n')); } catch (e) { print(e); }
}
