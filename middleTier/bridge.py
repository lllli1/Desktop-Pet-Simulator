# bridge.py (V2 最终/生产版 - 已修复 .open Bug)

import asyncio
import json
import logging
import os
from typing import Optional

import httpx
import uvicorn
import websockets
from websockets.connection import State  # <--- [!! 1. 新增的导入 !!]
from fastapi import FastAPI, Body, HTTPException
from fastapi.responses import JSONResponse

# --- 1. 日志配置 ---
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("bridge")

# --- 2. 配置 ---
SERVER_WS_URL = os.getenv("SERVER_WS_URL", "ws://127.0.0.1:8080")
AI_BASE_URL = os.getenv("AI_BASE_URL", "http://127.0.0.1:5000")
RECONNECT_SECONDS = float(os.getenv("RECONNECT_SECONDS", "2.0"))

# --- 3. 全局状态 ---
app = FastAPI(title="AI Relay Bridge (V2)", version="2.0-final-fix")
server_ws = None  # type: Optional[websockets.WebSocketClientProtocol]
server_ws_lock = asyncio.Lock()
ai_client = httpx.AsyncClient(base_url=AI_BASE_URL, timeout=30.0)
SERVER_TO_PY_TYPES = {"ai_judge_question", "ai_validate_final_answer"}

# --- 4. 核心功能：连接和转发 ---

async def ensure_server_connected():
    """确保与 Dart 服务端的 WS 连接可用（断线自动重连）。"""
    global server_ws
    async with server_ws_lock:
        
        # [!! 2. 修复的行 !!] (原为 .open)
        if server_ws and server_ws.state == State.OPEN:
            return server_ws
        
        while True:
            try:
                logger.info(f"Connecting to server WS: {SERVER_WS_URL} ...")
                server_ws = await websockets.connect(SERVER_WS_URL, max_size=None)
                logger.info("Connected to server WS.")
                return server_ws
            except Exception as e:
                logger.warning(f"Connect failed: {e}. Retry in {RECONNECT_SECONDS}s.")
                await asyncio.sleep(RECONNECT_SECONDS)

async def forward_to_server(message: dict):
    """把 Python 侧的结果转发给服务端 WS。"""
    ws = await ensure_server_connected()
    try:
        await ws.send(json.dumps(message, ensure_ascii=False))
        logger.info(f"Sent result to server (type={message.get('type')}, id={message.get('request_id')})")
    except Exception as e:
        logger.error(f"Send to server failed: {e}")
        # 这里不再 raise，防止一个发送失败导致整个循环崩溃
        logger.error(f"Forward to server failed: {e}")


# --- 5. 核心功能：调用 AI (app.py) ---

async def call_app_judge_question(task: dict, req_id: str):
    """调用 app.py 的 /ai/judge_question 接口"""
    payload = {
        "request_id": req_id,
        "story_truth": task.get("story_truth"),
        "history": task.get("history") or [],
        "new_question": task.get("new_question"),
    }
    try:
        resp = await ai_client.post("/ai/judge_question", json=payload)
        resp.raise_for_status() 
        ai_data = resp.json()
        await forward_to_server({
            "type": "ai_judge_question_result",
            "request_id": req_id,
            "judge_answer": ai_data.get("judge_answer"),
            "score_result": ai_data.get("score_result"),
        })
    except Exception as e:
        # 日志中显示更详细的错误
        logger.error(f"Task {req_id} failed in call_app_judge_question: {e}", exc_info=True)
        await forward_to_server({
            "type": "ai_judge_question_result",
            "request_id": req_id,
            "error": str(e),
        })

async def call_app_validate_final_answer(task: dict, req_id: str):
    """调用 app.py 的 /ai/validate_final_answer 接口"""
    payload = {
        "request_id": req_id,
        "story_truth": task.get("story_truth"),
        "final_answer_text": task.get("final_answer_text"),
    }
    try:
        resp = await ai_client.post("/ai/validate_final_answer", json=payload)
        resp.raise_for_status()
        ai_data = resp.json()
        await forward_to_server({
            "type": "ai_validate_final_answer_result",
            "request_id": req_id,
            "validation_status": ai_data.get("validation_status"),
            "feedback": ai_data.get("feedback"),
        })
    except Exception as e:
        logger.error(f"Task {req_id} failed in call_app_validate_final_answer: {e}", exc_info=True)
        await forward_to_server({
            "type": "ai_validate_final_answer_result",
            "request_id": req_id,
            "error": str(e),
        })

# --- 6. 核心循环：读取 Dart 消息 ---

async def handle_ai_task(task: dict, req_id: str, msg_type: str):
    if msg_type == "ai_judge_question":
        await call_app_judge_question(task, req_id)
    elif msg_type == "ai_validate_final_answer":
        await call_app_validate_final_answer(task, req_id)

async def server_reader_loop():
    """后台任务：持续读取服务端 WS 的消息，并调用 app.py"""
    global server_ws
    while True:
        try:
            ws = await ensure_server_connected()
            async for raw in ws:
                try:
                    msg = json.loads(raw)
                except Exception:
                    logger.warning(f"Received non-JSON: {raw}")
                    continue
                
                msg_type = msg.get("type")
                req_id = msg.get("request_id")
                
                logger.info(f"Received task from server, type={msg_type}, id={req_id}")

                if msg_type in SERVER_TO_PY_TYPES:
                    asyncio.create_task(handle_ai_task(msg, req_id, msg_type))
                
        except Exception as e:
            logger.warning(f"Server WS reader error: {e}. Reconnecting ...")
            # 在重连前将 server_ws 设为 None，强制 ensure_server_connected 重新连接
            async with server_ws_lock:
                server_ws = None 
            await asyncio.sleep(RECONNECT_SECONDS)

# --- 7. (V2) 启动事件 [!!! 关键修复 !!!] ---
@app.on_event("startup")
async def _startup():
    asyncio.create_task(server_reader_loop())

# --- 8. (V2) 保留的测试接口 (与主流程无关) ---
@app.post("/test/http_to_dart")
async def test_http_to_dart(payload: dict = Body(...)):
    try:
        await forward_to_server(payload)
        return JSONResponse({"ok": True, "message": "Sent to server."})
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/test/http_to_ai")
async def test_http_to_ai():
    try:
        resp = await ai_client.post("/ai/judge_question", json={
            "request_id": "test-http-to-ai",
            "story_truth": "汤底", "history": [], "new_question": "测试"
        })
        return resp.json()
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# --- 9. 启动 ---
if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8010)
