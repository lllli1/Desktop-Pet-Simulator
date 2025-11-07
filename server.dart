import 'dart:io';
import 'dart:convert';

class RoomState {
  bool running = false;          // 是否正在轮转
  int? speakingId;               // 当前允许发言的用户id（不包含主持人）
  int round = 1;                 // 轮次，从1开始
  List<int> order = [];          // 在线用户按id升序（含主持人）
  final Map<int, WebSocket> socketsById = {};
  final Map<WebSocket, int> idBySocket = {};
  final Set<int> online = {};    // 在线id集合
  final Set<int> issued = {};    // 曾经发过的id（用于重连校验）

  int _nextAlloc = 1;

  /// 分配最小未用正整数ID
  int allocateNewId() {
    while (issued.contains(_nextAlloc)) {
      _nextAlloc++;
    }
    issued.add(_nextAlloc);
    return _nextAlloc++;
  }

  /// 仅听众的发言顺序（排除主持人 id==1）
  List<int> get talkOrder => order.where((id) => id != 1).toList();

  void attach(int id, WebSocket ws) {
    socketsById[id] = ws;
    idBySocket[ws] = id;
    online.add(id);
    order = online.toList()..sort();

    // 若尚未指定发言者，则指向听众序列中的首位
    if (speakingId == null) {
      final t = talkOrder;
      speakingId = t.isNotEmpty ? t.first : null;
    }
  }

  void detach(WebSocket ws) {
    final id = idBySocket[ws];
    if (id == null) return;

    socketsById.remove(id);
    idBySocket.remove(ws);
    online.remove(id);
    order = online.toList()..sort();

    // 如果当前发言者掉线，则推进到下一位
    if (speakingId == id) {
      _advanceToNext(fromId: id, countRoundWhenWrap: false);
    }

    // 若已无听众（只剩主持人或空房），自动停止并复位发言者与轮次
    if (talkOrder.isEmpty) {
      running = false;
      speakingId = null;
      round = 1;
    }
  }

  /// 从指定id推进到下一位（基于 talkOrder）
  void _advanceToNext({int? fromId, bool countRoundWhenWrap = true}) {
    final t = talkOrder;
    if (t.isEmpty) {
      speakingId = null;
      return;
    }
    if (fromId == null) {
      speakingId = t.first;
      return;
    }
    final idx = t.indexOf(fromId);
    if (idx < 0) {
      // 当前id不在听众序列（可能是主持人），回到首位
      speakingId = t.first;
      return;
    }
    final nextIdx = (idx + 1) % t.length;
    if (countRoundWhenWrap && nextIdx == 0) round += 1;
    speakingId = t[nextIdx];
  }

  /// 主持人判定后推进
  void advanceAfterVerdict() {
    _advanceToNext(fromId: speakingId, countRoundWhenWrap: true);
  }

  Map<String, dynamic> toJson() => {
        'type': 'state',
        'running': running,
        'speakingId': speakingId,
        'round': round,
        'order': order, // 前端可显示完整在线顺序（含主持人）
      };
}

void main() async {
  final server = await HttpServer.bind('0.0.0.0', 8080);
  print('Server started: ws://localhost:8080');
  final room = RoomState();

  void send(WebSocket ws, Map<String, dynamic> msg) {
    try {
      ws.add(jsonEncode(msg));
    } catch (_) {}
  }

  void broadcast(Map<String, dynamic> msg) {
    final text = jsonEncode(msg);
    for (final ws in room.socketsById.values) {
      try {
        ws.add(text);
      } catch (_) {}
    }
  }

  void broadcastState() => broadcast(room.toJson());

  await for (final req in server) {
    // 仅处理 WebSocket
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response
        ..statusCode = HttpStatus.notFound
        ..close();
      continue;
    }

    final ws = await WebSocketTransformer.upgrade(req);

    ws.listen((raw) {
      Map<String, dynamic>? data;
      try {
        data = jsonDecode(raw as String) as Map<String, dynamic>;
      } catch (_) {
        return;
      }
      final type = data?['type'];

      switch (type) {
        // 连接/重连
        case 'restore': {
          final savedId = data?['savedId'];
          int id;
          bool isHost;

          if (savedId is int &&
              room.issued.contains(savedId) &&
              !room.online.contains(savedId)) {
            // 恢复旧ID（未被占用）
            id = savedId;
          } else {
            // 分配新ID
            id = room.allocateNewId();
          }
          isHost = (id == 1); // 规则：id==1 为主持人

          room.attach(id, ws);

          // 欢迎信息（告知身份）
          send(ws, {
            'type': 'welcome',
            'playerId': id,
            'isHost': isHost,
          });

          // 系统公告
          broadcast({
            'type': 'system',
            'text': '玩家 $id 加入房间（${isHost ? "主持人" : "听众"}）',
            'ts': DateTime.now().toIso8601String(),
          });

          // 更新全员状态
          broadcastState();
          break;
        }

        // 听众发言（主持人不允许发言）
        case 'chat': {
          final id = room.idBySocket[ws];
          if (id == null) break;
          if (id == 1) break; // 主持人不允许发言（裁判）

          final text = (data?['text'] ?? '').toString().trim();
          if (text.isEmpty) break;

          // 只有在进行中且轮到自己才能发言
          if (room.running && room.speakingId == id) {
            broadcast({
              'type': 'chat',
              'from': id,
              'text': text,
              'ts': DateTime.now().toIso8601String(),
            });
          }
          break;
        }

        // 主持人控制（开始/停止/判定）
        case 'hostControl': {
          final id = room.idBySocket[ws];
          if (id != 1) break; // 仅主持人可控

          final action = (data?['action'] ?? '').toString();

          if (action == 'start') {
            if (room.talkOrder.isNotEmpty) {
              room.running = true;
              // 确保发言者是听众序列中的一个
              if (room.speakingId == null || !room.talkOrder.contains(room.speakingId)) {
                room.speakingId = room.talkOrder.first;
              }
              broadcast({
                'type': 'system',
                'text': '主持人开始轮转',
                'ts': DateTime.now().toIso8601String(),
              });
              broadcastState();
            } else {
              send(ws, {
                'type': 'system',
                'text': '当前没有听众可发言，无法开始',
                'ts': DateTime.now().toIso8601String(),
              });
            }
          } else if (action == 'stop') {
            room.running = false;
            broadcast({
              'type': 'system',
              'text': '主持人停止轮转',
              'ts': DateTime.now().toIso8601String(),
            });
            broadcastState();
          } else if (action == 'verdict') {
            final verdict = (data?['verdict'] ?? '').toString(); // Yes/No/Unknown
            final speaking = room.speakingId;

            if (room.running &&
                speaking != null &&
                ['Yes', 'No', 'Unknown'].contains(verdict)) {
              // 广播判定
              broadcast({
                'type': 'verdict',
                'to': speaking,
                'verdict': verdict,
                'ts': DateTime.now().toIso8601String(),
              });

              // 推进至下一位听众
              room.advanceAfterVerdict();
              // 若推进后没有听众（例如都掉线），自动停止
              if (room.talkOrder.isEmpty) {
                room.running = false;
              }
              broadcastState();
            }
          }
          break;
        }

        default:
          break;
      }
    }, onDone: () {
      // 断开连接
      room.detach(ws);
      broadcast({
        'type': 'system',
        'text': '有人离线，当前在线：${room.order}',
        'ts': DateTime.now().toIso8601String(),
      });
      broadcastState();
    }, onError: (_) {
      room.detach(ws);
      broadcastState();
    });
  }
}
