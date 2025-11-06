import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
  int _count = 0;
  String _status = '未连接';
  bool _isConnecting = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  void _connect() async {
    if (_isConnecting) return;
    _isConnecting = true;

    // 1. 关闭旧连接
    if (_channel != null) {
      try {
        await _channel!.sink.close();
      } catch (e) {
        debugPrint('关闭旧连接失败: $e');
      }
    }

    setState(() {
      _status = '连接中...';
    });

    // 2. 延迟 100ms 避免服务器来不及处理断开
    await Future.delayed(const Duration(milliseconds: 100));

    if (!mounted) {
      _isConnecting = false;
      return;
    }

    try {
      _channel = WebSocketChannel.connect(Uri.parse('ws://localhost:8080/ws'));

      _channel!.stream.listen(
        (data) {
          final map = jsonDecode(data);
          if (mounted) {
            setState(() {
              _count = map['count'];
              _status = '在线人数: $_count';
            });
          }
        },
        onError: (error) {
          if (mounted) {
            setState(() => _status = '连接错误');
          }
        },
        onDone: () {
          if (mounted) {
            setState(() => _status = '已断开');
          }
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() => _status = '连接失败');
      }
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
      appBar: AppBar(
        title: const Text('伪联机计数器'),
        centerTitle: true,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.people_alt, size: 100, color: Colors.blue.shade700),
            const SizedBox(height: 30),
            Text(
              _status,
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: _status.contains('在线') ? Colors.green : Colors.red,
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
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '提示：多开 Chrome 窗口即可模拟多人联机',
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}