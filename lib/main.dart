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

  // 判定高亮
  bool awaitingVerdict = false;

  // —— 新增：计分 —— //
  final Map<int, int> scores = {};       // playerId -> total score
  int? lastQuestionUserId;               // 最近一条“顺序区提问”的玩家ID（用于打分目标）
  final Set<int> _scoredThisTurn = {};   // 可选：本题已打分的玩家，避免重复打分（简单去重）

  // 消息 & 控件
  final List<Map<String, dynamic>> messages = [];      // 顺序发言区：system/opening/chat/verdict
  final List<Map<String, dynamic>> freeMessages = [];  // 自由聊天区：freechat
  final TextEditingController _ctrlOrder = TextEditingController();
  final TextEditingController _ctrlFree  = TextEditingController();
  final TextEditingController _openingCtrl = TextEditingController();
  final ScrollController _scrollOrder = ScrollController();
  final ScrollController _scrollFree  = ScrollController();

  // 服务器地址（由左栏端口切换）
  String wsAddress = 'ws://localhost:8080';

  // 左侧：历史端口
  List<int> recentPorts = [];
  static const _recentPortsKey = 'recentPorts';

  // 本机头像（256x256 圆形透明 PNG）
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

  /// 选择本机图片 -> 裁剪正方形 -> 缩放 256 -> 圆形透明
  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image, withData: true, allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    if (file.bytes == null || file.bytes!.isEmpty) return;

    try {
      final processed = _processAvatarToCirclePng(file.bytes!, 256);
      _avatarBytes = processed;
      await _saveAvatar(_avatarBytes!);
      setState(() {});
    } catch (_) {
      _avatarBytes = file.bytes!;
      await _saveAvatar(_avatarBytes!);
      setState(() {});
    }
  }

  Uint8List _processAvatarToCirclePng(Uint8List rawBytes, int size) {
    final decoded = img.decodeImage(rawBytes);
    if (decoded == null) throw Exception('无法解码图片');
    final minSide = decoded.width < decoded.height ? decoded.width : decoded.height;
    final x0 = (decoded.width - minSide) ~/ 2;
    final y0 = (decoded.height - minSide) ~/ 2;
    final square = img.copyCrop(decoded, x: x0, y: y0, width: minSide, height: minSide);
    final resized = img.copyResize(square, width: size, height: size, interpolation: img.Interpolation.cubic);
    final circle = img.copyCropCircle(resized, centerX: size ~/ 2, centerY: size ~/ 2, radius: size ~/ 2);
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

          case 'bulkSync':
            setState(() {
              final List ord = map['ordered'] ?? [];
              final List free = map['free'] ?? [];
              messages
                ..clear()
                ..addAll(ord.map((e) => Map<String, dynamic>.from(e)));
              freeMessages
                ..clear()
                ..addAll(free.map((e) => Map<String, dynamic>.from(e)));

              // 兼容服务端同步历史积分
              scores.clear();
              final dynamic ss = map['scores'];
              if (ss is Map) {
                ss.forEach((k, v) {
                  final id = int.tryParse('$k');
                  final val = (v is num) ? v.toInt() : int.tryParse('$v');
                  if (id != null && val != null) scores[id] = val;
                });
              }

              // 恢复“最近提问者”为顺序区最后一条 chat 的 from（便于主持人掉线恢复后继续打分）
              for (int i = ord.length - 1; i >= 0; i--) {
                final m = ord[i] as Map<String, dynamic>;
                if (m['type'] == 'chat' && m['from'] is int) {
                  lastQuestionUserId = m['from'] as int;
                  break;
                }
              }
            });
            _scrollToEnd(_scrollOrder);
            _scrollToEnd(_scrollFree);
            break;

          case 'state':
            setState(() {
              running = map['running'] == true;
              waitingOpening = map['waitingOpening'] == true;
              hostOpeningUsed = map['hostOpeningUsed'] == true;
              speakingId = map['speakingId'];
              round = (map['round'] ?? 1) as int;
              order = (map['order'] as List).map((e) => e as int).toList();
              final av = map['awaitingVerdict'];
              awaitingVerdict = (av == true) || (av == 1) || (av == 'true');

              // 兼容服务端在 state 中携带 scores
              final dynamic ss = map['scores'];
              if (ss is Map) {
                scores.clear();
                ss.forEach((k, v) {
                  final id = int.tryParse('$k');
                  final val = (v is num) ? v.toInt() : int.tryParse('$v');
                  if (id != null && val != null) scores[id] = val;
                });
              }
            });
            break;

          case 'system':
          case 'chat':
          case 'verdict':
          case 'opening':
            setState(() {
              messages.add(Map<String, dynamic>.from(map));
              // 记录最近提问者：顺序区 chat 的 from
              if (map['type'] == 'chat' && map['from'] is int) {
                lastQuestionUserId = map['from'] as int;
                _scoredThisTurn.remove(lastQuestionUserId); // 新问题允许再次打分
              }
            });
            _scrollToEnd(_scrollOrder);
            break;

          case 'freechat':
            setState(() => freeMessages.add(Map<String, dynamic>.from(map)));
            _scrollToEnd(_scrollFree);
            break;

          case 'score': // 服务端广播的打分事件（推荐）
            setState(() {
              final to = map['to'];
              final delta = map['delta'];
              final total = map['total']; // 若服务端给总分，优先采用
              if (to is int) {
                if (total is num) {
                  scores[to] = total.toInt();
                } else if (delta is num) {
                  scores[to] = (scores[to] ?? 0) + delta.toInt();
                }
                // 一旦对该提问者打分，清理 pending（避免重复）
                if (lastQuestionUserId == to) {
                  _scoredThisTurn.add(to);
                }
              }
            });
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

  bool get canFreeChat =>
      myId != null && !isHost; // 自由区：主持人不能说，其他人随时可说

  void _sendOrderChat() {
    final txt = _ctrlOrder.text.trim();
    if (txt.isEmpty || !canSpeakAudience) return;
    _ch?.sink.add(jsonEncode({'type': 'chat', 'text': txt}));
    _ctrlOrder.clear();
  }

  void _sendFreeChat() {
    final txt = _ctrlFree.text.trim();
    if (txt.isEmpty || !canFreeChat) return;
    _ch?.sink.add(jsonEncode({'type': 'freechat', 'text': txt}));
    _ctrlFree.clear();
  }

  void _hostAction(String action, {String? verdict}) {
    if (!isHost) return;
    if (action == 'verdict') {
      setState(() { awaitingVerdict = false; });
    }
    final p = {'type': 'hostControl', 'action': action};
    if (verdict != null) p['verdict'] = verdict;
    _ch?.sink.add(jsonEncode(p));
  }

  // —— 新增：主持人打分 —— //
  void _hostScore(int delta) {
    if (!isHost) return;
    final to = lastQuestionUserId;
    if (to == null) return;
    if (_scoredThisTurn.contains(to)) return; // 已打过分则不重复

    // 本地先行乐观更新
    setState(() {
      scores[to] = (scores[to] ?? 0) + delta;
      _scoredThisTurn.add(to);
    });

    // 通知服务端
    final p = {'type': 'hostControl', 'action': 'score', 'to': to, 'delta': delta};
    _ch?.sink.add(jsonEncode(p));
  }

  void _sendOpening() {
    if (!isHost || !running || !waitingOpening || hostOpeningUsed) return;
    final txt = _openingCtrl.text.trim();
    if (txt.isEmpty) return;
    _ch?.sink.add(jsonEncode({'type': 'hostControl', 'action': 'opening', 'text': txt}));
    _openingCtrl.clear();
  }

  void _scrollToEnd(ScrollController c) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (c.hasClients) {
        c.animateTo(
          c.position.maxScrollExtent + 100,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _ch?.sink.close();
    _ctrlOrder.dispose();
    _ctrlFree.dispose();
    _openingCtrl.dispose();
    _scrollOrder.dispose();
    _scrollFree.dispose();
    super.dispose();
  }

  // ====== 左侧栏：房间端口 + 左下角个人区块 ======
  Widget _buildLeftSidebar() {
    final roleLabel = isHost ? '主持人' : (speakingId == myId ? '发言人' : '观众');
    final roleColor = isHost ? Colors.orange : (speakingId == myId ? Colors.blue : Colors.grey);

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
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('ID: ${myId ?? "-"}', style: const TextStyle(fontSize: 12, color: Colors.black87)),
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: _pickAvatar,
                      child: Container(
                        width: 56, height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.grey.shade300),
                          color: Colors.white,
                          image: _avatarBytes == null
                              ? null
                              : DecorationImage(fit: BoxFit.cover, image: MemoryImage(_avatarBytes!)),
                        ),
                        child: _avatarBytes == null ? const Icon(Icons.person, color: Colors.grey) : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: roleColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: roleColor.withValues(alpha: 0.40)),
                  ),
                  child: Text(roleLabel, style: TextStyle(color: roleColor, fontWeight: FontWeight.w600)),
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

  // ====== 中间栏：上“顺序发言区” + 下“自由聊天区” + （下方）积分展示 ======
  Widget _buildCenterColumn() {
    return Container(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          // 顶部状态行
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
          const SizedBox(height: 12),

          // —— 顺序发言区 ——（保持原逻辑）
          _buildOrderedChatPanel(),

          const SizedBox(height: 12),

          // —— 自由聊天区 ——（主持人不可发言，其他人随时可发言）
          _buildFreeChatPanel(),

          const SizedBox(height: 10),

          // —— 中心积分展示 ——（主持人看全体；玩家看自己）
          _buildScoreBoard(),
        ],
      ),
    );
  }

  // 顺序发言区（原逻辑）
  Widget _buildOrderedChatPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: SizedBox(
        height: 260,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Text('顺序发言区', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: _scrollOrder,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: messages.length,
                itemBuilder: (_, i) => _tile(messages[i]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrlOrder,
                      enabled: canSpeakAudience,
                      decoration: InputDecoration(
                        hintText: canSpeakAudience
                            ? '轮到你，请发言…'
                            : (waitingOpening ? '等待主持人开场…' : '等待轮到你…'),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _sendOrderChat(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(onPressed: canSpeakAudience ? _sendOrderChat : null, child: const Text('发送')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 自由聊天区
  Widget _buildFreeChatPanel() {
    final hint = isHost ? '主持人不可在自由区发言' : '自由聊天…（无需按顺序）';
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: SizedBox(
        height: 220,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Text('自由聊天区', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: _scrollFree,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: freeMessages.length,
                itemBuilder: (_, i) {
                  final m = freeMessages[i];
                  final from = m['from'];
                  final text = m['text'];
                  return ListTile(
                    leading: const Icon(Icons.forum),
                    title: Text('玩家 $from：$text'),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrlFree,
                      enabled: canFreeChat,
                      decoration: InputDecoration(
                        hintText: hint,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _sendFreeChat(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(onPressed: canFreeChat ? _sendFreeChat : null, child: const Text('发送')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // —— 中央积分展示 —— //
  Widget _buildScoreBoard() {
    if (isHost) {
      // 主持人：显示所有玩家积分（按ID升序）
      final ids = List<int>.from(order)..sort();
      return Center(
        child: Wrap(
          spacing: 10,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: ids.map((id) {
            final val = scores[id] ?? 0;
            return _scoreChip('ID $id：$val 分');
          }).toList(),
        ),
      );
    } else {
      // 普通玩家：只显示自己积分
      final val = scores[myId ?? -1] ?? 0;
      return Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.blue.withValues(alpha: 0.35)),
          ),
          child: Text('我的积分：$val',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.blue)),
        ),
      );
    }
  }

  Widget _scoreChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
    }

  // ====== 右侧栏：发言顺序 + 开场区 + 在线玩家 + 底部按钮（含打分区） ======
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

    final openingPanel = (isHost && running && waitingOpening && !hostOpeningUsed)
        ? Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.shade100),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('开场发言（仅此一次）', style: TextStyle(fontWeight: FontWeight.bold)),
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
                  OutlinedButton(onPressed: () => _hostAction('skipOpening'), child: const Text('跳过')),
                ]),
              ],
            ),
          )
        : const SizedBox.shrink();

    final onlinePanel = Expanded(child: _buildOnlinePlayersPanel());

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
            const SizedBox(height: 12),
            openingPanel,
            if (openingPanel is! SizedBox) const SizedBox(height: 12),
            onlinePanel,
            const SizedBox(height: 16), // 与底部按钮拉开距离

            if (isHost) _buildBottomControls(),   // Start/Stop + Yes/No/Unknown
            if (isHost) const SizedBox(height: 8),
            if (isHost) _buildScoreControls(),    // ⭐ 新增：打分区
          ],
        ),
      ),
    );
  }

  // 在线玩家（按 ID 升序）
  Widget _buildOnlinePlayersPanel() {
    final ids = List<int>.from(order)..sort();
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Text('在线玩家', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(10),
              itemCount: ids.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final id = ids[i];
                final role = _roleOf(id);
                final roleColor = _roleColor(role, id);
                final isMe = (id == myId);
                final avatarBytes = isMe ? _avatarBytes : null;
                return _playerTile(id: id, role: role, roleColor: roleColor, bytes: avatarBytes);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _playerTile({
    required int id,
    required String role,
    required Color roleColor,
    Uint8List? bytes,
  }) {
    return Row(
      children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            border: Border.all(color: Colors.grey.shade300),
            image: bytes == null ? null : DecorationImage(image: MemoryImage(bytes), fit: BoxFit.cover),
          ),
          child: bytes == null ? const Icon(Icons.person, color: Colors.grey) : null,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Row(
            children: [
              Text('ID: $id', style: const TextStyle(fontSize: 14)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: roleColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: roleColor.withValues(alpha: 0.4)),
                ),
                child: Text(role, style: TextStyle(color: roleColor, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _roleOf(int id) {
    if (id == 1) return '主持人';
    if (speakingId == id && !waitingOpening) return '发言人';
    return '观众';
  }

  Color _roleColor(String role, int id) {
    switch (role) {
      case '主持人': return Colors.orange;
      case '发言人': return Colors.blue;
      default: return Colors.grey;
    }
  }

  // ====== 右侧底部按钮：Start/Stop + Yes/No/Unknown（带判定高亮） ======
  Widget _buildBottomControls() {
    final bool hl = awaitingVerdict;
    final ButtonStyle ynuStyle = ButtonStyle(
      backgroundColor: hl ? const MaterialStatePropertyAll(Colors.amber) : null,
      foregroundColor: hl ? const MaterialStatePropertyAll(Colors.black) : null,
      elevation: hl ? const MaterialStatePropertyAll(4) : null,
      side: hl ? const MaterialStatePropertyAll(BorderSide(color: Colors.orange, width: 2)) : null,
    );

    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _hostAction('start'),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _hostAction('stop'),
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                  style: const ButtonStyle(
                    backgroundColor: MaterialStatePropertyAll(Colors.red),
                    foregroundColor: MaterialStatePropertyAll(Colors.white),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _hostAction('verdict', verdict: 'Yes'),
                  style: ynuStyle, child: const Text('Yes'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _hostAction('verdict', verdict: 'No'),
                  style: ynuStyle, child: const Text('No'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => _hostAction('verdict', verdict: 'Unknown'),
                  style: ynuStyle, child: const Text('Unknown'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ====== 右侧底部“打分”区（仅主持人可见） ======
  Widget _buildScoreControls() {
    final int? target = lastQuestionUserId;
    // 仅当存在“最近提问者”时显示；若本题已打过分，用一个提醒代替按钮
    if (target == null) {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: const Text('暂无可打分的提问', style: TextStyle(color: Colors.black54)),
      );
    }

    final bool already = _scoredThisTurn.contains(target);
    if (already) {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.green.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.green.shade200),
        ),
        child: Text('已为 玩家 $target 打分，当前总分：${scores[target] ?? 0}',
            style: const TextStyle(color: Colors.green, fontWeight: FontWeight.w600)),
      );
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.purple.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.purple.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('为 玩家 $target 本题打分',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: OutlinedButton(onPressed: () => _hostScore(0), child: const Text('0'))),
              const SizedBox(width: 8),
              Expanded(child: ElevatedButton(onPressed: () => _hostScore(1), child: const Text('+1'))),
              const SizedBox(width: 8),
              Expanded(child: ElevatedButton(onPressed: () => _hostScore(2), child: const Text('+2'))),
              const SizedBox(width: 8),
              Expanded(child: ElevatedButton(onPressed: () => _hostScore(3), child: const Text('+3'))),
            ],
          ),
        ],
      ),
    );
  }

  // 发言顺序 Chips
  Widget _buildOrderChips() {
    if (order.isEmpty) return const Text('-', style: TextStyle(color: Colors.black54));
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
          color: bg, borderRadius: BorderRadius.circular(999), border: Border.all(color: borderColor),
        ),
        child: Text('$id${isHostId ? " (主持)" : ""}',
            style: TextStyle(color: fg, fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal)),
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

  // 顺序发言区消息项
  Widget _tile(Map<String, dynamic> m) {
    switch (m['type']) {
      case 'system':
        return ListTile(
          dense: true,
          leading: const Icon(Icons.info, color: Colors.grey),
          title: Text('[系统] ${m['text']}', style: const TextStyle(color: Colors.grey)),
        );
      case 'opening':
        return ListTile(leading: const Icon(Icons.mic), title: Text('主持人开场：${m['text']}'));
      case 'chat':
        return ListTile(leading: const Icon(Icons.person), title: Text('玩家 ${m['from']}：${m['text']}'));
      case 'verdict':
        return ListTile(leading: const Icon(Icons.gavel), title: Text('主持人判定 → 玩家 ${m['to']} : ${m['verdict']}'));
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
