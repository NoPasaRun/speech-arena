extends Node

# Клиенты внешних API для хода NPC. Дочерний узел TurnManager (создаётся
# только в процессе выделенного сервера), про комнаты и ходы ничего не знает —
# TurnManager вызывает эти корутины через await:
#   transcribe()  — Яндекс SpeechKit STT v1 (речь игрока -> текст)
#   npc_reply()   — Claude Haiku (реплика NPC + жесты + оценка хода)
#   synthesize()  — Яндекс SpeechKit TTS v1, голос alena (реплика -> mp3)
#
# Запасных вариантов нет: подменять чужим голосом или заготовленной репликой
# нельзя, поэтому временные сбои (сеть, 408/429/5xx) переживаются повторами
# внутри _request(), а если API так и не ответил — функция возвращает
# признак ошибки, и TurnManager честно проваливает ход.
#
# Ключи ищутся в таком порядке: переменные окружения YANDEX_API_KEY /
# ANTHROPIC_API_KEY, затем секция [keys] в res://secrets.cfg, затем в
# user://secrets.cfg. Шаблон — secrets.cfg.example; сам secrets.cfg лежит в
# .gitignore. Нет ключа — громкая ошибка при старте.
#
# Важно: Яндекс не отдаёт CORS-заголовки, поэтому эти вызовы работают только
# из нативного процесса (выделенный сервер, десктоп, Android), но не из
# web-экспорта Godot.

const YANDEX_STT_URL := "https://stt.api.cloud.yandex.net/speech/v1/stt:recognize"
const YANDEX_TTS_URL := "https://tts.api.cloud.yandex.net/speech/v1/tts:synthesize"
const ANTHROPIC_URL := "https://api.anthropic.com/v1/messages"
const ANTHROPIC_VERSION := "2023-06-01"

const CLAUDE_MODEL := "claude-haiku-4-5"
const CLAUDE_MAX_TOKENS := 300
const CLAUDE_TEMPERATURE := 0.8
const TTS_VOICE := "alena"

# Синхронный STT v1 принимает не больше 30 секунд и 1 МБ. 30 с 16-битного
# моно на 16 кГц — ровно 960 000 байт, поэтому режем и ресемплим до 16 кГц.
const STT_RATE := 16000
const STT_MAX_SAMPLES := STT_RATE * 30
const STT_MIN_SEC := 0.2

const REQUEST_TIMEOUT_SEC := 20.0
const MAX_ATTEMPTS := 3
const RETRY_DELAY_SEC := 0.7 # перед 2-й попыткой 0.7 с, перед 3-й 1.4 с
const MAX_HISTORY_MESSAGES := 20 # последние 10 обменов репликами

const SECRET_PATHS := ["res://secrets.cfg", "user://secrets.cfg"]

const SCENARIOS := {
	"restaurant_date": "Ты — Аня, девушка на первом свидании с игроком в ресторане. " \
		+ "Держись дружелюбно, немного застенчиво, живо реагируй на то, что " \
		+ "говорит собеседник и что он делает. Отвечай ТОЛЬКО на русском " \
		+ "языке, 1-2 короткими разговорными предложениями — это озвучат вслух " \
		+ "текст-в-речь, поэтому не используй эмодзи и markdown.",
}
const DEFAULT_SCENARIO := "restaurant_date"

# Словарь жестов NPC-болванчика (см. Npc.gd — там они превращаются в твины).
const VALID_ACTIONS := ["talk", "turn", "nod", "shrug", "idle"]
const DEFAULT_ACTIONS := ["talk"]

const FORMAT_RULES := "Каждый ответ давай СТРОГО в таком текстовом формате, ровно три строки, " \
	+ "без markdown и без JSON:\n" \
	+ "РЕПЛИКА: <твоя реплика, 1-2 коротких предложения>\n" \
	+ "ДЕЙСТВИЯ: <от 1 до 3 жестов через запятую строго из списка: talk, turn, nod, shrug, idle — " \
	+ "talk означает, что в этот момент ты говоришь реплику, остальные — молчаливые жесты>\n" \
	+ "ОЦЕНКА: <целое число от -2 до 3, насколько удачно прошёл ход игрока>"

var _yandex_key := ""
var _anthropic_key := ""

func _ready() -> void:
	var cfg_values := _load_secret_files()
	_yandex_key = _secret("YANDEX_API_KEY", cfg_values)
	_anthropic_key = _secret("ANTHROPIC_API_KEY", cfg_values)
	if _yandex_key.is_empty():
		push_error("YANDEX_API_KEY не задан: без него нет ни распознавания, ни озвучки (см. secrets.cfg.example)")
	if _anthropic_key.is_empty():
		push_error("ANTHROPIC_API_KEY не задан: без него NPC не сможет отвечать (см. secrets.cfg.example)")

func _load_secret_files() -> Dictionary:
	var values := {}
	# Идём с конца: файл из начала списка перекрывает следующие.
	for i in range(SECRET_PATHS.size() - 1, -1, -1):
		var cfg := ConfigFile.new()
		if cfg.load(SECRET_PATHS[i]) != OK or not cfg.has_section("keys"):
			continue
		for key in cfg.get_section_keys("keys"):
			values[key] = str(cfg.get_value("keys", key, ""))
	return values

func _secret(secret_name: String, cfg_values: Dictionary) -> String:
	var from_env := OS.get_environment(secret_name).strip_edges()
	if not from_env.is_empty():
		return from_env
	return str(cfg_values.get(secret_name, "")).strip_edges()

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

# POST с повторами: до MAX_ATTEMPTS попыток, повторяем только то, что
# имеет смысл повторять (обрыв/таймаут, 408, 429, 5xx). Ошибки 4xx — неверный
# ключ или запрос — повтор не лечит. Возвращает {ok, code, body}.
func _request(url: String, headers: PackedStringArray, body: PackedByteArray) -> Dictionary:
	var res := {"ok": false, "code": 0, "body": PackedByteArray()}
	for attempt in MAX_ATTEMPTS:
		if attempt > 0:
			await get_tree().create_timer(RETRY_DELAY_SEC * attempt).timeout
		res = await _request_once(url, headers, body)
		if res.ok or not _is_retryable(res.code):
			break
	return res

static func _is_retryable(code: int) -> bool:
	return code == 0 or code == 408 or code == 429 or code >= 500

# Один запрос = один временный HTTPRequest, поэтому корутины из разных
# комнат не мешают друг другу.
func _request_once(url: String, headers: PackedStringArray, body: PackedByteArray) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT_SEC
	add_child(http)
	var err := http.request_raw(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		return {"ok": false, "code": 0, "body": PackedByteArray()}
	var result: Array = await http.request_completed
	http.queue_free()
	var code: int = result[1]
	return {
		"ok": result[0] == HTTPRequest.RESULT_SUCCESS and code == 200,
		"code": code,
		"body": result[3],
	}

func _report_failed(what: String, res: Dictionary) -> void:
	var body: PackedByteArray = res.body
	push_error("%s: HTTP %s (после %d попыток) %s" % [what, res.code, MAX_ATTEMPTS, body.get_string_from_utf8().left(300)])

# ---------------------------------------------------------------------------
# STT: Яндекс SpeechKit v1
# ---------------------------------------------------------------------------

# samples — моно float32 с частотой src_rate (то, что копится в
# RoomTurn.audio_buffer). Возвращает {ok, text}: ok == false — сбой API
# (ход надо проваливать), ok == true и text == "" — игрок молчал.
func transcribe(samples: PackedFloat32Array, src_rate: int) -> Dictionary:
	if src_rate <= 0 or samples.size() < int(src_rate * STT_MIN_SEC):
		return {"ok": true, "text": ""}
	if _yandex_key.is_empty():
		return {"ok": false, "text": ""}
	var pcm := await _resample_async(samples, src_rate)
	var url := "%s?lang=ru-RU&topic=general&format=lpcm&sampleRateHertz=%d" % [YANDEX_STT_URL, STT_RATE]
	var headers := PackedStringArray([
		"Authorization: Api-Key " + _yandex_key,
		"Content-Type: application/octet-stream",
	])
	var res: Dictionary = await _request(url, headers, pcm)
	if not res.ok:
		_report_failed("Яндекс STT", res)
		return {"ok": false, "text": ""}
	var parsed = JSON.parse_string((res.body as PackedByteArray).get_string_from_utf8())
	if not (parsed is Dictionary):
		push_error("Яндекс STT вернул не JSON")
		return {"ok": false, "text": ""}
	return {"ok": true, "text": str(parsed.get("result", "")).strip_edges()}

# Ресемплинг записи на главном потоке подвесил бы сервер на сотни
# миллисекунд (а при живой диктовке он повторяется каждые 1.5 с и затрагивает
# все комнаты), поэтому считаем в WorkerThreadPool и ждём по кадрам.
func _resample_async(samples: PackedFloat32Array, src_rate: int) -> PackedByteArray:
	var holder := [PackedByteArray()]
	var task_id := WorkerThreadPool.add_task(func():
		holder[0] = _to_pcm16(samples, src_rate, STT_RATE, STT_MAX_SAMPLES)
	)
	while not WorkerThreadPool.is_task_completed(task_id):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task_id)
	return holder[0]

# float32 [-1..1] на src_rate -> 16-битный little-endian PCM на dst_rate.
# Каждый выходной сэмпл — среднее по своему окну входных (простейший ФНЧ,
# чтобы при понижении частоты не было алиасинга).
static func _to_pcm16(samples: PackedFloat32Array, src_rate: int, dst_rate: int, max_out: int) -> PackedByteArray:
	var ratio := float(src_rate) / float(dst_rate)
	var out_count := mini(int(samples.size() / ratio), max_out)
	var out := PackedByteArray()
	out.resize(out_count * 2)
	for i in out_count:
		var first := int(i * ratio)
		var last := mini(maxi(int((i + 1) * ratio), first + 1), samples.size())
		var sum := 0.0
		for j in range(first, last):
			sum += samples[j]
		var value := clampf(sum / float(last - first), -1.0, 1.0)
		out.encode_s16(i * 2, int(value * 32767.0))
	return out

# ---------------------------------------------------------------------------
# LLM: Claude Haiku
# ---------------------------------------------------------------------------

# history — переписка комнаты, {role, content}; здесь она только читается.
# Возвращает {reply_text, actions, score_delta, exchange} либо пустой
# словарь при сбое. exchange — пара сообщений для истории: TurnManager
# вызывает remember() только когда ход дошёл до игрока целиком (иначе после
# сорванной озвучки NPC "помнил" бы реплику, которую никто не услышал).
func npc_reply(scenario: String, history: Array, transcript: String, events: Array) -> Dictionary:
	if _anthropic_key.is_empty():
		return {}
	var user_text := "Игрок сказал: \"%s\"" % (transcript if not transcript.is_empty() else "(тишина, ничего не расслышала)")
	if not events.is_empty():
		var parts := PackedStringArray()
		for e in events:
			parts.append("%s %s" % [e.get("type", ""), e.get("object", "")])
		user_text += "\nДействия игрока за этот ход: %s." % ", ".join(parts)

	var messages := history.duplicate()
	messages.append({"role": "user", "content": user_text})
	var persona: String = SCENARIOS.get(scenario, SCENARIOS[DEFAULT_SCENARIO])
	var payload := {
		"model": CLAUDE_MODEL,
		"max_tokens": CLAUDE_MAX_TOKENS,
		"temperature": CLAUDE_TEMPERATURE,
		"system": persona + "\n\n" + FORMAT_RULES,
		"messages": messages,
	}
	var headers := PackedStringArray([
		"x-api-key: " + _anthropic_key,
		"anthropic-version: " + ANTHROPIC_VERSION,
		"content-type: application/json",
	])
	var res: Dictionary = await _request(ANTHROPIC_URL, headers, JSON.stringify(payload).to_utf8_buffer())
	if not res.ok:
		_report_failed("Claude", res)
		return {}

	var parsed = JSON.parse_string((res.body as PackedByteArray).get_string_from_utf8())
	var text := ""
	if parsed is Dictionary:
		for block in parsed.get("content", []):
			if block is Dictionary and block.get("type", "") == "text":
				text += str(block.get("text", ""))
	var npc := _parse_npc_response(text)
	if npc.is_empty():
		push_error("Claude вернул пустой ответ")
		return {}

	# В историю кладём нормализованный ответ в том же трёхстрочном формате:
	# так Haiku на следующих ходах держит формат по собственным примерам.
	npc["exchange"] = [
		{"role": "user", "content": user_text},
		{"role": "assistant", "content": "РЕПЛИКА: %s\nДЕЙСТВИЯ: %s\nОЦЕНКА: %d" % [
			npc.reply_text, ", ".join(npc.actions), npc.score_delta]},
	]
	return npc

# Дописывает обмен репликами из npc_reply() в историю комнаты.
static func remember(history: Array, npc: Dictionary) -> void:
	history.append_array(npc.exchange)
	while history.size() > MAX_HISTORY_MESSAGES:
		history.pop_front() # парами, чтобы история всегда начиналась с user
		history.pop_front()

# Просим не JSON, а построчный формат: реплика может содержать кавычки, и
# разбирать её дословно без экранирования надёжнее.
static func _parse_npc_response(text: String) -> Dictionary:
	var reply_lines := PackedStringArray()
	var actions: Array = []
	var score := 0
	var in_reply := false
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		var upper := line.to_upper()
		if upper.begins_with("РЕПЛИКА"):
			in_reply = true
			reply_lines.append(_after_colon(line))
		elif upper.begins_with("ДЕЙСТВИ"):
			in_reply = false
			for item in _after_colon(line).split(","):
				var action := item.strip_edges().to_lower()
				if VALID_ACTIONS.has(action) and actions.size() < 3:
					actions.append(action)
		elif upper.begins_with("ОЦЕНКА"):
			in_reply = false
			score = clampi(_after_colon(line).lstrip("+").to_int(), -2, 3)
		elif in_reply and not line.is_empty():
			reply_lines.append(line) # реплика, перенесённая на следующую строку
	var reply := " ".join(reply_lines).strip_edges()
	if reply.is_empty():
		reply = text.strip_edges() # модель проигнорировала формат — берём всё как реплику
	if reply.is_empty():
		return {}
	if actions.is_empty():
		actions = DEFAULT_ACTIONS.duplicate()
	return {"reply_text": reply, "actions": actions, "score_delta": score}

static func _after_colon(line: String) -> String:
	return line.substr(line.find(":") + 1).strip_edges() if line.contains(":") else ""

# ---------------------------------------------------------------------------
# TTS: Яндекс SpeechKit v1, голос alena
# ---------------------------------------------------------------------------

# Возвращает {mp3, duration} (mp3 — 48 кГц, моно, 64 кбит/с; duration —
# длительность в секундах) или пустой словарь при сбое. emotion у alena:
# "neutral" или "good".
func synthesize(text: String, emotion: String = "neutral") -> Dictionary:
	var clean := text.strip_edges()
	if _yandex_key.is_empty() or clean.is_empty():
		return {}
	var form := "text=%s&lang=ru-RU&voice=%s&emotion=%s&format=mp3" % [clean.uri_encode(), TTS_VOICE, emotion]
	var headers := PackedStringArray([
		"Authorization: Api-Key " + _yandex_key,
		"Content-Type: application/x-www-form-urlencoded",
	])
	var res: Dictionary = await _request(YANDEX_TTS_URL, headers, form.to_utf8_buffer())
	if not res.ok:
		_report_failed("Яндекс TTS", res)
		return {}
	var mp3: PackedByteArray = res.body
	var stream := AudioStreamMP3.new()
	stream.data = mp3
	var duration := stream.get_length()
	if duration <= 0.0:
		push_error("Яндекс TTS вернул аудио, которое не читается как mp3 (%d байт)" % mp3.size())
		return {}
	return {"mp3": mp3, "duration": duration}
