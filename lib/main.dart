import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '伪联机计数器',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const CounterPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class CounterPage extends StatefulWidget {
  const CounterPage({super.key});
  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> {
  WebSocketChannel? _channel;
  int _playerId = 0;
  int _count = 0;
  String _status = '未连接';
  bool _isConnecting = false;
  late SharedPreferences _prefs;

  @override
  void initState() {
    super.initState();
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    if (mounted) _connect();
  }

  void _connect() async {
    if (_isConnecting) return;
    _isConnecting = true;

    // 关闭旧连接
    if (_channel != null) {
      try {
        await _channel!.sink.close();
      } catch (_) {}
    }

    setState(() {
      _status = '连接中...';
    });

    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted) {
      _isConnecting = false;
      return;
    }

    try {
      _channel = WebSocketChannel.connect(Uri.parse('ws://localhost:8080/ws'));

      // 1. 读取本地保存的ID
      final savedId = _prefs.getInt('playerId');

      // 2. 发送 restore 消息
      _channel!.sink.add(jsonEncode({
        'type': 'restore',
        'savedId': savedId,
      }));

      _channel!.stream.listen(
        (data) {
          final map = jsonDecode(data);
          if (mounted) {
            setState(() {
              if (map['playerId'] != null) {
                _playerId = map['playerId'];
                _count = map['count'];
                _status = '玩家 $_playerId | 在线: $_count';

                // 保存ID到本地
                _prefs.setInt('playerId', _playerId);
              } else if (map['count'] != null) {
                _count = map['count'];
                _status = '玩家 $_playerId | 在线: $_count';
              }
            });
          }
        },
        onError: (_) => setState(() => _status = '连接错误'),
        onDone: () => setState(() => _status = '已断开'),
      );
    } catch (e) {
      setState(() => _status = '连接失败');
    } finally {
      _isConnecting = false;
    }
  }

  @override
  void dispose() {
    _channel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('伪联机计数器'), centerTitle: true),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.people_alt, size: 100, color: Colors.blue.shade700),
            const SizedBox(height: 30),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Column(
                children: [
                  Text(
                    '玩家 ID: $_playerId',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.blue.shade800),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '在线人数: $_count',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Colors.green.shade700),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),
            ElevatedButton.icon(
              onPressed: _isConnecting ? null : _connect,
              icon: const Icon(Icons.refresh),
              label: Text(_isConnecting ? '连接中...' : '重新连接'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                textStyle: const TextStyle(fontSize: 18),
                backgroundColor: Colors.green,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '刷新页面 = 老玩家重连 | 新开窗口 = 新玩家加入',
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}