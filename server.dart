import 'dart:io';
import 'dart:convert';

void main() async {
  final server = await HttpServer.bind('0.0.0.0', 8080);
  print('主机已启动: ws://localhost:8080');
  print('请运行: flutter run -d chrome');

  int clientCount = 0;
  final List<WebSocket> clients = [];

  await for (var request in server) {
    if (request.uri.path == '/ws') {
      try {
        final socket = await WebSocketTransformer.upgrade(request);
        clientCount++;
        clients.add(socket);
        print('新客户端连接 → 当前人数: $clientCount');
        _broadcast(clients, clientCount);

        socket.listen(
          (_) {}, // 可扩展接收消息
          onDone: () {
            clientCount--;
            clients.remove(socket);
            print('客户端断开 → 当前人数: $clientCount');
            _broadcast(clients, clientCount);
          },
          onError: (_) {
            clientCount--;
            clients.remove(socket);
            _broadcast(clients, clientCount);
          },
        );
      } catch (e) {
        print('WebSocket 升级失败: $e');
      }
    } else {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
    }
  }
}

void _broadcast(List<WebSocket> clients, int count) {
  final data = jsonEncode({'count': count});
  // 清理已关闭的 socket
  clients.removeWhere((c) => c.readyState != WebSocket.open);
  for (var client in clients) {
    try {
      client.add(data);
    } catch (e) {
      print('广播失败，移除客户端');
    }
  }
}