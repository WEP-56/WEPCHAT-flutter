import 'dart:convert';
import 'dart:typed_data';

/// 仅使用 ZIP 的 store 方法，避免引入体积较大的压缩依赖。
/// 生成的文件符合 ZIP 规范，可由常见解压工具打开；备份内容不加密。
class ZipArchive {
  final List<int> _bytes = <int>[];
  final List<_Entry> _entries = <_Entry>[];

  void addText(String name, String value) => addBytes(name, utf8.encode(value));

  void addBytes(String name, List<int> data) {
    if (name.trim().isEmpty || name.contains('..')) {
      throw ArgumentError.value(name, 'name', 'ZIP 条目名称无效');
    }
    final int offset = _bytes.length;
    final List<int> safe = List<int>.from(data);
    final int crc = _crc32(safe);
    _writeLocal(name, safe, crc);
    _entries.add(_Entry(name, safe.length, crc, offset));
  }

  Uint8List build() {
    final int centralOffset = _bytes.length;
    for (final _Entry entry in _entries) {
      _writeCentral(entry);
    }
    final int centralSize = _bytes.length - centralOffset;
    _write16(0x06054b50);
    _write16(0);
    _write16(0);
    _write16(_entries.length);
    _write16(_entries.length);
    _write32(centralSize);
    _write32(centralOffset);
    _write16(0);
    return Uint8List.fromList(_bytes);
  }

  /// 读取本实现生成的 store ZIP 条目（恢复备份使用）。
  static Map<String, Uint8List> extract(Uint8List bytes) {
    final Map<String, Uint8List> out = <String, Uint8List>{};
    int offset = 0;
    while (offset + 30 <= bytes.length) {
      final int sig = _read32(bytes, offset);
      if (sig != 0x04034b50) break;
      final int nameLen = _read16(bytes, offset + 26);
      final int extraLen = _read16(bytes, offset + 28);
      final int size = _read32(bytes, offset + 18);
      final int nameStart = offset + 30;
      final String name = utf8.decode(
        bytes.sublist(nameStart, nameStart + nameLen),
      );
      final int dataStart = nameStart + nameLen + extraLen;
      out[name] = Uint8List.fromList(
        bytes.sublist(dataStart, dataStart + size),
      );
      offset = dataStart + size;
    }
    return out;
  }

  static int _read16(Uint8List b, int i) => b[i] | (b[i + 1] << 8);
  static int _read32(Uint8List b, int i) =>
      _read16(b, i) | (_read16(b, i + 2) << 16);

  void _writeLocal(String name, List<int> data, int crc) {
    final List<int> n = utf8.encode(name);
    _write32(0x04034b50);
    _write16(20);
    _write16(0);
    _write16(0);
    _write16(0);
    _write16(0);
    _write32(crc);
    _write32(data.length);
    _write32(data.length);
    _write16(n.length);
    _write16(0);
    _bytes.addAll(n);
    _bytes.addAll(data);
  }

  void _writeCentral(_Entry e) {
    final List<int> n = utf8.encode(e.name);
    _write32(0x02014b50);
    _write16(20);
    _write16(20);
    _write16(0);
    _write16(0);
    _write16(0);
    _write16(0);
    _write32(e.crc);
    _write32(e.size);
    _write32(e.size);
    _write16(n.length);
    _write16(0);
    _write16(0);
    _write16(0);
    _write16(0);
    _write32(0);
    _write32(e.offset);
    _bytes.addAll(n);
  }

  void _write16(int value) {
    _bytes.add(value & 0xff);
    _bytes.add((value >> 8) & 0xff);
  }

  void _write32(int value) {
    _write16(value & 0xffff);
    _write16((value >> 16) & 0xffff);
  }

  static int _crc32(List<int> data) {
    int crc = 0xffffffff;
    for (final int b in data) {
      crc ^= b;
      for (int i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    return crc ^ 0xffffffff;
  }
}

class _Entry {
  const _Entry(this.name, this.size, this.crc, this.offset);
  final String name;
  final int size;
  final int crc;
  final int offset;
}
