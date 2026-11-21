import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'core.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await Store.load();
  final node = Node(store);
  await node.start();
  runApp(QuickDropApp(store, node));
}

class QuickDropApp extends StatelessWidget {
  const QuickDropApp(this.store, this.node, {super.key});
  final Store store;
  final Node node;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'QuickDrop',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: Colors.teal,
            brightness: Brightness.dark,
            useMaterial3: true),
        home: HomePage(store, node),
      );
}

// ───────────────────────── File actions ─────────────────────────
Future<void> openItem(Item i) async {
  final path = i.path;
  if (path == null) return;
  if (isMobile) {
    await OpenFilex.open(path);
  } else if (Platform.isWindows) {
    await Process.run('cmd', ['/c', 'start', '', path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [path]);
  } else {
    await Process.run('xdg-open', [path]);
  }
}

Future<void> showInFolder(Item i) async {
  final path = i.path;
  if (path == null) return;
  if (Platform.isWindows) {
    await Process.run('explorer.exe', ['/select,', path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', ['-R', path]);
  } else {
    await Process.run('xdg-open', [p.dirname(path)]);
  }
}

Future<void> saveAs(Item i) async {
  final src = File(i.path!);
  if (isMobile) {
    await FilePicker.platform
        .saveFile(fileName: i.name, bytes: await src.readAsBytes());
  } else {
    final out = await FilePicker.platform.saveFile(fileName: i.name);
    if (out != null) await src.copy(out);
  }
}

// ───────────────────────── Home ─────────────────────────
class HomePage extends StatefulWidget {
  const HomePage(this.store, this.node, {super.key});
  final Store store;
  final Node node;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Future<String?> _ipFuture = Address.localIp();
  final _addr = TextEditingController();
  final _pin = TextEditingController();
  final _text = TextEditingController();
  String? _peerIp, _peerName;
  bool _connecting = false, _dragging = false;
  int _tab = 0;

  Store get store => widget.store;
  Node get node => widget.node;

  @override
  void initState() {
    super.initState();
    store.askAccept = _ask;
  }

  void _msg(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  String _err(Object e) => e.toString().replaceFirst('Exception: ', '');

  Future<bool> _ask(String from, String name, int size) async {
    if (!mounted) return true;
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('$from ต้องการส่ง'),
        content: Text('$name (${fmtSize(size)})'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('ปฏิเสธ')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true), child: const Text('รับ')),
        ],
      ),
    );
    return r ?? false;
  }

  Future<void> _connect([String? input]) async {
    final ip = Address.decode(input ?? _addr.text);
    if (ip == null) {
      _msg('รูปแบบ Address ไม่ถูกต้อง');
      return;
    }
    setState(() => _connecting = true);
    try {
      final name = await node.ping(ip, _pin.text);
      store.rememberPeer(ip);
      setState(() {
        _peerIp = ip;
        _peerName = name;
      });
      _msg('เชื่อมต่อกับ $name แล้ว');
    } catch (e) {
      setState(() => _peerIp = null);
      _msg(_err(e));
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _scan() async {
    final v = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScanPage()));
    if (v != null) {
      _addr.text = v.replaceFirst('qd://', '');
      _connect(v);
    }
  }

  bool _needPeer() {
    if (_peerIp == null) {
      _msg('กรอก Address ปลายทางแล้วกด "เชื่อมต่อ" ก่อน');
      return false;
    }
    return true;
  }

  Future<void> _sendFiles(List<File> files) async {
    if (files.isEmpty || !_needPeer()) return;
    try {
      await node.sendFiles(_peerIp!, _pin.text, files);
      _msg('ส่งสำเร็จ ${files.length} รายการ');
    } catch (e) {
      _msg('ส่งไม่สำเร็จ: ${_err(e)}');
    }
  }

  List<File> _toFiles(Iterable<String?> paths) =>
      paths.whereType<String>().map((e) => File(e)).toList();

  Future<void> _pickFiles() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (r != null) await _sendFiles(_toFiles(r.files.map((f) => f.path)));
  }

  Future<void> _pickImages() async {
    if (isMobile) {
      final xs = await ImagePicker().pickMultipleMedia();
      await _sendFiles(_toFiles(xs.map((x) => x.path)));
    } else {
      final r = await FilePicker.platform
          .pickFiles(allowMultiple: true, type: FileType.media);
      if (r != null) await _sendFiles(_toFiles(r.files.map((f) => f.path)));
    }
  }

  Future<void> _camera() async {
    final x = await ImagePicker().pickImage(source: ImageSource.camera);
    if (x != null) await _sendFiles([File(x.path)]);
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData('text/plain');
    if (d?.text != null) setState(() => _text.text = d!.text!);
  }

  Future<void> _sendText() async {
    if (_text.text.isEmpty || !_needPeer()) return;
    try {
      await node.sendText(_peerIp!, _pin.text, _text.text);
      _text.clear();
      _msg('ส่งข้อความสำเร็จ');
    } catch (e) {
      _msg('ส่งไม่สำเร็จ: ${_err(e)}');
    }
  }

  // ── cards ──
  Widget _myCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FutureBuilder<String?>(
            future: _ipFuture,
            builder: (c, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final ip = snap.data;
              if (ip == null) {
                return const Text('ไม่พบเครือข่าย — เชื่อมต่อ Wi-Fi/LAN ก่อน');
              }
              final code = Address.pretty(ip);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(6),
                      child: QrImageView(data: 'qd://$ip', size: 110),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Address ของเครื่องนี้',
                              style: Theme.of(c).textTheme.labelLarge),
                          SelectableText(code,
                              style: Theme.of(c).textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'monospace',
                                  letterSpacing: 2)),
                          Text('$ip • ${store.deviceName}',
                              style: Theme.of(c).textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ]),
                  if (node.bindError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('เปิดพอร์ตรับข้อมูลไม่ได้: ${node.bindError}',
                          style: TextStyle(color: Theme.of(c).colorScheme.error)),
                    ),
                  Row(children: [
                    TextButton.icon(
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('คัดลอก'),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: code));
                        _msg('คัดลอก Address แล้ว');
                      },
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('รีเฟรช'),
                      onPressed: () => setState(() => _ipFuture = Address.localIp()),
                    ),
                  ]),
                ],
              );
            },
          ),
        ),
      );

  Widget _connectCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('ส่งไปยังเครื่อง', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _addr,
              decoration: InputDecoration(
                labelText: 'Address ปลายทาง (เช่น 1AB-C2DE หรือ 192.168.1.20)',
                border: const OutlineInputBorder(),
                suffixIcon: isMobile
                    ? IconButton(
                        icon: const Icon(Icons.qr_code_scanner), onPressed: _scan)
                    : null,
              ),
              onSubmitted: (_) => _connect(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _pin,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'PIN ของปลายทาง (ถ้ามี)',
                  border: OutlineInputBorder()),
            ),
            if (store.recent.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(spacing: 8, children: [
                  for (final ip in store.recent)
                    ActionChip(
                      label: Text(Address.pretty(ip)),
                      onPressed: () {
                        _addr.text = ip;
                        _connect(ip);
                      },
                    ),
                ]),
              ),
            const SizedBox(height: 8),
            Row(children: [
              FilledButton.icon(
                icon: _connecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.link),
                label: const Text('เชื่อมต่อ'),
                onPressed: _connecting ? null : _connect,
              ),
              const SizedBox(width: 12),
              if (_peerIp != null)
                Flexible(
                  child: Text('✓ $_peerName ($_peerIp)',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.green)),
                ),
            ]),
          ]),
        ),
      );

  Widget _sendCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('เลือกข้อมูลที่จะส่ง', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonalIcon(
                  icon: const Icon(Icons.insert_drive_file),
                  label: const Text('ไฟล์'),
                  onPressed: _pickFiles),
              FilledButton.tonalIcon(
                  icon: const Icon(Icons.photo_library),
                  label: const Text('รูปภาพ/วิดีโอ'),
                  onPressed: _pickImages),
              if (isMobile)
                FilledButton.tonalIcon(
                    icon: const Icon(Icons.photo_camera),
                    label: const Text('ถ่ายรูป'),
                    onPressed: _camera),
            ]),
            if (!isMobile)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('หรือลากไฟล์/รูปมาวางที่หน้าต่างโปรแกรมเพื่อส่งทันที',
                    style: TextStyle(fontSize: 12)),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                  labelText: 'ข้อความ / ลิงก์ / โค้ด',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Row(children: [
              OutlinedButton.icon(
                  icon: const Icon(Icons.content_paste),
                  label: const Text('วาง'),
                  onPressed: _paste),
              const SizedBox(width: 8),
              FilledButton.icon(
                  icon: const Icon(Icons.send),
                  label: const Text('ส่งข้อความ'),
                  onPressed: _sendText),
            ]),
            ValueListenableBuilder<double?>(
              valueListenable: store.progress,
              builder: (c, v, _) => v == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Column(children: [
                        LinearProgressIndicator(value: v),
                        const SizedBox(height: 4),
                        Text('กำลังส่ง ${(v * 100).toInt()}%'),
                      ]),
                    ),
            ),
          ]),
        ),
      );

  Future<void> _settings() async {
    final name = TextEditingController(text: store.deviceName);
    final pin = TextEditingController(text: store.pin);
    var auto = store.autoReceive;
    var dir = store.receiveDir;
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setS) => AlertDialog(
          title: const Text('ตั้งค่า'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'ชื่อเครื่อง')),
              TextField(
                  controller: pin,
                  decoration: const InputDecoration(
                      labelText: 'PIN สำหรับรับข้อมูล (เว้นว่าง = ไม่ใช้)')),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('รับอัตโนมัติ (ไม่ต้องกดยืนยัน)'),
                value: auto,
                onChanged: (v) => setS(() => auto = v),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('โฟลเดอร์ปลายทาง'),
                subtitle: Text(dir),
                trailing: isMobile
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.folder_open),
                        onPressed: () async {
                          final d = await FilePicker.platform.getDirectoryPath();
                          if (d != null) setS(() => dir = d);
                        },
                      ),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c), child: const Text('ยกเลิก')),
            FilledButton(
              onPressed: () {
                store.updateSettings(
                    name: name.text, pin: pin.text, auto: auto, dir: dir);
                Navigator.pop(c);
              },
              child: const Text('บันทึก'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('ล้างประวัติทั้งหมด?'),
        content: const Text('จะลบเฉพาะรายการในโปรแกรม ไม่ลบไฟล์ในโฟลเดอร์'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('ยกเลิก')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true), child: const Text('ล้าง')),
        ],
      ),
    );
    if (ok == true) store.clearAll();
  }

  @override
  Widget build(BuildContext context) {
    final sendPane = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _myCard(),
        const SizedBox(height: 12),
        _connectCard(),
        const SizedBox(height: 12),
        _sendCard(),
      ],
    );
    final inboxPane = Padding(
      padding: const EdgeInsets.all(16),
      child: InboxView(store),
    );

    Widget body = LayoutBuilder(builder: (c, box) {
      if (box.maxWidth >= 900) {
        return Row(children: [
          SizedBox(width: 440, child: sendPane),
          Expanded(child: inboxPane),
        ]);
      }
      return _tab == 0 ? sendPane : inboxPane;
    });

    if (!isMobile) {
      body = DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (d) {
          setState(() => _dragging = false);
          _sendFiles(d.files.map((x) => File(x.path)).toList());
        },
        child: Container(
          decoration: BoxDecoration(
            border: _dragging
                ? Border.all(color: Theme.of(context).colorScheme.primary, width: 3)
                : null,
          ),
          child: body,
        ),
      );
    }

    return LayoutBuilder(builder: (c, box) {
      final wide = box.maxWidth >= 900;
      return Scaffold(
        appBar: AppBar(
          title: const Text('QuickDrop'),
          actions: [
            IconButton(
                tooltip: 'ล้างประวัติ',
                icon: const Icon(Icons.delete_sweep),
                onPressed: _clear),
            IconButton(
                tooltip: 'ตั้งค่า',
                icon: const Icon(Icons.settings),
                onPressed: _settings),
          ],
        ),
        body: SafeArea(child: body),
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: (i) => setState(() => _tab = i),
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.send), label: 'ส่ง'),
                  NavigationDestination(icon: Icon(Icons.inbox), label: 'กล่องรับ'),
                ],
              ),
      );
    });
  }
}

// ───────────────────────── QR scanner ─────────────────────────
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  bool _done = false;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('สแกน QR จากหน้าจอคอมพิวเตอร์')),
        body: MobileScanner(
          onDetect: (cap) {
            final v = cap.barcodes.firstOrNull?.rawValue;
            if (v != null && !_done) {
              _done = true;
              Navigator.pop(context, v);
            }
          },
        ),
      );
}

// ───────────────────────── Inbox ─────────────────────────
class InboxView extends StatelessWidget {
  const InboxView(this.store, {super.key});
  final Store store;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          List<Item> inc(Kind k) =>
              store.items.where((i) => i.incoming && i.kind == k).toList();
          final sent = store.items.where((i) => !i.incoming).toList();
          return DefaultTabController(
            length: 4,
            child: Column(children: [
              TabBar(tabs: [
                Tab(text: 'ไฟล์ (${inc(Kind.file).length})'),
                Tab(text: 'รูปภาพ (${inc(Kind.image).length})'),
                Tab(text: 'ข้อความ (${inc(Kind.text).length})'),
                Tab(text: 'ส่งแล้ว (${sent.length})'),
              ]),
              Expanded(
                child: TabBarView(children: [
                  _FileList(store, inc(Kind.file)),
                  _Gallery(store, inc(Kind.image)),
                  _TextList(store, inc(Kind.text)),
                  _SentList(store, sent),
                ]),
              ),
            ]),
          );
        },
      );
}

Widget _empty() => const Center(child: Text('ยังไม่มีรายการ'));

class _ItemMenu extends StatelessWidget {
  const _ItemMenu(this.store, this.item);
  final Store store;
  final Item item;
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        onSelected: (v) {
          switch (v) {
            case 'open':
              openItem(item);
            case 'folder':
              showInFolder(item);
            case 'save':
              saveAs(item);
            case 'del':
              store.remove(item, deleteFile: true);
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'open', child: Text('เปิดไฟล์')),
          if (!isMobile)
            const PopupMenuItem(value: 'folder', child: Text('เปิดโฟลเดอร์')),
          const PopupMenuItem(value: 'save', child: Text('บันทึกเป็น…')),
          const PopupMenuItem(value: 'del', child: Text('ลบ')),
        ],
      );
}

class _FileList extends StatelessWidget {
  const _FileList(this.store, this.items);
  final Store store;
  final List<Item> items;
  @override
  Widget build(BuildContext context) => items.isEmpty
      ? _empty()
      : ListView(children: [
          for (final i in items)
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: Text(i.name, overflow: TextOverflow.ellipsis),
              subtitle: Text('${fmtSize(i.size)} • ${fmtTime(i.time)} • จาก ${i.peer}'),
              onTap: () => openItem(i),
              trailing: _ItemMenu(store, i),
            ),
        ]);
}

class _Gallery extends StatelessWidget {
  const _Gallery(this.store, this.items);
  final Store store;
  final List<Item> items;

  void _view(BuildContext context, Item i) {
    if (!isImagePath(i.path!)) {
      openItem(i);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (c) => Dialog(
        child: Stack(children: [
          InteractiveViewer(child: Image.file(File(i.path!))),
          Positioned(
              right: 4,
              top: 4,
              child: IconButton(
                  icon: const Icon(Icons.close), onPressed: () => Navigator.pop(c))),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => items.isEmpty
      ? _empty()
      : GridView.extent(
          maxCrossAxisExtent: 150,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [
            for (final i in items)
              GestureDetector(
                onTap: () => _view(context, i),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(fit: StackFit.expand, children: [
                    isImagePath(i.path!)
                        ? Image.file(File(i.path!),
                            fit: BoxFit.cover,
                            cacheWidth: 300,
                            errorBuilder: (_, __, ___) =>
                                const Center(child: Icon(Icons.broken_image)))
                        : const ColoredBox(
                            color: Colors.black26,
                            child: Center(child: Icon(Icons.videocam, size: 40))),
                    Positioned(right: 0, top: 0, child: _ItemMenu(store, i)),
                  ]),
                ),
              ),
          ],
        );
}

class _TextList extends StatelessWidget {
  const _TextList(this.store, this.items);
  final Store store;
  final List<Item> items;

  Uri? _link(String t) {
    final s = t.trim();
    if (!RegExp(r'^https?://\S+$').hasMatch(s)) return null;
    return Uri.tryParse(s);
  }

  @override
  Widget build(BuildContext context) => items.isEmpty
      ? _empty()
      : ListView(children: [
          for (final i in items)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SelectableText(i.text ?? '', maxLines: 6),
                  const SizedBox(height: 4),
                  Text('${fmtTime(i.time)} • จาก ${i.peer}',
                      style: Theme.of(context).textTheme.bodySmall),
                  Row(children: [
                    TextButton.icon(
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy'),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: i.text ?? ''));
                        ScaffoldMessenger.of(context)
                            .showSnackBar(const SnackBar(content: Text('คัดลอกแล้ว')));
                      },
                    ),
                    if (_link(i.text ?? '') != null)
                      TextButton.icon(
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: const Text('เปิดลิงก์'),
                        onPressed: () => launchUrl(_link(i.text!)!,
                            mode: LaunchMode.externalApplication),
                      ),
                    const Spacer(),
                    IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => store.remove(i)),
                  ]),
                ]),
              ),
            ),
        ]);
}

class _SentList extends StatelessWidget {
  const _SentList(this.store, this.items);
  final Store store;
  final List<Item> items;
  @override
  Widget build(BuildContext context) => items.isEmpty
      ? _empty()
      : ListView(children: [
          for (final i in items)
            ListTile(
              leading: Icon(i.kind == Kind.text
                  ? Icons.text_snippet
                  : i.kind == Kind.image
                      ? Icons.image
                      : Icons.insert_drive_file),
              title: Text(
                  i.kind == Kind.text ? (i.text ?? '') : i.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              subtitle: Text('ส่งไป ${i.peer} • ${fmtTime(i.time)} • ✓ สำเร็จ'),
              trailing: IconButton(
                  icon: const Icon(Icons.close), onPressed: () => store.remove(i)),
            ),
        ]);
}
