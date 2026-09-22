import array
import base64
import json
import logging
import os
import re
import struct

import anthropic
import httpx
from fastapi import FastAPI, Form, HTTPException, UploadFile, File
from fastapi.responses import JSONResponse

# AI-бэкенд тестовой сессии "свиданка" (см. TurnManager.gd в корне репозитория
# за полным контрактом). Делает три вещи на каждый ход:
#   1. Распознаёт речь игрока — Yandex SpeechKit STT.
#   2. Просит Claude сыграть роль NPC и вернуть реплику + оценку хода.
#   3. Озвучивает реплику NPC — Yandex SpeechKit TTS.
# Если STT/TTS не сработали (нет ключей/сеть упала) — STT просто вернёт
# пустой transcript (для NPC это равносильно "тишине"), а TTS вернёт пустой
# audio_base64: тогда TurnManager.gd на сервере сам озвучит текст через
# espeak-ng, а если и его нет — клиент озвучит локально (см. _speak_npc_text
# в TurnManager.gd). Это единственный оставшийся fallback, локальных ML-
# моделей в бэкенде больше нет — все шаги идут через внешние API.
#
# Нужны переменные окружения:
#   ANTHROPIC_API_KEY — ключ Claude (реплики NPC)
#   YANDEX_API_KEY     — API-ключ Yandex Cloud сервисного аккаунта (STT + TTS)
#   YANDEX_FOLDER_ID   — опционально: id каталога. Нужен только для ключей
#                        пользовательского аккаунта; ключ сервисного аккаунта
#                        уже привязан к каталогу, folderId можно не слать.
# Все SDK/запросы подхватывают ключи из окружения сами, в коде ничего не
# хардкодится.

logger = logging.getLogger(__name__)

LLM_MODEL = "claude-haiku-4-5"
LLM_TIMEOUT_SEC = 90.0

YANDEX_API_KEY = os.environ.get("YANDEX_API_KEY", "")
YANDEX_FOLDER_ID = os.environ.get("YANDEX_FOLDER_ID", "")
YANDEX_HTTP_TIMEOUT_SEC = 30.0

YANDEX_STT_URL = "https://stt.api.cloud.yandex.net/speech/v1/stt:recognize"
# Синхронный stt:recognize у Yandex жёстко ограничен 1 МБ и 30 секундами на
# запрос, а ход у нас длится ровно TURN_DURATION_SEC=30s (см. TurnManager.gd)
# — на частоте, на которой Godot пишет WAV (обычно 44100/48000 Гц), полный
# ход не влезет в лимит. 16 кГц даёт 30с*16000Гц*2 байта ≈ 937 КБ — укладыва-
# емся с запасом, качества достаточно для распознавания речи.
YANDEX_STT_SAMPLE_RATE = 16000

YANDEX_TTS_URL = "https://tts.api.cloud.yandex.net/speech/v1/tts:synthesize"
YANDEX_VOICE = "alena"  # тёплый женский голос ru-RU, подходит под персонажа Ани

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

# Словарь жестов NPC-болванчика на сцене (см. Npc.gd на стороне Godot —
# именно эти строки там задают анимацию твинами). Всё, чего нет в этом
# списке, при парсинге отбрасывается.
VALID_ACTIONS = {"talk", "turn", "nod", "shrug", "idle"}
DEFAULT_ACTIONS = ["talk"]

# CJK-диапазоны — маленькая модель иногда сваливается в китайский посреди
# русского ответа, это защитная зачистка на выходе (см. _clean_reply_text).
_CJK_RE = re.compile(r"[一-鿿㐀-䶿豈-﫿]+")
_MULTI_SPACE_RE = re.compile(r"[ \t]{2,}")
_MAX_REPLY_CHARS = 300

app = FastAPI()
_llm_client = anthropic.AsyncAnthropic(timeout=LLM_TIMEOUT_SEC)
_yandex_http = httpx.AsyncClient(timeout=YANDEX_HTTP_TIMEOUT_SEC)


# Godot всегда шлёт WAV в ровно этом формате (44-байтный canonical-заголовок,
# 16-bit PCM моно) — см. TurnManager._encode_wav_16bit_mono.
def _parse_wav_pcm16_mono(data: bytes) -> tuple[array.array, int]:
    if len(data) < 44 or data[0:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("не WAV-файл")
    channels = struct.unpack_from("<H", data, 22)[0]
    sample_rate = struct.unpack_from("<I", data, 24)[0]
    bits = struct.unpack_from("<H", data, 34)[0]
    if channels != 1 or bits != 16:
        raise ValueError(f"ожидался 16-bit моно PCM, пришло channels={channels} bits={bits}")
    samples = array.array("h")
    samples.frombytes(data[44:])
    return samples, sample_rate


def _resample_pcm16(samples: array.array, src_rate: int, dst_rate: int) -> array.array:
    if src_rate == dst_rate or len(samples) == 0:
        return samples
    ratio = dst_rate / src_rate
    dst_len = max(1, int(len(samples) * ratio))
    last_idx = len(samples) - 1
    out = array.array("h", bytes(dst_len * 2))
    for i in range(dst_len):
        src_pos = i / ratio
        idx = int(src_pos)
        if idx >= last_idx:
            out[i] = samples[last_idx]
            continue
        frac = src_pos - idx
        out[i] = int(samples[idx] + (samples[idx + 1] - samples[idx]) * frac)
    return out


async def _transcribe(audio_bytes: bytes) -> str:
    if not audio_bytes or not YANDEX_API_KEY:
        return ""
    try:
        samples, sample_rate = _parse_wav_pcm16_mono(audio_bytes)
    except ValueError as exc:
        logger.warning("Не удалось разобрать аудио хода для STT: %s", exc)
        return ""
    samples = _resample_pcm16(samples, sample_rate, YANDEX_STT_SAMPLE_RATE)
    params = {
        "lang": "ru-RU",
        "format": "lpcm",
        "sampleRateHertz": str(YANDEX_STT_SAMPLE_RATE),
    }
    if YANDEX_FOLDER_ID:
        params["folderId"] = YANDEX_FOLDER_ID
    try:
        resp = await _yandex_http.post(
            YANDEX_STT_URL,
            headers={"Authorization": f"Api-Key {YANDEX_API_KEY}"},
            params=params,
            content=samples.tobytes(),
        )
        resp.raise_for_status()
        return resp.json().get("result", "").strip()
    except httpx.HTTPError as exc:
        logger.warning("Yandex SpeechKit STT недоступен: %s", exc)
        return ""


def _build_system_prompt(scenario: str) -> str:
    return SCENARIOS.get(scenario, SCENARIOS[DEFAULT_SCENARIO])


def _build_user_message(transcript: str, events: list) -> str:
    events_desc = ""
    if events:
        parts = [f"{e.get('type')} {e.get('object')}" for e in events]
        events_desc = f"\nДействия игрока за этот ход: {', '.join(parts)}."
    return (
        f'Игрок сказал: "{transcript or "(тишина, ничего не расслышала)"}"'
        f"{events_desc}\n\n"
        "Ответь СТРОГО в этом текстовом формате, ровно три строки, без "
        "markdown, без JSON, без лишних пояснений:\n"
        "РЕПЛИКА: <твоя реплика, 1-2 коротких предложения>\n"
        "ДЕЙСТВИЯ: <от 1 до 3 жестов через запятую строго из списка: "
        "talk, turn, nod, shrug, idle — talk означает, что в этот момент "
        "ты говоришь реплику, остальные — молчаливые жесты>\n"
        "ОЦЕНКА: <целое число от -2 до 3, насколько удачно прошёл ход>"
    )


# Просим НЕ json, а простой построчный формат: маленькие модели регулярно
# ломают валидный JSON, если реплика сама содержит кавычки (см. историю
# правок), а с текстовыми метками парсить эту же реплику дословно — без
# экранирования — гораздо надёжнее.
def _parse_npc_response(text: str) -> dict:
    reply_match = re.search(
        r"РЕПЛИКА\s*:\s*(.+?)(?:\n\s*ДЕЙСТВИ[ЯЕ]\s*:|\Z)", text, re.DOTALL | re.IGNORECASE
    )
    actions_match = re.search(r"ДЕЙСТВИ[ЯЕ]\s*:\s*(.+)", text, re.IGNORECASE)
    score_match = re.search(r"ОЦЕНКА\s*:\s*(-?\d+)", text, re.IGNORECASE)
    reply_text = (reply_match.group(1) if reply_match else text).strip()
    actions = DEFAULT_ACTIONS
    if actions_match:
        raw = [a.strip().lower() for a in actions_match.group(1).split(",")]
        valid = [a for a in raw if a in VALID_ACTIONS]
        if valid:
            actions = valid[:3]
    try:
        score_delta = int(score_match.group(1)) if score_match else 0
    except ValueError:
        score_delta = 0
    return {"reply_text": reply_text, "actions": actions, "score_delta": score_delta}


def _clean_reply_text(text: str) -> str:
    text = _CJK_RE.sub("", text)
    text = _MULTI_SPACE_RE.sub(" ", text).strip()
    if len(text) > _MAX_REPLY_CHARS:
        text = text[:_MAX_REPLY_CHARS].rstrip() + "…"
    if not text:
        text = "..."
    return text


async def _ask_npc(scenario: str, transcript: str, events: list) -> dict:
    response = await _llm_client.messages.create(
        model=LLM_MODEL,
        max_tokens=500,
        system=_build_system_prompt(scenario),
        messages=[{"role": "user", "content": _build_user_message(transcript, events)}],
    )
    content = "".join(block.text for block in response.content if block.type == "text")
    parsed = _parse_npc_response(content)
    parsed["reply_text"] = _clean_reply_text(parsed["reply_text"])
    return parsed


async def _synthesize_speech(text: str) -> bytes:
    if not text or not YANDEX_API_KEY:
        return b""
    data = {
        "text": text,
        "lang": "ru-RU",
        "voice": YANDEX_VOICE,
        "format": "mp3",
    }
    if YANDEX_FOLDER_ID:
        data["folderId"] = YANDEX_FOLDER_ID
    try:
        resp = await _yandex_http.post(
            YANDEX_TTS_URL,
            headers={"Authorization": f"Api-Key {YANDEX_API_KEY}"},
            data=data,
        )
        resp.raise_for_status()
        return resp.content
    except httpx.HTTPError as exc:
        logger.warning("Yandex SpeechKit недоступен, отдаю ход без озвучки: %s", exc)
        return b""


@app.post("/api/npc_turn")
async def npc_turn(
    turn_id: int = Form(...),
    scenario: str = Form(DEFAULT_SCENARIO),
    events: str = Form("[]"),
    audio: UploadFile = File(...),
):
    audio_bytes = await audio.read()
    transcript = await _transcribe(audio_bytes)

    try:
        events_list = json.loads(events)
    except json.JSONDecodeError:
        events_list = []

    try:
        npc = await _ask_npc(scenario, transcript, events_list)
    except anthropic.RateLimitError as exc:
        raise HTTPException(status_code=429, detail=f"LLM: превышен лимит запросов: {exc}")
    except anthropic.APIStatusError as exc:
        raise HTTPException(status_code=502, detail=f"LLM вернул ошибку: {exc}")
    except anthropic.APIConnectionError as exc:
        raise HTTPException(status_code=502, detail=f"LLM недоступен: {exc}")
    except Exception as exc:
        # SDK может упасть ещё до сетевого запроса (например TypeError, если
        # ANTHROPIC_API_KEY не задан) — такие ошибки не наследуют ни один из
        # типов anthropic.* выше, но клиенту всё равно нужен внятный ответ,
        # а не голый 500.
        logger.error("Неожиданная ошибка при обращении к LLM: %s", exc)
        raise HTTPException(status_code=502, detail=f"LLM: непредвиденная ошибка: {exc}")

    tts_bytes = await _synthesize_speech(npc["reply_text"])
    audio_base64 = base64.b64encode(tts_bytes).decode("ascii") if tts_bytes else ""

    return JSONResponse({
        "transcript": transcript,
        "reply_text": npc["reply_text"],
        "actions": npc["actions"],
        "score_delta": npc["score_delta"],
        "audio_base64": audio_base64,
    })
