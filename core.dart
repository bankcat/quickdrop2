import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const kPort = 53317;
bool get isMobile => Platform.isAndroid || Platform.isIOS;

enum Kind { file, image, text }

const _imgExt = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic'};
const _vidExt = {'.mp4', '.mov', '.mkv', '.avi', '.webm'};
bool isImagePath(String f) => _imgExt.contains(p.extension(f).toLowerCase());
bool isMediaPath(String f) {
  final e = p.extension(f).toLowerCase();
  return _imgExt.contains(e) || _vidExt.contains(e);
}

String fmtSize(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1048576).toStringAsFixed(1)} MB';
  return '${(b / 1073741824).toStringAsFixed(2)} GB';
}

String fmtTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.day)}/${two(t.month)} ${two(t.hour)}:${two(t.minute)}';
}

// ───────────────────────── Address ─────────────────────────
/// Address = IPv4 (32 bit) แปลงเป็นเลขฐาน 36 ยาว 7 ตัว เช่น 1A2-B3CD
/// พอร์ตคงที่ จึงถอดกลับเป็น IP ได้ทันทีโดยไม่ต้องมีเซิร์ฟเวอร์กลาง
class Address {
  static String encode(String ip) {
    final n = ip.split('.').fold<int>(0, (a, b) => a * 256 + int.parse(b));
    return n.toRadixString(36).toUpperCase().padLeft(7, '0');
  }

  static String pretty(String ip) {
    final c = encode(ip);
    return '${c.substring(0, 3)}-${c.substring(3)}';
  }

  /// รับได้ทั้งรหัส (มี/ไม่มีขีด), IP ตรง ๆ, หรือค่าจาก QR (qd://IP)
  static String? decode(String input) {
    var s = input.trim().replaceFirst('qd://', '');
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(s)) return s;
    s = s.replaceAll(RegExp(r'[\s-]'), '');
    if (!RegExp(r'^[0-9a-zA-Z]{6,7}$').hasMatch(s)) return null;
    final n = int.tryParse(s, radix: 36);
    if (n == null || n > 0xFFFFFFFF) return null;
    return [24, 16, 8, 0].map((sh) => (n >> sh) & 255).join('.');
  }

  static Future<String?> localIp() async {
    final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
    String? best;
    var bestScore = -1;
    for (final i in ifs) {
      final n = i.name.toLowerCase();
      if (['vethernet', 'virtualbox', 'vmware', 'docker', 'wsl', 'vbox']
          .any(n.contains)) {
        continue;
      }
      for (final a in i.addresses) {
        final ip = a.address;
        if (a.isLoopback || ip.startsWith('169.254')) continue;
        var s = 0;
        if (ip.startsWith('192.168.')) {
          s = 3;
        } else if (ip.startsWith('10.')) {
          s = 2;
        } else if (RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip)) {
          s = 1;
        }
        if (s > bestScore) {
          best = ip;
          bestScore = s;
        }
      }
    }
    return best;
  }
}

// ───────────────────────── Model / Store ─────────────────────────
class Item {
  Item({
    required this.kind,
    required this.name,
    this.path,
    this.text,
    this.size = 0,
    DateTime? time,
    this.peer = '',
    required this.incoming,
  }) : time = time ?? DateTime.now();

  final Kind kind;
  final String name;
  final String? path;
  final String? text;
  final int size;
  final DateTime time;
  final String peer;
  final bool incoming;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'name': name,
        'path': path,
        'text': text,
        'size': size,
        'time': time.toIso8601String(),
        'peer': peer,
        'incoming': incoming,
      };

  factory Item.fromJson(Map<String, dynamic> j) => Item(
        kind: Kind.values.byName(j['kind']),
        name: j['name'],
        path: j['path'],
        text: j['text'],
        size: j['size'] ?? 0,
        time: DateTime.parse(j['time']),
        peer: j['peer'] ?? '',
        incoming: j['incoming'] ?? true,
      );
}

class Store extends ChangeNotifier {
  Store._(this._prefs);
  final SharedPreferences _prefs;

  List<Item> items = [];
  List<String> recent = [];
  String deviceName = '';
  String pin = '';
  bool autoReceive = true;
  String receiveDir = '';
  final progress = ValueNotifier<double?>(null);

  /// ถูกเรียกเมื่อปิดโหมดรับอัตโนมัติ ให้ UI ถามผู้ใช้
  Future<bool> Function(String from, String name, int size)? askAccept;

  static Future<Store> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = Store._(prefs);
    s.deviceName = prefs.getString('name') ?? Platform.localHostname;
    s.pin = prefs.getString('pin') ?? '';
    s.autoReceive = prefs.getBool('auto') ?? true;
    s.recent = prefs.getStringList('recent') ?? [];
    s.receiveDir = prefs.getString('dir') ?? await _defaultDir();
    final raw = prefs.getString('items');
    if (raw != null) {
      try {
        s.items = (jsonDecode(raw) as List)
            .map((e) => Item.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }
    await Directory(s.receiveDir).create(recursive: true);
    return s;
  }

  static Future<String> _defaultDir() async {
    Directory? base;
    if (Platform.isAndroid) {
      base = await getExternalStorageDirectory();
    } else if (!isMobile) {
      base = await getDownloadsDirectory();
    }
    base ??= await getApplicationDocumentsDirectory();
    return p.join(base.path, 'QuickDrop');
  }

  void _persist() => _prefs.setString(
      'items', jsonEncode(items.take(500).map((e) => e.toJson()).toList()));

  void add(Item i) {
    items.insert(0, i);
    _persist();
    notifyListeners();
  }

  void remove(Item i, {bool deleteFile = false}) {
    items.remove(i);
    if (deleteFile && i.path != null && i.incoming) {
      try {
        File(i.path!).deleteSync();
      } catch (_) {}
    }
    _persist();
    notifyListeners();
  }

  void clearAll() {
    items.clear();
    _persist();
    notifyListeners();
  }

  void rememberPeer(String ip) {
    recent
      ..remove(ip)
      ..insert(0, ip);
    if (recent.length > 5) recent = recent.sublist(0, 5);
    _prefs.setStringList('recent', recent);
    notifyListeners();
  }

  void updateSettings({String? name, String? pin, bool? auto, String? dir}) {
    if (name != null && name.trim().isNotEmpty) {
      deviceName = name.trim();
      _prefs.setString('name', deviceName);
    }
    if (pin != null) {
      this.pin = pin;
      _prefs.setString('pin', pin);
    }
    if (auto != null) {
      autoReceive = auto;
      _prefs.setBool('auto', auto);
    }
    if (dir != null) {
      receiveDir = dir;
      _prefs.setString('dir', dir);
      Directory(dir).createSync(recursive: true);
    }
    notifyListeners();
  }
}

// ───────────────────────── Server + Client ─────────────────────────
class Node {
  Node(this.store);
  final Store store;
  HttpServer? _server;
  String? bindError;

  Future<void> start() async {
    try {
      _server =
          await HttpServer.bind(InternetAddress.anyIPv4, kPort, shared: true);
      _server!.listen(_handle, onError: (_) {});
    } catch (e) {
      bindError = '$e';
    }
  }

  String _hv(HttpHeaders h, String k) => Uri.decodeComponent(h.value(k) ?? '');

  Future<void> _handle(HttpRequest r) async {
    try {
      if (r.method == 'GET' && r.uri.path == '/info') {
        final ok = store.pin.isEmpty || _hv(r.headers, 'x-pin') == store.pin;
        r.response.headers.contentType = ContentType.json;
        r.response.write(jsonEncode(
            {'app': 'quickdrop', 'name': store.deviceName, 'pinOk': ok}));
        await r.response.close();
        return;
      }
      if (r.method == 'POST' && r.uri.path == '/send') {
        await _receive(r);
        return;
      }
      r.response.statusCode = 404;
      await r.response.close();
    } catch (_) {
      try {
        r.response.statusCode = 500;
        await r.response.close();
      } catch (_) {}
    }
  }

  Future<void> _receive(HttpRequest r) async {
    final h = r.headers;
    if (store.pin.isNotEmpty && _hv(h, 'x-pin') != store.pin) {
      r.response.statusCode = 401;
      await r.response.close();
      return;
    }
    final kind = h.value('x-kind') ?? 'file';
    final name = p.basename(_hv(h, 'x-name'));
    final from = _hv(h, 'x-from');
    if (!store.autoReceive) {
      final ok = await (store.askAccept?.call(
              from, kind == 'text' ? 'ข้อความ' : name, r.contentLength) ??
          Future.value(true));
      if (!ok) {
        r.response.statusCode = 403;
        await r.response.close();
        return;
      }
    }
    if (kind == 'text') {
      final text = await utf8.decoder.bind(r).join();
      store.add(Item(
          kind: Kind.text,
          name: 'ข้อความ',
          text: text,
          size: text.length,
          peer: from,
          incoming: true));
    } else {
      final dir = Directory(store.receiveDir)..createSync(recursive: true);
      final dest = _unique(dir.path, name.isEmpty ? 'file' : name);
      final sink = File(dest).openWrite();
      await sink.addStream(r);
      await sink.close();
      store.add(Item(
          kind: isMediaPath(dest) ? Kind.image : Kind.file,
          name: p.basename(dest),
          path: dest,
          size: File(dest).lengthSync(),
          peer: from,
          incoming: true));
    }
    r.response.write('ok');
    await r.response.close();
  }

  String _unique(String dir, String name) {
    var dest = p.join(dir, name);
    var n = 1;
    while (File(dest).existsSync()) {
      dest = p.join(dir, '${p.basenameWithoutExtension(name)} ($n)${p.extension(name)}');
      n++;
    }
    return dest;
  }

  /// ทดสอบการเชื่อมต่อ + ตรวจ PIN คืนชื่อเครื่องปลายทาง
  Future<String> ping(String ip, String pin) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await c.getUrl(Uri.parse('http://$ip:$kPort/info'));
      req.headers.set('x-pin', Uri.encodeComponent(pin));
      final res = await req.close().timeout(const Duration(seconds: 4));
      final j = jsonDecode(await res.transform(utf8.decoder).join());
      if (j['app'] != 'quickdrop') throw Exception('ไม่ใช่เครื่อง QuickDrop');
      if (j['pinOk'] != true) throw Exception('PIN ไม่ถูกต้อง');
      return j['name'] as String;
    } on SocketException {
      throw Exception('ติดต่อเครื่องปลายทางไม่ได้ (ตรวจว่าอยู่ Wi-Fi เดียวกัน/เปิดโปรแกรมอยู่/Firewall)');
    } on TimeoutException {
      throw Exception('หมดเวลาเชื่อมต่อ');
    } finally {
      c.close(force: true);
    }
  }

  Future<void> _post(String ip, String pin,
      {required String kind,
      required String name,
      required int length,
      required Stream<List<int>> body}) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await c.postUrl(Uri.parse('http://$ip:$kPort/send'));
      req.contentLength = length;
      req.headers
        ..set('x-kind', kind)
        ..set('x-name', Uri.encodeComponent(name))
        ..set('x-from', Uri.encodeComponent(store.deviceName))
        ..set('x-pin', Uri.encodeComponent(pin));
      await req.addStream(body);
      final res = await req.close();
      await res.drain();
      if (res.statusCode == 403) throw Exception('ปลายทางปฏิเสธการรับ');
      if (res.statusCode != 200) {
        throw Exception('ส่งไม่สำเร็จ (${res.statusCode})');
      }
    } finally {
      c.close(force: true);
    }
  }

  Future<void> sendFiles(String ip, String pin, List<File> files) async {
    final total = files.fold<int>(0, (a, f) => a + f.lengthSync());
    var done = 0;
    store.progress.value = 0;
    try {
      for (final f in files) {
        final len = await f.length();
        var sent = 0;
        final stream = f.openRead().map((chunk) {
          sent += chunk.length;
          store.progress.value = total == 0 ? 1 : (done + sent) / total;
          return chunk;
        });
        await _post(ip, pin,
            kind: 'file', name: p.basename(f.path), length: len, body: stream);
        done += len;
        store.add(Item(
            kind: isMediaPath(f.path) ? Kind.image : Kind.file,
            name: p.basename(f.path),
            path: f.path,
            size: len,
            peer: ip,
            incoming: false));
      }
    } finally {
      store.progress.value = null;
    }
  }

  Future<void> sendText(String ip, String pin, String text) async {
    final bytes = utf8.encode(text);
    await _post(ip, pin,
        kind: 'text', name: 'text', length: bytes.length, body: Stream.value(bytes));
    store.add(Item(
        kind: Kind.text,
        name: 'ข้อความ',
        text: text,
        size: text.length,
        peer: ip,
        incoming: false));
  }
}
