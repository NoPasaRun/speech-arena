import json
import os
import re
import tempfile

import httpx
from fastapi import FastAPI, Form, HTTPException, UploadFile, File
from fastapi.responses import JSONResponse
from faster_whisper import WhisperModel

# AI-бэкенд тестовой сессии "свиданка" (см. TurnManager.gd в корне репозитория
# за полным контрактом). Делает две вещи на каждый ход:
#   1. Распознаёт речь игрока локально (faster-whisper, CPU, без ключей).
#   2. Просит внешний LLM (OpenAI-совместимый эндпоинт) сыграть роль NPC и
#      вернуть реплику + оценку хода в JSON.
# audio_base64 в ответе всегда пустой — озвучку NPC генерирует сам Godot-
# сервер через espeak-ng (см. TurnManager._synthesize_speech), так что здесь
# TTS не нужен.

LLM_URL = "http://tours-24.online:8080/v1/chat/completions"
LLM_MODEL = "qwen2.5-1.5b"
LLM_TIMEOUT_SEC = 90.0

WHISPER_MODEL_SIZE = "small"

SCENARIOS = {
    "restaurant_date": (
        "Ты — Аня, девушка на первом свидании с игроком в ресторане. "
        "Держись дружелюбно, немного застенчиво, живо реагируй на то, что "
        "говорит собеседник и что он делает. Отвечай ТОЛЬКО на русском "
        "языке, 1-2 короткими разговорными предложениями — это озвучат вслух "
        "текст-в-речь, поэтому не используй эмодзи и markdown. Никогда не "
        "используй китайские иероглифы, английские или любые другие "
        "нерусские слова — только русский язык."
    ),
}
DEFAULT_SCENARIO = "restaurant_date"

# CJK-диапазоны — маленькая модель иногда сваливается в китайский посреди
# русского ответа, это защитная зачистка на выходе (см. _clean_reply_text).
_CJK_RE = re.compile(r"[一-鿿㐀-䶿豈-﫿]+")
_MULTI_SPACE_RE = re.compile(r"[ \t]{2,}")
_MAX_REPLY_CHARS = 300

app = FastAPI()
_whisper = WhisperModel(WHISPER_MODEL_SIZE, device="cpu", compute_type="int8")


def _transcribe(audio_bytes: bytes) -> str:
    if not audio_bytes:
        return ""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        f.write(audio_bytes)
        tmp_path = f.name
    try:
        segments, _ = _whisper.transcribe(tmp_path, language="ru", beam_size=1)
        return " ".join(seg.text.strip() for seg in segments).strip()
    finally:
        os.unlink(tmp_path)


def _build_messages(scenario: str, transcript: str, events: list) -> list:
    persona = SCENARIOS.get(scenario, SCENARIOS[DEFAULT_SCENARIO])
    events_desc = ""
    if events:
        parts = [f"{e.get('type')} {e.get('object')}" for e in events]
        events_desc = f"\nДействия игрока за этот ход: {', '.join(parts)}."
    user_content = (
        f'Игрок сказал: "{transcript or "(тишина, ничего не расслышала)"}"'
        f"{events_desc}\n\n"
        "Ответь СТРОГО в этом текстовом формате, ровно три строки, без "
        "markdown, без JSON, без лишних пояснений:\n"
        "РЕПЛИКА: <твоя реплика, 1-2 коротких предложения>\n"
        "ДЕЙСТВИЕ: idle\n"
        "ОЦЕНКА: <целое число от -2 до 3, насколько удачно прошёл ход>"
    )
    return [
        {"role": "system", "content": persona},
        {"role": "user", "content": user_content},
    ]


# Просим НЕ json, а простой построчный формат: маленькие модели регулярно
# ломают валидный JSON, если реплика сама содержит кавычки (см. историю
# правок), а с текстовыми метками парсить эту же реплику дословно — без
# экранирования — гораздо надёжнее.
def _parse_npc_response(text: str) -> dict:
    reply_match = re.search(
        r"РЕПЛИКА\s*:\s*(.+?)(?:\n\s*ДЕЙСТВИЕ\s*:|\Z)", text, re.DOTALL | re.IGNORECASE
    )
    action_match = re.search(r"ДЕЙСТВИЕ\s*:\s*(\S+)", text, re.IGNORECASE)
    score_match = re.search(r"ОЦЕНКА\s*:\s*(-?\d+)", text, re.IGNORECASE)
    reply_text = (reply_match.group(1) if reply_match else text).strip()
    action = action_match.group(1).strip() if action_match else "idle"
    try:
        score_delta = int(score_match.group(1)) if score_match else 0
    except ValueError:
        score_delta = 0
    return {"reply_text": reply_text, "action": action, "score_delta": score_delta}


def _clean_reply_text(text: str) -> str:
    text = _CJK_RE.sub("", text)
    text = _MULTI_SPACE_RE.sub(" ", text).strip()
    if len(text) > _MAX_REPLY_CHARS:
        text = text[:_MAX_REPLY_CHARS].rstrip() + "…"
    if not text:
        text = "..."
    return text


async def _ask_npc(scenario: str, transcript: str, events: list) -> dict:
    async with httpx.AsyncClient(timeout=LLM_TIMEOUT_SEC) as client:
        resp = await client.post(LLM_URL, json={
            "model": LLM_MODEL,
            "messages": _build_messages(scenario, transcript, events),
            "temperature": 0.7,
        })
        resp.raise_for_status()
        content = resp.json()["choices"][0]["message"]["content"]
    parsed = _parse_npc_response(content)
    parsed["reply_text"] = _clean_reply_text(parsed["reply_text"])
    return parsed


@app.post("/api/npc_turn")
async def npc_turn(
    turn_id: int = Form(...),
    scenario: str = Form(DEFAULT_SCENARIO),
    events: str = Form("[]"),
    audio: UploadFile = File(...),
):
    audio_bytes = await audio.read()
    transcript = _transcribe(audio_bytes)

    try:
        events_list = json.loads(events)
    except json.JSONDecodeError:
        events_list = []

    try:
        npc = await _ask_npc(scenario, transcript, events_list)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"LLM недоступен: {exc}")

    return JSONResponse({
        "transcript": transcript,
        "reply_text": npc["reply_text"],
        "action": npc["action"],
        "score_delta": npc["score_delta"],
        "audio_base64": "",
    })
