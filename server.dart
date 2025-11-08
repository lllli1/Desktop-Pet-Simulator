// bin/server.dart  或  server.dart
import 'dart:io';
import 'dart:convert';

void main(List<String> args) async {
  final port = args.isNotEmpty ? int.tryParse(args.first) ?? 8080 : 8080;
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  print('WebSocket server listening on ws://localhost:$port');

  final wsServer = _SoupServer();
  await for (HttpRequest req in server) {
    if (WebSocketTransformer.isUpgradeRequest(req)) {
      final socket = await WebSocketTransformer.upgrade(req);
      wsServer.handleClient(socket);
    } else {
      req.response
        ..statusCode = HttpStatus.forbidden
        ..write('WebSocket only')
        ..close();
    }
  }
}

class _SoupServer {
  // 连接
  final Map<WebSocket, int> _connToId = {};
  final Map<int, WebSocket> _idToConn = {};

  // 全局状态
  int _nextId = 1;               // 1 号留给主持人（第一个连入者）
  bool running = false;
  bool waitingOpening = false;
  bool hostOpeningUsed = false;
  int? speakingId;
  int round = 1;
  List<int> order = [];          // 包含主持人 1
  bool awaitingVerdict = false;  // 是否等待主持人判定（控制客户端高亮）

  // ===== 历史存储（最近 N 条） =====
  final int _maxHistory = 200;
  final List<Map<String, dynamic>> _histOrdered = []; // system/opening/chat/verdict
  final List<Map<String, dynamic>> _histFree = [];    // freechat

  void handleClient(WebSocket ws) {
    final id = _assignId(ws);
    final isHost = (id == 1);

    // welcome
    _send(ws, {
      'type': 'welcome',
      'playerId': id,
      'isHost': isHost,
    });

    // 首次下发历史
    _send(ws, {
      'type': 'bulkSync',
      'ordered': _histOrdered,
      'free': _histFree,
    });

    // 再发一次当前状态
    _broadcastState();

    ws.listen((data) {
      try {
        final msg = jsonDecode(data);
        final type = msg['type'];

        switch (type) {
          case 'restore':
            // 客户端请求恢复：回 welcome + 历史 + 状态
            _send(ws, {
              'type': 'welcome',
              'playerId': id,
              'isHost': isHost,
            });
            _send(ws, {
              'type': 'bulkSync',
              'ordered': _histOrdered,
              'free': _histFree,
            });
            _broadcastState();
            break;

          case 'hostControl':
            if (!isHost) break;
            final action = (msg['action'] ?? '').toString();
            switch (action) {
              case 'start':
                _onStart();
                break;
              case 'stop':
                _onStop();
                break;
              case 'opening':
                _onOpening((msg['text'] ?? '').toString());
                break;
              case 'skipOpening':
                _onSkipOpening();
                break;
              case 'verdict':
                _onVerdict((msg['verdict'] ?? '').toString());
                break;
            }
            break;

          case 'chat':
            // 顺序发言区：仅当前发言观众可说话
            if (!running || waitingOpening) break;
            if (speakingId != id) break;

            final text = (msg['text'] ?? '').toString();
            if (text.isEmpty) break;

            final objChat = {
              'type': 'chat',
              'from': id,
              'text': text,
              'ts': DateTime.now().toIso8601String(),
            };
            _broadcast(objChat);
            _pushOrdered(objChat);

            // 新规则：顺序区发言均视为需要判定
            awaitingVerdict = true;
            _broadcastState();
            break;

          case 'freechat':
            // 自由聊天：主持人不能说，其他人随时可说
            if (id == 1) break;
            final text = (msg['text'] ?? '').toString();
            if (text.isEmpty) break;

            final objFree = {
              'type': 'freechat',
              'from': id,
              'text': text,
              'ts': DateTime.now().toIso8601String(),
            };
            _broadcast(objFree);
            _pushFree(objFree);
            // 不影响流程与 awaitingVerdict
            break;
        }
      } catch (e) {
        print('Error handling message: $e');
      }
    }, onDone: () {
      _onDisconnect(ws);
    }, onError: (e) {
      print('WS error: $e');
      _onDisconnect(ws);
    });
  }

  int _assignId(WebSocket ws) {
    if (!_idToConn.containsKey(1)) {
      _connToId[ws] = 1;
      _idToConn[1] = ws;
      if (!order.contains(1)) order.insert(0, 1);
      print('New host connected: id=1');
      return 1;
    }
    while (_idToConn.containsKey(_nextId) || _nextId == 1) {
      _nextId++;
    }
    final id = _nextId++;
    _connToId[ws] = id;
    _idToConn[id] = ws;
    if (!order.contains(id)) order.add(id);
    print('New user connected: id=$id');
    return id;
  }

  void _onDisconnect(WebSocket ws) {
    final id = _connToId.remove(ws);
    if (id != null) {
      _idToConn.remove(id);
      order.remove(id);

      // 当前发言者掉线则推进
      if (speakingId == id) {
        _advanceSpeaker();
      }
      print('User disconnected: id=$id');
    }
    _broadcastState();
  }

  // ===== 流程控制 =====
  void _onStart() {
    running = true;
    waitingOpening = true;
    hostOpeningUsed = false;
    speakingId = null;
    round = 1;
    awaitingVerdict = false;

    final obj = {
      'type': 'system',
      'text': '游戏开始，等待主持人开场',
      'ts': DateTime.now().toIso8601String(),
    };
    _broadcast(obj);
    _pushOrdered(obj);
    _broadcastState();
  }

  void _onStop() {
    running = false;
    waitingOpening = false;
    awaitingVerdict = false;

    final obj = {
      'type': 'system',
      'text': '游戏已停止',
      'ts': DateTime.now().toIso8601String(),
    };
    _broadcast(obj);
    _pushOrdered(obj);
    _broadcastState();
  }

  void _onOpening(String text) {
    if (!running || !waitingOpening || hostOpeningUsed) return;
    hostOpeningUsed = true;
    waitingOpening = false;

    final obj = {
      'type': 'opening',
      'text': text,
      'ts': DateTime.now().toIso8601String(),
    };
    _broadcast(obj);
    _pushOrdered(obj);

    _setFirstAudienceAsSpeaker();
    _broadcastState();
  }

  void _onSkipOpening() {
    if (!running || !waitingOpening) return;
    hostOpeningUsed = true;
    waitingOpening = false;

    final obj = {
      'type': 'system',
      'text': '主持人跳过开场',
      'ts': DateTime.now().toIso8601String(),
    };
    _broadcast(obj);
    _pushOrdered(obj);

    _setFirstAudienceAsSpeaker();
    _broadcastState();
  }

  void _onVerdict(String verdict) {
    if (!running) return;
    if (speakingId == null) return;

    final obj = {
      'type': 'verdict',
      'to': speakingId,
      'verdict': verdict,
      'ts': DateTime.now().toIso8601String(),
    };
    _broadcast(obj);
    _pushOrdered(obj);

    awaitingVerdict = false; // 关闭高亮
    _advanceSpeaker();
    _broadcastState();
  }

  void _setFirstAudienceAsSpeaker() {
    final audience = order.where((id) => id != 1).toList();
    if (audience.isEmpty) {
      speakingId = null;
      return;
    }
    speakingId = audience.first;
  }

  void _advanceSpeaker() {
    final audience = order.where((id) => id != 1).toList();
    if (audience.isEmpty) {
      speakingId = null;
      return;
    }
    if (speakingId == null) {
      speakingId = audience.first;
      return;
    }
    final idx = audience.indexOf(speakingId!);
    if (idx < 0 || idx == audience.length - 1) {
      round += 1;
      speakingId = audience.first;
    } else {
      speakingId = audience[idx + 1];
    }
  }

  // ===== 历史存储 =====
  void _pushOrdered(Map<String, dynamic> obj) {
    _histOrdered.add(obj);
    if (_histOrdered.length > _maxHistory) {
      _histOrdered.removeAt(0);
    }
  }

  void _pushFree(Map<String, dynamic> obj) {
    _histFree.add(obj);
    if (_histFree.length > _maxHistory) {
      _histFree.removeAt(0);
    }
  }

  // ===== 广播/发送 =====
  void _broadcastState() {
    final payload = {
      'type': 'state',
      'running': running,
      'waitingOpening': waitingOpening,
      'hostOpeningUsed': hostOpeningUsed,
      'speakingId': speakingId,
      'round': round,
      'order': order,
      'awaitingVerdict': awaitingVerdict,
    };
    print('[STATE] running=$running waitingOpening=$waitingOpening '
        'speakingId=$speakingId round=$round awaitingVerdict=$awaitingVerdict '
        'online=${_idToConn.length}');
    _broadcast(payload);
  }

  void _broadcast(Map<String, dynamic> obj) {
    final text = jsonEncode(obj);
    for (final ws in _connToId.keys.toList()) {
      try {
        ws.add(text);
      } catch (_) {}
    }
  }

  void _send(WebSocket ws, Map<String, dynamic> obj) {
    ws.add(jsonEncode(obj));
  }
}
