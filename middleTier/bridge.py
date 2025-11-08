# bridge_app.py
import asyncio
import json
import logging
import os
from typing import Optional, Set

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Body, HTTPException
from fastapi.responses import JSONResponse
import websockets

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("bridge")

# ========================
# 配置
# ========================
SERVER_WS_URL = os.getenv("SERVER_WS_URL", "ws://localhost:8080")  # Dart WebSocket 服务端
RECONNECT_SECONDS = float(os.getenv("RECONNECT_SECONDS", "2.0"))

# ========================
# 全局状态
# ========================
app = FastAPI(title="AI Relay Bridge", version="1.0")

# 与 Dart 服务端的 WS 连接（单连接）
server_ws = None  # type: Optional[websockets.WebSocketClientProtocol]
server_ws_lock = asyncio.Lock()

# 与 Python 脚本的 WS 连接（可多个）
python_clients: Set[WebSocket] = set()
python_clients_lock = asyncio.Lock()

# 仅转发以下四类消息，其它消息忽略（你也可选择全部转发）
SERVER_TO_PY_TYPES = {"ai_judge_question", "ai_validate_final_answer"}
PY_TO_SERVER_TYPES = {"ai_judge_question_result", "ai_validate_final_answer_result"}


# ========================
# 工具函数
# ========================
async def ensure_server_connected():
    """确保与 Dart 服务端的 WS 连接可用（断线自动重连）。"""
    global server_ws
    async with server_ws_lock:
        if server_ws and server_ws.open:
            return server_ws
        # 断线重连
        while True:
            try:
                logger.info(f"Connecting to server WS: {SERVER_WS_URL} ...")
                server_ws = await websockets.connect(SERVER_WS_URL, max_size=None)
                logger.info("Connected to server WS.")
                return server_ws
            except Exception as e:
                logger.warning(f"Connect failed: {e}. Retry in {RECONNECT_SECONDS}s.")
                await asyncio.sleep(RECONNECT_SECONDS)


async def broadcast_to_python(message: dict):
    """把服务端发来的特定消息转发给所有 Python WS 客户端。"""
    text = json.dumps(message, ensure_ascii=False)
    async with python_clients_lock:
        to_remove = []
        for ws in python_clients:
            try:
                await ws.send_text(text)
            except Exception:
                to_remove.append(ws)
        for ws in to_remove:
            python_clients.discard(ws)


async def forward_to_server(message: dict):
    """把 Python 发送来的结果转发给服务端 WS。"""
    ws = await ensure_server_connected()
    try:
        await ws.send(json.dumps(message, ensure_ascii=False))
    except Exception as e:
        logger.error(f"Send to server failed: {e}")
        raise


async def server_reader_loop():
    """后台任务：持续读取服务端 WS 的消息，并转发到 Python。"""
    global server_ws
    while True:
        try:
            ws = await ensure_server_connected()
            async for raw in ws:
                try:
                    msg = json.loads(raw)
                except Exception:
                    # 不是 JSON，忽略
                    continue
                msg_type = msg.get("type")
                if msg_type in SERVER_TO_PY_TYPES:
                    await broadcast_to_python(msg)
        except Exception as e:
            logger.warning(f"Server WS reader error: {e}. Reconnecting ...")
            # 触发重连
            await asyncio.sleep(RECONNECT_SECONDS)


@app.on_event("startup")
async def _startup():
    asyncio.create_task(server_reader_loop())


# ========================
# 1 Python 侧 WebSocket
# ========================
@app.websocket("/python/ws")
async def python_ws(ws: WebSocket):
    await ws.accept()
    async with python_clients_lock:
        python_clients.add(ws)
    logger.info("Python WS connected.")

    try:
        while True:
            text = await ws.receive_text()
            # Python 侧也可以通过 WS 主动把“result”传回来
            try:
                msg = json.loads(text)
            except Exception:
                continue
            msg_type = msg.get("type")
            if msg_type in PY_TO_SERVER_TYPES:
                await forward_to_server(msg)
            # 其它类型忽略（桥只是转发）
    except WebSocketDisconnect:
        logger.info("Python WS disconnected.")
    finally:
        async with python_clients_lock:
            python_clients.discard(ws)


# ========================
# 2 Python 侧 HTTP（可选）
#    若不想用 WS 回推结果，可以用这两个 HTTP 接口
# ========================
@app.post("/bridge/ai/judge_question_result")
async def http_ai_judge_question_result(payload: dict = Body(...)):
    """
    期望 payload 结构：
    {
      "type": "ai_judge_question_result",
      "request_id": "...",
      "judge_answer": "是|否|未知",
      "score_result": {"score": 0|1|2|3, "justification": "..."}
    }
    """
    if payload.get("type") != "ai_judge_question_result":
        raise HTTPException(status_code=400, detail="type must be ai_judge_question_result")
    await forward_to_server(payload)
    return JSONResponse({"ok": True, "request_id": payload.get("request_id")})


@app.post("/bridge/ai/validate_final_answer_result")
async def http_ai_validate_final_answer_result(payload: dict = Body(...)):
    """
    期望 payload 结构：
    {
      "type": "ai_validate_final_answer_result",
      "request_id": "...",
      "validation_status": "APPROACHING|CORRECT|INCORRECT|UNKNOWN",
      "feedback": "..."
    }
    """
    if payload.get("type") != "ai_validate_final_answer_result":
        raise HTTPException(status_code=400, detail="type must be ai_validate_final_answer_result")
    await forward_to_server(payload)
    return JSONResponse({"ok": True, "request_id": payload.get("request_id")})


# ========================
# main 入口
# ========================
if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8010)
