import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/html.dart' as html;

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '特殊聊天室（主持人轮转）',
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

  int? myId;
  bool isHost = false;

  bool running = false;
  int? speakingId;
  int round = 1;
  List<int> order = [];

  final List<Map<String, dynamic>> messages = [];
  final TextEditingController _ctrl = TextEditingController();
  final ScrollController _scroll = ScrollController();

  String wsAddress = 'ws://localhost:8080'; // 如需跨设备，改成 ws://<服务器IP>:8080

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    _connect();
  }

  void _connect() {
    try {
      final uri = Uri.parse(wsAddress);
      _ch = kIsWeb
          ? html.HtmlWebSocketChannel.connect(uri)
          : IOWebSocketChannel.connect(uri);

      final saved = _prefs?.getInt('playerId');
      _ch!.sink.add(jsonEncode({
        'type': 'restore',
        'savedId': saved,
      }));

      _ch!.stream.listen((data) {
        final map = jsonDecode(data);
        final t = map['type'];
        if (t == 'welcome') {
          setState(() {
            myId = map['playerId'] as int;
            isHost = (map['isHost'] == true);
          });
          _prefs?.setInt('playerId', myId!);
        } else if (t == 'state') {
          setState(() {
            running = map['running'] == true;
            speakingId = map['speakingId'];
            round = (map['round'] ?? 1) as int;
            order = (map['order'] as List).map((e) => e as int).toList();
          });
        } else if (t == 'system' || t == 'chat' || t == 'verdict') {
          setState(() {
            messages.add(Map<String, dynamic>.from(map));
          });
          _scrollToBottom();
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

  bool get canSpeak => running && myId != null && speakingId == myId && !isHost;

  void _sendChat() {
    final txt = _ctrl.text.trim();
    if (txt.isEmpty || !canSpeak) return;
    _ch?.sink.add(jsonEncode({
      'type': 'chat',
      'text': txt,
    }));
    _ctrl.clear();
  }

  void _hostAction(String action, {String? verdict}) {
    if (!isHost) return;
    final payload = {'type': 'hostControl', 'action': action};
    if (verdict != null) payload['verdict'] = verdict;
    _ch?.sink.add(jsonEncode(payload));
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
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final header = Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text('我：${myId ?? "-"}', style: const TextStyle(fontSize: 16)),
              if (isHost)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade100,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text('主持人', style: TextStyle(color: Colors.orange)),
                ),
            ],
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('轮次：$round', style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 12),
            Icon(
              running ? Icons.play_circle_fill : Icons.pause_circle_filled,
              color: running ? Colors.green : Colors.grey,
            ),
          ],
        ),
      ],
    );

    final stateCard = Container(
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
          Text('当前发言：${speakingId ?? "-"}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text('顺序：${order.isEmpty ? "-" : order.join(" → ")}'),
          const SizedBox(height: 6),
          Text('服务器：$wsAddress', style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );

    final hostPanel = isHost
        ? Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
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
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: () => _hostAction('verdict', verdict: 'Yes'),
                child: const Text('Yes'),
              ),
              ElevatedButton(
                onPressed: () => _hostAction('verdict', verdict: 'No'),
                child: const Text('No'),
              ),
              ElevatedButton(
                onPressed: () => _hostAction('verdict', verdict: 'Unknown'),
                child: const Text('Unknown'),
              ),
            ],
          )
        : const SizedBox.shrink();

    Widget _tile(Map<String, dynamic> m) {
      switch (m['type']) {
        case 'system':
          return ListTile(
            dense: true,
            leading: const Icon(Icons.info, color: Colors.grey),
            title: Text('[系统] ${m['text']}', style: const TextStyle(color: Colors.grey)),
            subtitle: Text(m['ts'] ?? ''),
          );
        case 'chat':
          return ListTile(
            leading: const Icon(Icons.person),
            title: Text('玩家 ${m['from']}：${m['text']}'),
            subtitle: Text(m['ts'] ?? ''),
          );
        case 'verdict':
          return ListTile(
            leading: const Icon(Icons.gavel),
            title: Text('主持人判定 → 玩家 ${m['to']} : ${m['verdict']}'),
            subtitle: Text(m['ts'] ?? ''),
          );
        default:
          return const SizedBox.shrink();
      }
    }

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
            enabled: canSpeak,
            decoration: InputDecoration(
              hintText: canSpeak ? '轮到你，请发言…' : '等待轮到你…',
              border: const OutlineInputBorder(),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onSubmitted: (_) => _sendChat(),
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: canSpeak ? _sendChat : null,
          child: const Text('发送'),
        ),
      ],
    );

    final addressBar = Row(
      children: [
        Expanded(
          child: TextFormField(
            initialValue: wsAddress,
            decoration: const InputDecoration(
              labelText: '服务器地址（ws://… 或 wss://…）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => wsAddress = v.trim(),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: () {
            // 主动重连
            _ch?.sink.close();
            _connect();
          },
          icon: const Icon(Icons.link),
          label: const Text('连接'),
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(title: const Text('特殊聊天室（主持人依序发言）')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            header,
            const SizedBox(height: 8),
            stateCard,
            const SizedBox(height: 8),
            addressBar,
            const SizedBox(height: 8),
            hostPanel,
            const SizedBox(height: 8),
            const Divider(height: 16),
            messageList,
            inputBar,
          ],
        ),
      ),
    );
  }
}
