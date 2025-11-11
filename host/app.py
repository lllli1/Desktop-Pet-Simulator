import json
from flask import Flask, request, jsonify
from openai import OpenAI
from openai.types.chat import ChatCompletionMessageParam
# ====== 放在 bridge.py / bridge_app.py 顶部已有 import 之后 ======
from fastapi import Body
# --- 1. 初始化 -----------------------------------------------------

# 初始化 Flask 应用
app = Flask(__name__)

# 直接显式写入 API Key（仅用于测试，生产环境请使用环境变量）
SILICONFLOW_API_KEY = "sk-rkxhkuqssjrntenzdbdazzydurdqhqqxvsmqxvxggduvufqk"  # 请替换为真实的 API Key

client = OpenAI(
    base_url='https://api.siliconflow.cn/v1',
    api_key=SILICONFLOW_API_KEY  # 直接使用显式的 API Key
)

# 定义将要使用的 AI 模型
AI_MODEL = "Pro/deepseek-ai/DeepSeek-V3.2-Exp" 

# --- 2. V10 AI 提示词模板 ---------------------------------------------

# 提示词 1：用于 /ai/judge_question (合并了法官和计分员)
PROMPT_JUDGE_SCORE = """
你是海龟汤（情境猜谜）的AI法官和计分员。
你的任务是：
1.  根据[汤底]和[历史问答]，判断玩家的[新问题]是"是"、"否"还是"不相关"。
2.  评估[新问题]对推进游戏的重要性，给出 0-3 分的评分和理由。

[汤底]:
{story_truth}

[历史问答]:
{history}

[新问题]:
{new_question}

你的回答：
你必须只返回一个 JSON 对象，绝不要添加任何其他文字。
JSON 格式如下：
{{"judge_answer": "<'是', '否', 或 '不相关'>", "score": <0-3 的数字>, "justification": "<一句简短的评分理由>"}}
"""

# 提示词 2：用于 /ai/validate_final_answer
PROMPT_VALIDATE_ANSWER = """
你是海龟汤（情境猜谜）的AI主裁。你的任务是判断玩家的[最终答案]是否猜中了[汤底]的完整真相。

裁决标准：
1.  `CORRECT` (正确): 玩家的答案几乎完整、准确地描述了[汤底]的核心真相。
2.  `APPROACHING` (接近了): 玩家猜对了一部分关键线索（例如猜对了地点，但猜错了动机），但离完整真相还有差距。
3.  `INCORRECT` (不对): 玩家的答案与[汤底]的真相完全不符。

[汤底]:
{story_truth}

[玩家的最终答案]:
{final_answer_text}

你的回答：
你必须只返回一个 JSON 对象，绝不要添加任何其他文字。
JSON 格式如下：
{{"validation_status": "<'CORRECT', 'APPROACHING', 或 'INCORRECT'>", "feedback": "<一句对玩家答案的简短评语>"}}
"""

# --- 3. 辅助函数 -----------------------------------------------------

def format_history(history_list: list) -> str:
    """辅助函数，把 history 列表转换成 AI 易读的格式"""
    if not history_list:
        return "无"
    # 转换: [{"question": "q1", "answer": "a1"}] -> "Q: q1 A: a1"
    return "\n".join([f"Q: {item.get('question', '')} A: {item.get('answer', '')}" for item in history_list])

def call_ai_model(prompt: str) -> dict:
    """
    统一的 AI 调用函数。
    发送提示词给 SiliconFlow API 并获取解析后的 JSON 响应。
    """
    messages: list[ChatCompletionMessageParam] = [
        {"role": "user", "content": prompt}
    ]
    
    # 调用 SiliconFlow API (关键：stream=False, response_format="json_object")
    response = client.chat.completions.create(
        model=AI_MODEL,
        messages=messages,
        stream=False,           # **关键：必须关闭流式**
        temperature=0.1,        # 低温以确保 JSON 输出的稳定性
        response_format={"type": "json_object"} # **关键：强制 JSON 输出**
    )
    
    # 提取并解析 AI 返回的 JSON 字符串
    ai_response_content = response.choices[0].message.content
    if not ai_response_content:
        raise ValueError("AI returned an empty response.")
        
    return json.loads(ai_response_content)

# --- 4. API 1: 循环提问 (The Q&A Loop) ----------------------------
@app.route('/ai/judge_question', methods=['POST'])
def handle_judge_question():
    data = request.json
    request_id = data.get('request_id')

    try:
        # 1. 准备 V10 提示词
        prompt = PROMPT_JUDGE_SCORE.format(
            story_truth=data.get('story_truth'),
            history=format_history(data.get('history')),
            new_question=data.get('new_question')
        )
        
        # 2. 调用 AI (已包含 JSON 解析)
        ai_data = call_ai_model(prompt)
        
        # 3. 构建 V9 成功响应
        final_response = {
            "request_id": request_id,
            "judge_answer": ai_data.get('judge_answer'),
            "score_result": {
                "score": ai_data.get('score'),
                "justification": ai_data.get('justification')
            }
        }
        return jsonify(final_response)

    except Exception as e:
        # 4. V9 错误处理
        error_response = {
            "request_id": request_id,
            "error": f"AI service failed: {str(e)}"
        }
        # 返回 500 Internal Server Error，并附带 V9 错误 JSON
        return jsonify(error_response), 500

# --- 5. API 2: 提交最终答案 (The Answer) --------------------------
@app.route('/ai/validate_final_answer', methods=['POST'])
def handle_validate_final_answer():
    data = request.json
    request_id = data.get('request_id')

    try:
        # 1. 准备 V10 提示词
        prompt = PROMPT_VALIDATE_ANSWER.format(
            story_truth=data.get('story_truth'),
            final_answer_text=data.get('final_answer_text')
        )

        # 2. 调用 AI (已包含 JSON 解析)
        ai_data = call_ai_model(prompt)
        
        # 3. 构建 V9 成功响应
        final_response = {
            "request_id": request_id,
            "validation_status": ai_data.get('validation_status'),
            "feedback": ai_data.get('feedback')
        }
        return jsonify(final_response)

    except Exception as e:
        # 4. V9 错误处理
        error_response = {
            "request_id": request_id,
            "error": f"AI service failed: {str(e)}"
        }
        return jsonify(error_response), 500













# --- 6. 启动 Flask 服务 -------------------------------------------
if __name__ == '__main__':
    # 注意：在生产环境中，你不应该使用 app.run()
    # 而应该使用 Gunicorn 或 uWSGI 来启动，例如:
    # gunicorn -w 4 -b 0.0.0.0:5000 app:app
    
    # host='0.0.0.0' 允许从外部访问（在我们的单机开发环境中是必须的）
    # debug=True 允许热重载，但在生产中必须关闭
    app.run(host='0.0.0.0', port=5000, debug=True)