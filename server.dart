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
  // 连接映射
  final Map<WebSocket, int> _connToId = {};
  final Map<int, WebSocket> _idToConn = {};

  // —— 全局状态 —— //
  int _nextId = 1;               // 1 号为主持人（首个连接）
  bool running = false;
  bool waitingOpening = false;
  bool hostOpeningUsed = false;
  int? speakingId;
  int round = 1;
  List<int> order = [];          // 含主持人 1
  bool awaitingVerdict = false;  // 是否等待主持人判定（高亮）

  // —— 计分 —— //
  final Map<int, int> scores = {}; // 玩家积分（id -> total）

  // —— 头像（跨端同步，base64 PNG/JPG）—— //
  final Map<int, String> avatarsB64 = {}; // id -> base64（不含 dataURI 头）

  // —— 历史（最近 200 条，可调）—— //
  final int _maxHistory = 200;
  final List<Map<String, dynamic>> _histOrdered = []; // system/opening/chat/verdict/score/avatar
  final List<Map<String, dynamic>> _histFree = [];    // freechat

  // ===== 工具：把 int 键的 Map 转成 string 键（供 jsonEncode 使用） =====
  Map<String, T> _stringKeys<T>(Map<int, T> m) {
    final out = <String, T>{};
    m.forEach((k, v) => out['$k'] = v);
    return out;
  }

  // 入口：处理新连接
  void handleClient(WebSocket ws) {
    final id = _assignId(ws);
    final isHost = (id == 1);

    // welcome
    _send(ws, {
      'type': 'welcome',
      'playerId': id,
      'isHost': isHost,
    });

    // 首次下发历史 & 积分 & 头像（注意把 Map<int,...> 的键转成字符串）
    _send(ws, {
      'type': 'bulkSync',
      'ordered': _histOrdered,
      'free': _histFree,
      'scores': _stringKeys(scores),
      'avatars': _stringKeys(avatarsB64),
    });

    // 下发当前状态
    _broadcastState();

    ws.listen((data) {
      try {
        final msg = jsonDecode(data);
        final type = msg['type'];

        switch (type) {
          case 'restore':
            _send(ws, {
              'type': 'welcome',
              'playerId': id,
              'isHost': isHost,
            });
            _send(ws, {
              'type': 'bulkSync',
              'ordered': _histOrdered,
              'free': _histFree,
              'scores': _stringKeys(scores),
              'avatars': _stringKeys(avatarsB64),
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
              case 'score':
                final to = msg['to'];
                final delta = msg['delta'];
                if (to is int && delta is int && delta >= 0 && delta <= 3) {
                  _applyScore(to, delta);
                }
                break;
            }
            break;

          case 'avatar':
            // 任何玩家都可更新自己的头像；限制体积以防滥用
            final pngB64 = (msg['pngB64'] ?? '').toString();
            if (pngB64.isEmpty) break;
            // 体积限制（base64长度大致等于原始*1.33），这里约 100KB 原图
            if (pngB64.length > 140000) {
              print('Avatar too large from id=$id, ignored.');
              break;
            }
            avatarsB64[id] = pngB64;
            final objAvatar = {
              'type': 'avatar',
              'id': id,
              'pngB64': pngB64,
              'ts': DateTime.now().toIso8601String(),
            };
            _broadcast(objAvatar);
            _pushOrdered(objAvatar); // 作为事件记录（可选）
            _broadcastState();       // state 中也包含 avatars
            break;

          case 'chat':
            // 顺序发言：仅当前发言观众可说
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

            awaitingVerdict = true;
            _broadcastState();
            break;

          case 'freechat':
            // 自由聊天：主持人不可发言，其余人随时可发
            if (id == 1) break;
            final text2 = (msg['text'] ?? '').toString();
            if (text2.isEmpty) break;

            final objFree = {
              'type': 'freechat',
              'from': id,
              'text': text2,
              'ts': DateTime.now().toIso8601String(),
            };
            _broadcast(objFree);
            _pushFree(objFree);
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

  // 分配玩家 ID（首个为主持人 1）
  int _assignId(WebSocket ws) {
    if (!_idToConn.containsKey(1)) {
      _connToId[ws] = 1;
      _idToConn[1] = ws;
      if (!order.contains(1)) order.insert(0, 1);
      scores.putIfAbsent(1, () => 0);
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
    scores.putIfAbsent(id, () => 0);
    print('New user connected: id=$id');
    return id;
  }

  void _onDisconnect(WebSocket ws) {
    final id = _connToId.remove(ws);
    if (id != null) {
      _idToConn.remove(id);
      order.remove(id);
      if (speakingId == id) {
        _advanceSpeaker();
      }
      print('User disconnected: id=$id');
    }
    _broadcastState();
  }

  // —— 流程控制 —— //
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

    awaitingVerdict = false;
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

  // —— 计分逻辑 —— //
  void _applyScore(int to, int delta) {
    scores[to] = (scores[to] ?? 0) + delta;

    final obj = {
      'type': 'score',
      'to': to,
      'delta': delta,
      'total': scores[to],
      'ts': DateTime.now().toIso8601String(),
    };
    _broadcast(obj);
    _pushOrdered(obj);
    _broadcastState();
  }

  // —— 历史入库 —— //
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

  // —— 广播/发送 —— //
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
      'scores': _stringKeys(scores),     // ★ 键转字符串
      'avatars': _stringKeys(avatarsB64) // ★ 键转字符串
    };
    print('[STATE] running=$running waitingOpening=$waitingOpening '
        'speakingId=$speakingId round=$round '
        'awaitingVerdict=$awaitingVerdict online=${_idToConn.length} '
        'scores=${scores.length} avatars=${avatarsB64.length}');
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
