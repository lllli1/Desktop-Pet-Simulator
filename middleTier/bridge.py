# bridge.py (V2.2 - 已添加 final_answer 转发)

import asyncio
import json
import logging
import os
from typing import Optional, Set
from contextlib import asynccontextmanager 

import httpx
import uvicorn
import websockets
from websockets.connection import State
from fastapi import FastAPI, Body, HTTPException
from fastapi.responses import JSONResponse

# --- 1. 日志配置 ---
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("bridge")

# --- 2. 配置 ---
SERVER_WS_URL = os.getenv("SERVER_WS_URL", "ws://127.0.0.1:8080")
AI_BASE_URL = os.getenv("AI_BASE_URL", "http://127.0.0.1:5000")
RECONNECT_SECONDS = float(os.getenv("RECONNECT_SECONDS", "2.0"))
PET_WS_PORT = int(os.getenv("PET_WS_PORT", "8011"))

# --- lifespan 函数 ---
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup (启动时)
    logger.info("Application starting up...")
    asyncio.create_task(server_reader_loop())
    asyncio.create_task(start_pet_ws_server())
    logger.info("Background tasks created.")
    
    yield # 应用在这里运行
    
    # Shutdown (关闭时, 可选)
    logger.info("Application shutting down...")

# --- 3. 全局状态 ---
app = FastAPI(
    title="AI Relay Bridge", 
    version="2.2-final-forward", 
    lifespan=lifespan 
)
server_ws = None  # type: Optional[websockets.WebSocketClientProtocol]
server_ws_lock = asyncio.Lock()
ai_client = httpx.AsyncClient(base_url=AI_BASE_URL, timeout=30.0)
SERVER_TO_PY_TYPES = {"ai_judge_question", "ai_validate_final_answer"}

pet_clients: Set[websockets.WebSocketServerProtocol] = set() 
pet_ws_lock = asyncio.Lock()

# --- 4. 核心功能：连接和转发 ---

async def ensure_server_connected():
    """确保与 Dart 服务端的 WS 连接可用（断线自动重连）。"""
    global server_ws
    async with server_ws_lock:
        
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
        logger.error(f"Forward to server failed: {e}")

async def broadcast_to_pets(message: dict):
    """把消息广播给所有连接的桌宠客户端"""
    async with pet_ws_lock:
        if not pet_clients:
            return
        
        json_message = json.dumps(message, ensure_ascii=False)
        tasks = [client.send(json_message) for client in pet_clients]
        results = await asyncio.gather(*tasks, return_exceptions=True)
        
        for res in results:
            if isinstance(res, Exception):
                logger.warning(f"Failed to send message to a pet client: {res}")

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

        # (已有的) 转发给桌宠
        pet_message = ai_data.copy()
        pet_message['type'] = 'ai_judge_result' 
        pet_message['request_id'] = req_id      
        asyncio.create_task(broadcast_to_pets(pet_message))
        
        # (已有的) 转发给主服务器
        await forward_to_server({
            "type": "ai_judge_question_result",
            "request_id": req_id,
            "judge_answer": ai_data.get("judge_answer"),
            "score_result": ai_data.get("score_result"),
        })
    except Exception as e:
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

        # --- [!! 🔥 新增: 将最终验证结果也转发给桌宠 !!] ---
        pet_message = ai_data.copy()
        pet_message['type'] = 'ai_validate_final_result' # (给桌宠一个新的专属类型)
        pet_message['request_id'] = req_id      
        asyncio.create_task(broadcast_to_pets(pet_message))
        # --- [!! 🔥 新增结束 !!] ---

        # (已有的) 转发给主服务器
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
                    # (已有的) 转发收到的 *任务* 给桌宠
                    asyncio.create_task(broadcast_to_pets(msg)) 
                    # (已有的) 处理任务
                    asyncio.create_task(handle_ai_task(msg, req_id, msg_type)) 
                
        except Exception as e:
            logger.warning(f"Server WS reader error: {e}. Reconnecting ...")
            async with server_ws_lock:
                server_ws = None 
            await asyncio.sleep(RECONNECT_SECONDS)

# --- 桌宠 WebSocket 服务器逻辑 ---
async def handle_pet_client(websocket: websockets.WebSocketServerProtocol):
    """处理单个桌宠客户端连接"""
    async with pet_ws_lock:
        pet_clients.add(websocket)
    logger.info(f"Pet client connected: {websocket.remote_address}")
    try:
        await websocket.wait_closed()
    finally:
        async with pet_ws_lock:
            pet_clients.remove(websocket)
        logger.info(f"Pet client disconnected: {websocket.remote_address}")

async def start_pet_ws_server():
    """启动桌宠专用的 WebSocket 服务器"""
    logger.info(f"Starting pet WebSocket server on ws://0.0.0.0:{PET_WS_PORT}")
    try:
        async with websockets.serve(handle_pet_client, "0.0.0.0", PET_WS_PORT):
            await asyncio.Future()  # 保持服务运行
    except Exception as e:
        logger.error(f"Pet WS server failed: {e}", exc_info=True)


# --- 保留的测试接口 ---
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

# --- 启动 ---
if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8010)
