// server.dart (完整内容 - 已集成 SQLite)
import 'dart:io';
import 'dart:convert';
import 'dart:math'; 
import 'package:sqlite3/sqlite3.dart'; // [!! 新增 !!]

// [AI 集成] 路径不变
final String GAME_PATH = '/ws/game';
final String BRIDGE_PATH = '/ws/bridge';

// [!! 新增 !!]
// 数据库初始化函数
Database _initDatabase() {
  print('[DB] Initializing database...');
  final db = sqlite3.open('stories.db'); // 这将在服务器根目录创建文件
  
  // 创建表 (如果不存在)
  db.execute('''
    CREATE TABLE IF NOT EXISTS stories (
      id TEXT PRIMARY KEY NOT NULL,
      storyFace TEXT NOT NULL,
      storyBottom TEXT NOT NULL,
      imgURL TEXT
    );
  ''');
  
  // 检查表是否为空，如果为空则插入一些示例数据
  final ResultSet check = db.select('SELECT COUNT(*) as count FROM stories');
  if (check.first['count'] == 0) {
    print('[DB] Database is empty. Inserting sample data...');
    db.execute('''
      INSERT INTO stories (id, storyFace, storyBottom, imgURL) VALUES
      (
        'story1',
        '（汤面）一个男人死在沙漠中，手里握着一根火柴。',
        '（汤底）男人和同伴乘坐热气球，热气球超重。他们抽火柴，男人抽到短的，被迫跳下。',
        'https://images.unsplash.com/photo-1506703121853-33362673a58d?fit=crop&w=1200&q=80'
      ),
      (
        'story2',
        '（汤面）一个女人买了一双新鞋，当天她就死了。',
        '（汤底）女人是马戏团的飞刀表演助手。她的新鞋是高跟鞋，比平时高了5厘米。她的搭档（丈夫）扔飞刀时没有调整高度，失手杀死了她。',
        'https://images.unsplash.com/photo-1543163521-1bf539c55dd2?fit=crop&w=1200&q=80'
      );
    ''');
    print('[DB] Sample data inserted.');
  }
  
  print('[DB] Database initialized successfully.');
  return db;
}


void main(List<String> args) async {
  final port = args.isNotEmpty ? int.tryParse(args.first) ?? 8080 : 8080;
  
  // [!! 修改 !!]
  // 初始化数据库并将其传递给服务器
  final db = _initDatabase();
  
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  print('WebSocket server listening on ws://localhost:$port');
  print('  - 游戏客户端 (main.dart) 请连接: ws://localhost:$port$GAME_PATH');
  print('  - AI 网桥 (bridge.py)   请连接: ws://localhost:$port$BRIDGE_PATH');

  final wsServer = _SoupServer(db); // [!! 修改 !!] 传入 db
  
  await for (HttpRequest req in server) {
    if (WebSocketTransformer.isUpgradeRequest(req)) {
      if (req.uri.path == GAME_PATH) {
        final socket = await WebSocketTransformer.upgrade(req);
        wsServer.handleClient(socket);
      } else if (req.uri.path == BRIDGE_PATH) {
        final socket = await WebSocketTransformer.upgrade(req);
        wsServer.handleBridge(socket);
      } else {
        req.response
          ..statusCode = HttpStatus.notFound
          ..write('Unknown WebSocket path')
          ..close();
      }
    } else {
      req.response
        ..statusCode = HttpStatus.forbidden
        ..write('WebSocket only')
        ..close();
    }
  }
}

// [!! 修改 !!]
// _StoryData 类现在包含 imgURL
class _StoryData {
  final String id;
  final String storyFace; 
  final String storyBottom; 
  final String? imgURL; // (可以为 null)
  _StoryData(this.id, this.storyFace, this.storyBottom, this.imgURL);
}

class _SoupServer {
  final Map<WebSocket, int> _connToId = {};
  final Map<int, WebSocket> _idToConn = {};
  WebSocket? _bridgeChannel;
  
  final Database _db; // [!! 新增 !!] 数据库实例

  String _currentStoryBottom = ""; 
  String? _currentStoryImgUrl = ""; // [!! 新增 !!]
  
  int? _finalGuesserId; 

  int _nextId = 1;
  bool running = false;
  bool waitingOpening = false;
  bool hostOpeningUsed = false;
  int? speakingId;
  int round = 1;
  List<int> order = [];
  bool awaitingVerdict = false;

  final Map<int, int> scores = {};
  final Map<int, String> avatarsB64 = {};
  final int _maxHistory = 200;
  final List<Map<String, dynamic>> _histOrdered = [];
  final List<Map<String, dynamic>> _histFree = [];
  
  // [!! 修改 !!]
  // 构造函数现在需要数据库
  _SoupServer(this._db);

  Map<String, T> _stringKeys<T>(Map<int, T> m) {
    final out = <String, T>{};
    m.forEach((k, v) => out['$k'] = v);
    return out;
  }

  // [!! 修改 !!]
  // 重写了数据库访问函数，使其使用 SQLite
  Future<_StoryData> _fetchStoryFromDatabase(String? storyId) async {
    // (不再需要 Future.delayed，因为数据库查询是 I/O 操作)
    
    ResultSet results;
    
    if (storyId != null) {
      // 尝试按 ID 获取
      results = _db.select('SELECT * FROM stories WHERE id = ?', [storyId]);
    } else {
      // 如果没有 ID，随机获取一个
      results = _db.select('SELECT * FROM stories ORDER BY RANDOM() LIMIT 1');
    }

    if (results.isEmpty) {
      // 如果数据库为空或找不到
      print('[DB] ❌ Error: No stories found in database.');
      // 返回一个安全的默认值
      return _StoryData(
        'error', 
        '（错误）数据库中没有找到故事。', 
        '（错误）请联系主持人检查服务器。', 
        null
      );
    }
    
    final row = results.first;
    return _StoryData(
      row['id'] as String,
      row['storyFace'] as String,
      row['storyBottom'] as String,
      row['imgURL'] as String?, // (可以是 null)
    );
  }

  void handleBridge(WebSocket ws) {
    print('[Server] ✅ AI Bridge (bridge.py) connected!');
    _bridgeChannel = ws;
    ws.listen(
      _handleBridgeMessage,
      onDone: () {
        print('[Server] ❌ AI Bridge disconnected.');
        _bridgeChannel = null;
      },
      onError: (e) {
        print('[Server] ❌ AI Bridge error: $e');
        _bridgeChannel = null;
      },
    );
  }

  // (此函数包含排行榜逻辑，无需改动)
  void _handleBridgeMessage(dynamic message) {
    print('[Server] ⬅️ Received AI Result from bridge: $message');
    try {
      final data = json.decode(message);
      final type = data['type'];

      if (type == 'ai_judge_question_result') {
        if (data['error'] != null) {
          print('[Server] ⚠️ AI returned an error: ${data['error']}');
          return;
        }
        final judgeAnswer = data['judge_answer']?.toString() ?? '...';
        final scoreResult = data['score_result'];
        if (scoreResult is Map && speakingId != null) {
          final score = scoreResult['score'];
          if (score is int && score > 0) {
            print('[Server] 🤖 Applying AI score $score to player $speakingId');
            _applyScore(speakingId!, score); 
          }
        }
        if (awaitingVerdict && speakingId != null) {
          print('[Server] 🤖 AI is submitting verdict: "$judgeAnswer"');
          _onVerdict(judgeAnswer);
        } else {
          print('[Server] ⚠️ AI sent a verdict, but we were not awaiting one.');
        }
      }
      
      else if (type == 'ai_validate_final_answer_result') {
        final status = data['validation_status']?.toString() ?? 'INCORRECT';
        final feedback = data['feedback']?.toString() ?? '...';

        final int? guesserId = _finalGuesserId;
        _finalGuesserId = null; 
        
        if (guesserId == null) {
          print('[Server] ⚠️ Received final answer result, but no guesser was stored.');
          return;
        }

        final bool correct = (status == 'CORRECT');
        
        if (correct) {
          // --- 逻辑：正确 ---
          print('[Server] 🤖  guess correct for $guesserId. Applying +5 score.');
          scores[guesserId] = (scores[guesserId] ?? 0) + 5;
          final finalScore = scores[guesserId]; 
          
          final leaderboard = _generateLeaderboard();
          
          _broadcast({
            "type": "game_over",
            "guesserId": guesserId,
            "correct": true,
            "feedback": feedback,
            "finalScore": finalScore,
            "leaderboard": leaderboard, // 发送排行榜
          });
          
          _onStop(triggeredByGuess: true); // 传递参数避免重复广播

        } else {
          // --- 逻辑：错误 ---
          print('[Server] 🤖  guess incorrect for $guesserId. Game continues.');
          final WebSocket? guesserConn = _idToConn[guesserId];
          if (guesserConn != null) {
            _send(guesserConn, {
              "type": "final_guess_result", 
              "correct": false,
              "feedback": feedback,
            });
          }
        }
      }

    } catch (e) {
      print('[Server] Error parsing bridge message: $e');
    }
  }

  // (此函数包含 -3 分逻辑，无需改动)
  void handleClient(WebSocket ws) {
    final id = _assignId(ws);
    final isHost = (id == 1);

    _send(ws, {'type': 'welcome', 'playerId': id, 'isHost': isHost});
    _send(ws, {
      'type': 'bulkSync',
      'ordered': _histOrdered,
      'free': _histFree,
      'scores': _stringKeys(scores),
      'avatars': _stringKeys(avatarsB64),
    });
    _broadcastState();

    ws.listen((data) {
      try {
        final msg = jsonDecode(data);
        final type = msg['type'];

        switch (type) {
          case 'restore':
            _send(ws, {'type': 'welcome', 'playerId': id, 'isHost': isHost});
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
                final storyId = msg['storyId']?.toString();
                _onStart(storyId); 
                break;
              case 'stop':
                _onStop(); // 默认是主持人停止
                break;
              case 'verdict':
                print('[Server] 👨‍⚖️ Host is submitting verdict manually.');
                _onVerdict((msg['verdict'] ?? '').toString());
                break;
              case 'opening':
                 print('[Server] ⚠️ "opening" action is deprecated (now automated).');
                break;
              case 'skipOpening':
                 print('[Server] ⚠️ "skipOpening" action is deprecated (now automated).');
                break;
              case 'score':
                print('[Server] ⚠️ "score" action is deprecated (now automated by AI).');
                break;
            }
            break;

          case 'avatar':
            final pngB64 = (msg['pngB64'] ?? '').toString();
            if (pngB64.isEmpty) break;
            if (pngB64.length > 140000) break;
            avatarsB64[id] = pngB64;
            final objAvatar = {
              'type': 'avatar',
              'id': id,
              'pngB64': pngB64,
              'ts': DateTime.now().toIso8601String(), 
            };
            _broadcast(objAvatar);
            _pushOrdered(objAvatar);
            _broadcastState();
            break;

          case 'chat':
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
            
            _sendTaskToAI(objChat); 

            awaitingVerdict = true;
            _broadcastState();
            break;

          case 'freechat':
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
            
          case 'final_guess':
            if (!running) break;
            final text = (msg['text'] ?? '').toString();
            final storyTruth = _currentStoryBottom;
            if (text.isEmpty || storyTruth.isEmpty) break;

            final int guesserId = id;
            final int currentScore = scores[guesserId] ?? 0;

            if (currentScore < 3) {
              print('[Server] ⚠️ Player $guesserId tried to guess (score $currentScore < 3).');
              final WebSocket? guesserConn = _idToConn[guesserId];
              if (guesserConn != null) {
                _send(guesserConn, {
                  "type": "final_guess_result",
                  "correct": false,
                  "feedback": "积分不足 3 分，无法推测。游戏继续。",
                });
              }
              break; 
            }
            
            if (_bridgeChannel == null) {
              print('[Server] ⚠️ Bridge not connected. Cannot validate final answer.');
              final WebSocket? guesserConn = _idToConn[guesserId];
              if (guesserConn != null) {
                _send(guesserConn, {
                  "type": "final_guess_result",
                  "correct": false,
                  "feedback": "错误：AI 验证服务未连接。未扣除积分，游戏继续。",
                });
              }
              break; 
            }

            print('[Server] ➡️ Player $guesserId guessing. Deducting 3 points from $currentScore.');
            scores[guesserId] = currentScore - 3; 
            _finalGuesserId = guesserId;          
            _broadcastState();                  

            final aiTask = {
              "type": "ai_validate_final_answer",
              "request_id": "final-${DateTime.now().toIso8601String()}-$id",
              "story_truth": storyTruth,
              "final_answer_text": text,
            };
            
            print('[Server] ➡️ Forwarding final answer task to Bridge...');
            _bridgeChannel!.add(jsonEncode(aiTask));
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

  void _sendTaskToAI(Map<String, dynamic> chatObject) {
    if (_bridgeChannel == null) {
      print('[Server] ⚠️ Bridge not connected. AI cannot judge. Host must judge manually.');
      return;
    }
    final storyTruth = _currentStoryBottom; 
    if (storyTruth.isEmpty) {
       print('[Server] ⚠️ _currentStoryBottom is empty. AI cannot judge.');
       return;
    }
    final List<Map<String, String>> aiHistory = [];
    for (final h in _histOrdered) {
      if (h['type'] == 'chat') {
        aiHistory.add({"role": "user", "content": h['text']});
      } else if (h['type'] == 'verdict') {
        aiHistory.add({"role": "assistant", "content": h['verdict']});
      }
    }
    final aiTask = {
      "type": "ai_judge_question",
      "request_id": chatObject['ts'], 
      "story_truth": storyTruth, 
      "history": aiHistory,
      "new_question": chatObject['text'],
    };
    print('[Server] ➡️ Forwarding task to Bridge...');
    _bridgeChannel!.add(jsonEncode(aiTask));
  }

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

  // [!! 修改 !!]
  // (增加了重置逻辑，并存储/广播 imgURL)
  void _onStart(String? storyId) async { 
    print('[Server] Host started game. Fetching story (id: $storyId)...');

    // 1. [!! 新增 !!] 重置分数, 历史记录, 和轮次
    print('[Server] Resetting game state: Scores, History, Round.');
    scores.clear();
    _histOrdered.clear();
    _histFree.clear();
    
    // 2. [!! 新增 !!] 将所有当前连接的玩家分数重置为 0
    // (注意: 头像 avatarsB64 和 玩家列表 order 不重置)
    for (final id in _idToConn.keys) {
      scores[id] = 0;
    }

    _StoryData storyData;
    try {
      // 3. [!! 修改 !!] 从真实数据库获取
      storyData = await _fetchStoryFromDatabase(storyId);
    } catch (e) {
      print('[Server] ❌ FATAL: Failed to fetch story from DB: $e');
      return;
    }
    
    // 4. [!! 修改 !!] 存储汤底和图片 URL
    _currentStoryBottom = storyData.storyBottom; 
    _currentStoryImgUrl = storyData.imgURL;
    
    // 5. 重置游戏状态
    running = true;
    waitingOpening = false; 
    hostOpeningUsed = true; 
    speakingId = null;
    round = 1; // 确保轮次重置为 1
    awaitingVerdict = false;
    _finalGuesserId = null; 

    final objStart = {
      'type': 'system',
      'text': '游戏开始！(分数已重置)', // 提示玩家分数已重置
      'ts': DateTime.now().toIso8601String(), 
    };
    _broadcast(objStart);
    _pushOrdered(objStart);

    // 6. [!! 修改 !!] 广播汤面时，带上 imgURL
    final objFace = {
      'type': 'opening', 
      'text': storyData.storyFace, 
      'imgURL': _currentStoryImgUrl, // [!! 新增 !!]
      'ts': DateTime.now().toIso8601String(), 
    };
    _broadcast(objFace);
    _pushOrdered(objFace); 

    _setFirstAudienceAsSpeaker();
    _broadcastState(); // 这将广播清空后的分数和状态
  }

  // [!! 修改 !!]
  // (增加了重置 imgURL 的逻辑)
  void _onStop({bool triggeredByGuess = false}) {
    running = false;
    waitingOpening = false;
    awaitingVerdict = false;
    _currentStoryBottom = ""; 
    _currentStoryImgUrl = null; // [!! 新增 !!] 重置图片
    _finalGuesserId = null; 

    if (!triggeredByGuess) {
      final leaderboard = _generateLeaderboard();

      final obj = {
        'type': 'game_over', 
        'feedback': '主持人已停止游戏。',
        'correct': false, 
        'ts': DateTime.now().toIso8601String(),
        'leaderboard': leaderboard, // 发送排行榜
      };
      _broadcast(obj);
      _pushOrdered(obj);
    }
    
    _broadcastState(); 
  }

  void _onOpening(String text) {
    print('[Server] ⚠️ _onOpening is deprecated.');
  }
  void _onSkipOpening() {
    print('[Server] ⚠️ _onSkipOpening is deprecated.');
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
  
  // (此函数用于生成排行榜，无需改动)
  List<Map<String, dynamic>> _generateLeaderboard() {
    final sortedScores = scores.entries.toList();
    sortedScores.sort((a, b) => b.value.compareTo(a.value));
    final topScores = sortedScores.take(3);
    return topScores.map((entry) {
      return {'id': entry.key, 'score': entry.value};
    }).toList();
  }

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
      'scores': _stringKeys(scores),
      'avatars': _stringKeys(avatarsB64)
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
