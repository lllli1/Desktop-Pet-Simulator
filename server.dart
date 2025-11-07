import 'dart:io';
import 'dart:convert';

class RoomState {
  bool running = false;            // 是否正在轮转
  int? speakingId;                 // 当前允许发言的用户id（仅听众）
  int round = 1;                   // 轮次，从1开始
  List<int> order = [];            // 在线用户按id升序（含主持人）
  final Map<int, WebSocket> socketsById = {};
  final Map<WebSocket, int> idBySocket = {};
  final Set<int> online = {};      // 在线id集合
  final Set<int> issued = {};      // 曾经发过的id（用于重连校验）

  // 开场白控制
  bool hostOpeningUsed = false;    // 主持人开场是否已用
  bool waitingOpening = false;     // 是否等待开场（Start 后，若尚未开场则为 true）

  int _nextAlloc = 1;

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

    // 若尚未指定发言者，则指向听众序列中的首位（仅在不等待开场时）
    if (speakingId == null && !waitingOpening) {
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

    if (speakingId == id) {
      _advanceToNext(fromId: id, countRoundWhenWrap: false);
    }

    // 只剩主持人或无人 → 停止并复位（但不重置 openingUsed）
    if (talkOrder.isEmpty) {
      running = false;
      speakingId = null;
      round = 1;
      waitingOpening = false; // 无人可讲，取消等待
    }
  }

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
    final nextIdx = idx < 0 ? 0 : (idx + 1) % t.length;
    if (countRoundWhenWrap && idx >= 0 && nextIdx == 0) round += 1;
    speakingId = t[nextIdx];
  }

  void advanceAfterVerdict() {
    _advanceToNext(fromId: speakingId, countRoundWhenWrap: true);
  }

  Map<String, dynamic> toJson() => {
        'type': 'state',
        'running': running,
        'speakingId': speakingId,
        'round': round,
        'order': order,
        'hostOpeningUsed': hostOpeningUsed,
        'waitingOpening': waitingOpening,
      };
}

void main() async {
  final server = await HttpServer.bind('0.0.0.0', 8080);
  print('Server started: ws://localhost:8080');
  final room = RoomState();

  void send(WebSocket ws, Map<String, dynamic> msg) {
    try { ws.add(jsonEncode(msg)); } catch (_) {}
  }

  void broadcast(Map<String, dynamic> msg) {
    final text = jsonEncode(msg);
    for (final ws in room.socketsById.values) {
      try { ws.add(text); } catch (_) {}
    }
  }

  void broadcastState() => broadcast(room.toJson());

  await for (final req in server) {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response..statusCode = HttpStatus.notFound..close();
      continue;
    }
    final ws = await WebSocketTransformer.upgrade(req);

    ws.listen((raw) {
      Map<String, dynamic>? data;
      try { data = jsonDecode(raw as String) as Map<String, dynamic>; } catch (_) { return; }
      final type = data?['type'];

      switch (type) {
        // 连接/重连
        case 'restore': {
          final savedId = data?['savedId'];
          int id;
          if (savedId is int && room.issued.contains(savedId) && !room.online.contains(savedId)) {
            id = savedId;
          } else {
            id = room.allocateNewId();
          }
          final isHost = (id == 1);
          room.attach(id, ws);

          send(ws, {'type':'welcome','playerId':id,'isHost':isHost});
          broadcast({'type':'system','text':'玩家 $id 加入（${isHost?"主持人":"听众"}）','ts':DateTime.now().toIso8601String()});
          broadcastState();
          break;
        }

        // 听众发言（主持人聊天一律不走这条）
        case 'chat': {
          final id = room.idBySocket[ws];
          if (id == null || id == 1) break; // 主持人不允许走 chat
          final text = (data?['text'] ?? '').toString().trim();
          if (text.isEmpty) break;
          if (room.running && !room.waitingOpening && room.speakingId == id) {
            broadcast({'type':'chat','from':id,'text':text,'ts':DateTime.now().toIso8601String()});
          }
          break;
        }

        // 主持人控制：开始/停止/判定/开场白/跳过开场
        case 'hostControl': {
          final id = room.idBySocket[ws];
          if (id != 1) break; // 只有主持人可控
          final action = (data?['action'] ?? '').toString();

          if (action == 'start') {
            if (room.talkOrder.isNotEmpty) {
              room.running = true;
              // 若没用过开场，则进入等待开场阶段；否则直接指向首位听众
              room.waitingOpening = !room.hostOpeningUsed;
              if (room.waitingOpening) {
                room.speakingId = null;
                broadcast({'type':'system','text':'主持人开始，等待开场发言…','ts':DateTime.now().toIso8601String()});
              } else {
                room.speakingId = room.talkOrder.first;
                broadcast({'type':'system','text':'主持人开始，进入轮转','ts':DateTime.now().toIso8601String()});
              }
              broadcastState();
            } else {
              send(ws, {'type':'system','text':'当前没有听众可发言，无法开始','ts':DateTime.now().toIso8601String()});
            }
          }

          else if (action == 'stop') {
            room.running = false;
            room.waitingOpening = false; // 结束时不再等待开场
            broadcast({'type':'system','text':'主持人停止轮转','ts':DateTime.now().toIso8601String()});
            broadcastState();
          }

          else if (action == 'verdict') {
            final verdict = (data?['verdict'] ?? '').toString(); // Yes/No/Unknown
            final speaking = room.speakingId;
            if (room.running && !room.waitingOpening && speaking != null &&
                ['Yes','No','Unknown'].contains(verdict)) {
              broadcast({'type':'verdict','to':speaking,'verdict':verdict,'ts':DateTime.now().toIso8601String()});
              room.advanceAfterVerdict();
              if (room.talkOrder.isEmpty) room.running = false;
              broadcastState();
            }
          }

          else if (action == 'opening') {
            // 主持人“开场发言”：仅在 run 中、等待开场且未使用时允许
            final text = (data?['text'] ?? '').toString().trim();
            if (text.isEmpty) break;
            if (room.running && room.waitingOpening && !room.hostOpeningUsed) {
              broadcast({'type':'opening','from':1,'text':text,'ts':DateTime.now().toIso8601String()});
              room.hostOpeningUsed = true;
              room.waitingOpening = false;
              // 开场后，直接进入首位听众
              if (room.talkOrder.isNotEmpty) {
                room.speakingId = room.talkOrder.first;
              } else {
                room.speakingId = null;
                room.running = false;
              }
              broadcastState();
            }
          }

          else if (action == 'skipOpening') {
            // 可选：主持人跳过开场
            if (room.running && room.waitingOpening) {
              room.waitingOpening = false;
              room.speakingId = room.talkOrder.isNotEmpty ? room.talkOrder.first : null;
              broadcast({'type':'system','text':'主持人跳过开场','ts':DateTime.now().toIso8601String()});
              broadcastState();
            }
          }

          break;
        }

        default: break;
      }
    }, onDone: () {
      room.detach(ws);
      broadcast({'type':'system','text':'有人离线，当前在线：${room.order}','ts':DateTime.now().toIso8601String()});
      broadcastState();
    }, onError: (_) {
      room.detach(ws);
      broadcastState();
    });
  }
}
