import 'dart:io';
import 'dart:convert';

void main() async {
  final server = await HttpServer.bind('0.0.0.0', 8080);
  print('主机已启动: ws://localhost:8080');

  int clientCount = 0;
  int nextPlayerId = 1;
  final List<WebSocket> clients = [];
  final Map<WebSocket, int> playerIds = {};
  final Set<int> activeIds = {};  // 当前在线的 ID（断开时移除）

  // === 辅助函数 ===
  int allocateNewId() {
    int id;
    do {
      id = nextPlayerId++;
    } while (activeIds.contains(id));
    activeIds.add(id);
    return id;
  }

  void broadcastCount(int count) {
    final data = jsonEncode({'count': count});
    clients.removeWhere((c) => c.readyState != WebSocket.open);
    for (var client in clients) {
      try {
        client.add(data);
      } catch (_) {}
    }
  }

  void sendToClient(WebSocket socket, Map<String, dynamic> data) {
    if (socket.readyState == WebSocket.open) {
      try {
        socket.add(jsonEncode(data));
      } catch (e) {
        print('发送失败: $e');
      }
    }
  }

  void handleDisconnect(WebSocket socket) {
    final id = playerIds.remove(socket);
    if (id != null) {
      activeIds.remove(id);  // 关键：从 activeIds 移除
      clientCount = playerIds.length;
      print('玩家 $id 断开 → 当前人数: $clientCount');
      clients.remove(socket);
      broadcastCount(clientCount);
    }
  }

  // === 主循环 ===
  await for (final request in server) {
    if (request.uri.path == '/ws') {
      try {
        final socket = await WebSocketTransformer.upgrade(request);
        clients.add(socket);

        socket.listen(
          (message) {
            final data = jsonDecode(message);
            int playerId;

            // 1. 老玩家恢复连接
            if (data['type'] == 'restore' && data['savedId'] != null) {
              final savedId = data['savedId'] as int;

              if (!activeIds.contains(savedId)) {
                // ID 未被占用 → 恢复成功
                playerId = savedId;
                activeIds.add(playerId);
                print('玩家 $playerId 恢复连接');
              } else {
                // ID 正在被别人用 → 分配新 ID
                playerId = allocateNewId();
                print('ID $savedId 已被占用，分配新ID: $playerId');
              }
            }
            // 2. 新玩家
            else {
              playerId = allocateNewId();
              print('新玩家加入，分配ID: $playerId');
            }

            // 记录
            playerIds[socket] = playerId;
            clientCount = playerIds.length;

            // 发送 ID + 人数
            sendToClient(socket, {
              'playerId': playerId,
              'count': clientCount,
            });

            // 广播人数
            broadcastCount(clientCount);
          },
          onDone: () => handleDisconnect(socket),
          onError: (_) => handleDisconnect(socket),
        );
      } catch (e) {
        print('WebSocket 错误: $e');
      }
    } else {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
    }
  }
}