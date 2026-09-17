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
        "текст-в-речь, поэтому не используй эмодзи и markdown."
    ),
}
DEFAULT_SCENARIO = "restaurant_date"

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
        "Ответь строго в виде JSON без markdown-обрамления, вот формат:\n"
        '{"reply_text": "<твоя реплика>", "action": "idle", '
        '"score_delta": <целое число от -2 до 3, насколько удачно прошёл ход>}'
    )
    return [
        {"role": "system", "content": persona},
        {"role": "user", "content": user_content},
    ]


def _extract_json(text: str) -> dict:
    match = re.search(r"\{.*\}", text, re.DOTALL)
    if not match:
        return {}
    try:
        return json.loads(match.group(0))
    except json.JSONDecodeError:
        return {}


async def _ask_npc(scenario: str, transcript: str, events: list) -> dict:
    async with httpx.AsyncClient(timeout=LLM_TIMEOUT_SEC) as client:
        resp = await client.post(LLM_URL, json={
            "model": LLM_MODEL,
            "messages": _build_messages(scenario, transcript, events),
            "temperature": 0.7,
        })
        resp.raise_for_status()
        content = resp.json()["choices"][0]["message"]["content"]
    parsed = _extract_json(content)
    reply_text = str(parsed.get("reply_text") or content).strip()
    action = str(parsed.get("action") or "idle")
    try:
        score_delta = int(parsed.get("score_delta", 0) or 0)
    except (TypeError, ValueError):
        score_delta = 0
    return {"reply_text": reply_text, "action": action, "score_delta": score_delta}


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
