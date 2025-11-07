import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/html.dart' as html;
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '特殊聊天室（三栏布局）',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const ChatPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  WebSocketChannel? _ch;
  SharedPreferences? _prefs;

  // 身份 & 状态
  int? myId;
  bool isHost = false;
  bool running = false;
  bool waitingOpening = false;
  bool hostOpeningUsed = false;
  int? speakingId;
  int round = 1;
  List<int> order = [];

  // 消息 & 控件
  final List<Map<String, dynamic>> messages = [];
  final TextEditingController _ctrl = TextEditingController();
  final TextEditingController _openingCtrl = TextEditingController();
  final ScrollController _scroll = ScrollController();

  // 服务器地址（由左栏端口切换）
  String wsAddress = 'ws://localhost:8080';

  // 左侧：历史端口
  List<int> recentPorts = [];
  static const _recentPortsKey = 'recentPorts';

  // 头像（已处理的 256x256 圆形透明 PNG）
  Uint8List? _avatarBytes;
  static const _avatarKey = 'avatarB64';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadRecentPorts();
    await _loadAvatar();
    _connect();
  }

  Future<void> _loadRecentPorts() async {
    final list = _prefs?.getStringList(_recentPortsKey) ?? [];
    final parsed = <int>[];
    for (final s in list) {
      final p = int.tryParse(s);
      if (p != null && p > 0 && p <= 65535) parsed.add(p);
    }
    if (!parsed.contains(8080)) parsed.insert(0, 8080);
    final seen = <int>{};
    recentPorts = parsed.where((e) => seen.add(e)).toList();
    setState(() {});
  }

  Future<void> _saveRecentPorts() async {
    final strList = recentPorts.map((e) => e.toString()).toList();
    await _prefs?.setStringList(_recentPortsKey, strList);
  }

  Future<void> _loadAvatar() async {
    final b64 = _prefs?.getString(_avatarKey);
    if (b64 != null && b64.isNotEmpty) {
      try {
        _avatarBytes = base64Decode(b64);
        setState(() {});
      } catch (_) {}
    }
  }

  Future<void> _saveAvatar(Uint8List bytes) async {
    await _prefs?.setString(_avatarKey, base64Encode(bytes));
  }

  /// 选择本机图片 -> 居中裁剪正方形 -> 缩放到 256 -> 圆形透明裁剪 -> PNG
  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    if (file.bytes == null || file.bytes!.isEmpty) return;

    try {
      final processed = _processAvatarToCirclePng(file.bytes!, 256);
      _avatarBytes = processed;
      await _saveAvatar(_avatarBytes!);
      setState(() {});
    } catch (e) {
      // 兜底：处理失败则直接用原图
      _avatarBytes = file.bytes!;
      await _saveAvatar(_avatarBytes!);
      setState(() {});
    }
  }

  /// 使用 image v4 管道裁剪成圆形透明 PNG（不再逐像素操作）
  Uint8List _processAvatarToCirclePng(Uint8List rawBytes, int size) {
    final decoded = img.decodeImage(rawBytes);
    if (decoded == null) {
      throw Exception('无法解码图片');
    }

    // 居中裁剪为正方形
    final minSide = decoded.width < decoded.height ? decoded.width : decoded.height;
    final x0 = (decoded.width - minSide) ~/ 2;
    final y0 = (decoded.height - minSide) ~/ 2;
    final square = img.copyCrop(decoded, x: x0, y: y0, width: minSide, height: minSide);

    // 缩放到目标尺寸
    final resized = img.copyResize(
      square,
      width: size,
      height: size,
      interpolation: img.Interpolation.cubic,
    );

    // 圆形透明裁剪（外部像素自动透明）
    final circle = img.copyCropCircle(
      resized,
      centerX: size ~/ 2,
      centerY: size ~/ 2,
      radius: size ~/ 2,
    );

    return Uint8List.fromList(img.encodePng(circle, level: 6));
  }

  Future<void> _addPort(int port, {bool connectNow = true}) async {
    if (port <= 0 || port > 65535) return;
    if (!recentPorts.contains(port)) {
      recentPorts.add(port);
      await _saveRecentPorts();
    }
    if (connectNow) {
      _selectPort(port);
    } else {
      setState(() {});
    }
  }

  void _selectPort(int port) {
    final isSecure = wsAddress.startsWith('wss://');
    final scheme = isSecure ? 'wss' : 'ws';
    wsAddress = '$scheme://localhost:$port';
    _ch?.sink.close();
    _connect();
    setState(() {});
  }

  void _connect() {
    try {
      final uri = Uri.parse(wsAddress);
      _ch = kIsWeb ? html.HtmlWebSocketChannel.connect(uri) : IOWebSocketChannel.connect(uri);

      final saved = _prefs?.getInt('playerId');
      _ch!.sink.add(jsonEncode({'type': 'restore', 'savedId': saved}));

      _ch!.stream.listen((data) {
        final map = jsonDecode(data);
        switch (map['type']) {
          case 'welcome':
            setState(() {
              myId = map['playerId'] as int;
              isHost = (map['isHost'] == true);
            });
            _prefs?.setInt('playerId', myId!);
            break;
          case 'state':
            setState(() {
              running = map['running'] == true;
              speakingId = map['speakingId'];
              round = (map['round'] ?? 1) as int;
              order = (map['order'] as List).map((e) => e as int).toList();
              hostOpeningUsed = map['hostOpeningUsed'] == true;
              waitingOpening = map['waitingOpening'] == true;
            });
            break;
          case 'system':
          case 'chat':
          case 'verdict':
          case 'opening':
            setState(() => messages.add(Map<String, dynamic>.from(map)));
            _scrollToBottom();
            break;
        }
      }, onDone: _scheduleReconnect, onError: (_) => _scheduleReconnect());
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted) return;
      _connect();
    });
  }

  bool get canSpeakAudience =>
      running && !waitingOpening && myId != null && !isHost && speakingId == myId;

  void _sendChat() {
    final txt = _ctrl.text.trim();
    if (txt.isEmpty || !canSpeakAudience) return;
    _ch?.sink.add(jsonEncode({'type': 'chat', 'text': txt}));
    _ctrl.clear();
  }

  void _hostAction(String action, {String? verdict}) {
    if (!isHost) return;
    final p = {'type': 'hostControl', 'action': action};
    if (verdict != null) p['verdict'] = verdict;
    _ch?.sink.add(jsonEncode(p));
  }

  void _sendOpening() {
    if (!isHost || !running || !waitingOpening || hostOpeningUsed) return;
    final txt = _openingCtrl.text.trim();
    if (txt.isEmpty) return;
    _ch?.sink.add(jsonEncode({'type': 'hostControl', 'action': 'opening', 'text': txt}));
    _openingCtrl.clear();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent + 100,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _ch?.sink.close();
    _ctrl.dispose();
    _openingCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ====== 左侧栏：房间端口 + 左下角个人区块 ======
  Widget _buildLeftSidebar() {
    final roleLabel = isHost ? '主持人' : (speakingId == myId ? '发言人' : '观众');
    final roleColor = isHost
        ? Colors.orange
        : (speakingId == myId ? Colors.blue : Colors.grey);

    return Container(
      width: 220,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(right: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('房间端口', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                ...recentPorts.map((p) {
                  final selected = wsAddress.endsWith(':$p');
                  return ListTile(
                    dense: true,
                    leading: Icon(Icons.dns, color: selected ? Colors.blue : Colors.grey),
                    title: Text('$p'),
                    trailing: selected ? const Icon(Icons.check, color: Colors.blue) : null,
                    onTap: () => _selectPort(p),
                  );
                }),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.add),
                  title: const Text('添加端口'),
                  onTap: _showAddPortDialog,
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),
          Align(
            alignment: Alignment.bottomLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 头像 + 顶部 userID
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'ID: ${myId ?? "-"}',
                      style: const TextStyle(fontSize: 12, color: Colors.black87),
                    ),
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: _pickAvatar, // 点击选择头像
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.grey.shade300),
                          color: Colors.white, // 默认白色底
                          image: _avatarBytes == null
                              ? null
                              : DecorationImage(
                                  fit: BoxFit.cover,
                                  image: MemoryImage(_avatarBytes!),
                                ),
                        ),
                        child: _avatarBytes == null
                            ? const Icon(Icons.person, color: Colors.grey)
                            : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 10),
                // 角色标签在头像右侧（用 withValues 替代 withOpacity）
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: roleColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: roleColor.withValues(alpha: 0.40)),
                  ),
                  child: Text(
                    roleLabel,
                    style: TextStyle(
                      color: roleColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showAddPortDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('加入新的房间端口'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '输入端口号 1-65535'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ElevatedButton(
            onPressed: () async {
              final port = int.tryParse(ctrl.text.trim());
              if (port != null && port > 0 && port <= 65535) {
                Navigator.pop(context);
                await _addPort(port, connectNow: true);
              }
            },
            child: const Text('加入'),
          ),
        ],
      ),
    );
  }

  // ====== 中间栏 ======
  Widget _buildCenterColumn() {
    final messageList = Expanded(
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: messages.length,
        itemBuilder: (_, i) => _tile(messages[i]),
      ),
    );

    final inputBar = Row(
      children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            enabled: canSpeakAudience,
            decoration: InputDecoration(
              hintText: canSpeakAudience
                  ? '轮到你，请发言…'
                  : (waitingOpening ? '等待主持人开场…' : '等待轮到你…'),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _sendChat(),
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(onPressed: canSpeakAudience ? _sendChat : null, child: const Text('发送')),
      ],
    );

    return Container(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(children: [
                Text('轮次：$round', style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 8),
                Icon(running ? Icons.play_circle_fill : Icons.pause_circle_filled,
                    color: running ? Colors.green : Colors.grey),
              ]),
              if (waitingOpening)
                const Text('等待主持人开场…', style: TextStyle(color: Colors.orange)),
            ],
          ),
          const Divider(height: 16),
          messageList,
          inputBar,
        ],
      ),
    );
  }

  // ====== 右侧栏：发言顺序（高亮） + 主持控制 ======
  Widget _buildRightColumn() {
    final progressCard = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('顺序（含主持人）：', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _buildOrderChips(),
          const SizedBox(height: 10),
          Text(
            '当前发言：${speakingId ?? (waitingOpening ? "（等待主持人开场）" : "-")}',
            style: const TextStyle(fontSize: 16),
          ),
        ],
      ),
    );

    final hostPanel = isHost
        ? Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(spacing: 8, runSpacing: 8, children: [
                  ElevatedButton.icon(
                    onPressed: () => _hostAction('start'),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start'),
                  ),
                  ElevatedButton.icon(
                    onPressed: () => _hostAction('stop'),
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  ),
                  ElevatedButton(
                      onPressed: () => _hostAction('verdict', verdict: 'Yes'),
                      child: const Text('Yes')),
                  ElevatedButton(
                      onPressed: () => _hostAction('verdict', verdict: 'No'),
                      child: const Text('No')),
                  ElevatedButton(
                      onPressed: () => _hostAction('verdict', verdict: 'Unknown'),
                      child: const Text('Unknown')),
                ]),
                const SizedBox(height: 8),
                if (running && waitingOpening && !hostOpeningUsed)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orange.shade100),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('开场发言（仅此一次）',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Row(children: [
                          Expanded(
                            child: TextField(
                              controller: _openingCtrl,
                              decoration: const InputDecoration(
                                hintText: '请输入开场内容…',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onSubmitted: (_) => _sendOpening(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(onPressed: _sendOpening, child: const Text('发表')),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: () => _hostAction('skipOpening'),
                            child: const Text('跳过'),
                          ),
                        ]),
                      ],
                    ),
                  ),
              ],
            ),
          )
        : const SizedBox.shrink();

    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(left: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            progressCard,
            hostPanel,
          ],
        ),
      ),
    );
  }

  // 高亮顺序 Chips
  Widget _buildOrderChips() {
    if (order.isEmpty) {
      return const Text('-', style: TextStyle(color: Colors.black54));
    }
    final children = <Widget>[];
    for (int i = 0; i < order.length; i++) {
      final id = order[i];
      final isCurrent = !waitingOpening && (speakingId == id);
      final isHostId = (id == 1);

      final bg = isCurrent ? Colors.blue.shade600 : Colors.grey.shade200;
      final fg = isCurrent ? Colors.white : Colors.black87;
      final borderColor = isCurrent ? Colors.blue.shade700 : Colors.grey.shade300;

      children.add(Container(
        margin: const EdgeInsets.only(right: 6, bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: borderColor),
        ),
        child: Text(
          '$id${isHostId ? " (主持)" : ""}',
          style: TextStyle(
            color: fg,
            fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ));

      if (i != order.length - 1) {
        children.add(Padding(
          padding: const EdgeInsets.only(right: 6, bottom: 6),
          child: Text('→', style: TextStyle(color: Colors.grey.shade600)),
        ));
      }
    }
    return Wrap(children: children);
  }

  // 消息项
  Widget _tile(Map<String, dynamic> m) {
    switch (m['type']) {
      case 'system':
        return ListTile(
          dense: true,
          leading: const Icon(Icons.info, color: Colors.grey),
          title: Text('[系统] ${m['text']}', style: const TextStyle(color: Colors.grey)),
        );
      case 'opening':
        return ListTile(
          leading: const Icon(Icons.mic),
          title: Text('主持人开场：${m['text']}'),
        );
      case 'chat':
        return ListTile(
          leading: const Icon(Icons.person),
          title: Text('玩家 ${m['from']}：${m['text']}'),
        );
      case 'verdict':
        return ListTile(
          leading: const Icon(Icons.gavel),
          title: Text('主持人判定 → 玩家 ${m['to']} : ${m['verdict']}'),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('特殊聊天室（三栏）')),
      body: Row(
        children: [
          _buildLeftSidebar(),
          Expanded(child: _buildCenterColumn()),
          _buildRightColumn(),
        ],
      ),
    );
  }
}
