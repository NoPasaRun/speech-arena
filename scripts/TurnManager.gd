extends Node

# Синглтон (автозагрузка). Серверная машина состояний хода тестовой сессии
# "свиданка": ждёт речь+действия игрока в течение хода, в конце хода шлёт
# накопленное на AI-бэкенд (FastAPI, ещё не написан) и рассылает клиентам
# ответ NPC. Если бэкенд недоступен — использует захардкоженный fallback,
# чтобы демо не падало без интернета.
#
# Один и тот же автозагружаемый узел обслуживает ВСЕ комнаты выделенного
# сервера одновременно: состояние (счёт, текущий ход, таймер) хранится не в
# полях узла, а в словаре _rooms[room_id] -> RoomTurn, так что комнаты не
# делят между собой счёт и не сбивают таймеры друг друга. На клиенте же
# используются поля state/total_score напрямую — там всегда только "своя"
# комната.
#
# Контракт бэкенда: POST BACKEND_URL, multipart/form-data:
#   turn_id (int), scenario (string), events (JSON-строка
#   [{"type","object","t"}]), audio (turn.wav, 16-bit PCM mono)
# Ответ JSON: {transcript, reply_text, action, score_delta, audio_base64 (mp3)}

const BACKEND_URL := "http://127.0.0.1:8000/api/npc_turn"
const TURN_DURATION_SEC := 30.0
const REQUEST_TIMEOUT_SEC := 10.0

enum State { IDLE, PLAYER_TURN, PROCESSING, NPC_TURN }

signal turn_started(turn_id: int, duration_sec: float)
signal npc_turn_received(turn_id: int, reply_text: String, action: String, score_delta: int, total_score: int, audio_base64: String)

# ---- клиентское состояние (только "своя" комната) ----
var state: State = State.IDLE
var total_score := 0

const _FALLBACK_REPLIES := [
	"Извини, я немного отвлеклась... Повтори, пожалуйста?",
	"Хм, дай мне подумать секунду.",
	"Здесь так шумно, я не совсем расслышала.",
]

class RoomTurn:
	var state: int = 0 # State.IDLE
	var current_turn_id := 0
	var current_player_id := -1
	var scenario := "restaurant_date"
	var total_score := 0
	var turn_events: Array = []
	var turn_start_ticks_msec := 0
	var audio_buffer: PackedFloat32Array = PackedFloat32Array()
	var timer: Timer
	var http: HTTPRequest

var _rooms: Dictionary = {}  # room_id -> RoomTurn (актуально только на выделенном сервере)

# ---------------------------------------------------------------------------
# Запуск сессии в комнате. Вызывает NetworkManager на сервере, когда в
# комнате регистрируется первый игрок ("speaker").
# ---------------------------------------------------------------------------
func start_match(room_id: String, player_id: int) -> void:
	if not multiplayer.is_server():
		return
	var rt := RoomTurn.new()
	rt.current_player_id = player_id
	rt.timer = Timer.new()
	rt.timer.one_shot = true
	rt.timer.timeout.connect(_on_turn_timeout.bind(room_id))
	add_child(rt.timer)
	rt.http = HTTPRequest.new()
	rt.http.timeout = REQUEST_TIMEOUT_SEC
	add_child(rt.http)
	rt.http.request_completed.connect(_on_backend_response.bind(room_id))
	_rooms[room_id] = rt
	_start_player_turn(room_id)

func cleanup_room(room_id: String) -> void:
	if not _rooms.has(room_id):
		return
	var rt: RoomTurn = _rooms[room_id]
	rt.timer.queue_free()
	rt.http.queue_free()
	_rooms.erase(room_id)

func _start_player_turn(room_id: String) -> void:
	var rt: RoomTurn = _rooms[room_id]
	rt.current_turn_id += 1
	rt.state = State.PLAYER_TURN
	rt.turn_events.clear()
	rt.audio_buffer.resize(0)
	rt.turn_start_ticks_msec = Time.get_ticks_msec()
	rt.timer.start(TURN_DURATION_SEC)
	for pid in NetworkManager.room_peer_ids(room_id):
		_on_turn_started.rpc_id(pid, rt.current_turn_id, TURN_DURATION_SEC)

@rpc("authority", "reliable")
func _on_turn_started(turn_id: int, duration_sec: float) -> void:
	state = State.PLAYER_TURN
	turn_started.emit(turn_id, duration_sec)

# ---------------------------------------------------------------------------
# Приём данных от игрока во время хода
# ---------------------------------------------------------------------------

@rpc("any_peer", "unreliable_ordered")
func submit_audio_chunk(samples: PackedFloat32Array) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	var room_id := NetworkManager.room_of_peer(sender_id)
	if room_id == "" or not _rooms.has(room_id):
		return
	var rt: RoomTurn = _rooms[room_id]
	if rt.state != State.PLAYER_TURN or sender_id != rt.current_player_id:
		return
	rt.audio_buffer.append_array(samples)

# Дискретное событие сцены (взял бокал, подвинул меню и т.п.). Вызывать
# из серверной логики drag-and-drop, когда список объектов утвердят.
func log_event(room_id: String, event_type: String, object_name: String) -> void:
	if not multiplayer.is_server() or not _rooms.has(room_id):
		return
	var rt: RoomTurn = _rooms[room_id]
	if rt.state != State.PLAYER_TURN:
		return
	var t := (Time.get_ticks_msec() - rt.turn_start_ticks_msec) / 1000.0
	rt.turn_events.append({"type": event_type, "object": object_name, "t": t})

# Игрок жмёт "Завершить ход" в UI: TurnManager.request_end_turn.rpc_id(1)
@rpc("any_peer", "reliable")
func request_end_turn() -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	var room_id := NetworkManager.room_of_peer(sender_id)
	if room_id == "" or not _rooms.has(room_id):
		return
	var rt: RoomTurn = _rooms[room_id]
	if rt.state != State.PLAYER_TURN or sender_id != rt.current_player_id:
		return
	_end_player_turn(room_id)

func _on_turn_timeout(room_id: String) -> void:
	if not _rooms.has(room_id):
		return
	if _rooms[room_id].state == State.PLAYER_TURN:
		_end_player_turn(room_id)

func _end_player_turn(room_id: String) -> void:
	var rt: RoomTurn = _rooms[room_id]
	rt.timer.stop()
	rt.state = State.PROCESSING
	_send_turn_to_backend(room_id)

# ---------------------------------------------------------------------------
# Запрос к AI-бэкенду
# ---------------------------------------------------------------------------
func _send_turn_to_backend(room_id: String) -> void:
	var rt: RoomTurn = _rooms[room_id]
	var wav_bytes := _encode_wav_16bit_mono(rt.audio_buffer, AudioServer.get_mix_rate())
	var events_json := JSON.stringify(rt.turn_events)

	var boundary := "----turnmanager-%d" % Time.get_ticks_msec()
	var body := PackedByteArray()
	_append_form_field(body, boundary, "turn_id", str(rt.current_turn_id))
	_append_form_field(body, boundary, "scenario", rt.scenario)
	_append_form_field(body, boundary, "events", events_json)
	_append_form_file(body, boundary, "audio", "turn.wav", "audio/wav", wav_bytes)
	body.append_array(("--%s--\r\n" % boundary).to_utf8_buffer())

	var headers := PackedStringArray([
		"Content-Type: multipart/form-data; boundary=%s" % boundary,
	])

	var err := rt.http.request_raw(BACKEND_URL, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		push_warning("Не удалось отправить ход бэкенду (%s), включаю fallback" % err)
		_fallback_npc_turn(room_id)

func _append_form_field(body: PackedByteArray, boundary: String, field_name: String, value: String) -> void:
	var chunk := "--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % [boundary, field_name, value]
	body.append_array(chunk.to_utf8_buffer())

func _append_form_file(body: PackedByteArray, boundary: String, field_name: String, filename: String, content_type: String, data: PackedByteArray) -> void:
	var header := "--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\nContent-Type: %s\r\n\r\n" % [boundary, field_name, filename, content_type]
	body.append_array(header.to_utf8_buffer())
	body.append_array(data)
	body.append_array("\r\n".to_utf8_buffer())

func _on_backend_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, room_id: String) -> void:
	if not _rooms.has(room_id):
		return
	var rt: RoomTurn = _rooms[room_id]
	if rt.state != State.PROCESSING:
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_warning("Бэкенд недоступен (result=%s, code=%s), включаю fallback" % [result, response_code])
		_fallback_npc_turn(room_id)
		return

	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null or not (parsed is Dictionary):
		push_warning("Не удалось разобрать ответ бэкенда, включаю fallback")
		_fallback_npc_turn(room_id)
		return

	_apply_npc_turn(
		room_id,
		parsed.get("reply_text", ""),
		parsed.get("action", ""),
		parsed.get("score_delta", 0),
		parsed.get("audio_base64", "")
	)

func _fallback_npc_turn(room_id: String) -> void:
	var reply: String = _FALLBACK_REPLIES[randi() % _FALLBACK_REPLIES.size()]
	_apply_npc_turn(room_id, reply, "idle", 0, "")

func _apply_npc_turn(room_id: String, reply_text: String, action: String, score_delta: int, audio_base64: String) -> void:
	var rt: RoomTurn = _rooms[room_id]
	rt.state = State.NPC_TURN
	rt.total_score += score_delta
	for pid in NetworkManager.room_peer_ids(room_id):
		_broadcast_npc_turn.rpc_id(pid, rt.current_turn_id, reply_text, action, score_delta, rt.total_score, audio_base64)
	if action != "":
		_broadcast_event(room_id, action)
	_start_player_turn(room_id)

@rpc("authority", "reliable")
func _broadcast_npc_turn(turn_id: int, reply_text: String, action: String, score_delta: int, new_total_score: int, audio_base64: String) -> void:
	print("[Ход %d] NPC: %s (action=%s, score_delta=%d, total=%d)" % [turn_id, reply_text, action, score_delta, new_total_score])
	state = State.NPC_TURN
	total_score = new_total_score
	npc_turn_received.emit(turn_id, reply_text, action, score_delta, new_total_score, audio_base64)
	_play_npc_voice(audio_base64)

var _npc_voice: AudioStreamPlayer

func _play_npc_voice(audio_base64: String) -> void:
	if audio_base64.is_empty():
		return
	var mp3_bytes := Marshalls.base64_to_raw(audio_base64)
	if mp3_bytes.is_empty():
		push_warning("Не удалось декодировать audio_base64 ответа NPC")
		return
	if _npc_voice == null:
		_npc_voice = AudioStreamPlayer.new()
		_npc_voice.bus = "Master"
		add_child(_npc_voice)
	var stream := AudioStreamMP3.new()
	stream.data = mp3_bytes
	_npc_voice.stream = stream
	_npc_voice.play()

func _broadcast_event(_room_id: String, _action: String) -> void:
	pass # TODO: применить визуальный эффект события на сцену — ждём
		 # утверждённый командой список интерактивных объектов ресторана

func _encode_wav_16bit_mono(samples: PackedFloat32Array, sample_rate: int) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		var s := clampf(samples[i], -1.0, 1.0)
		data.encode_s16(i * 2, int(s * 32767.0))

	var header := PackedByteArray()
	header.resize(44)
	var data_size := data.size()
	var byte_rate := sample_rate * 2
	header.encode_u32(0, 0x46464952)   # "RIFF"
	header.encode_u32(4, 36 + data_size)
	header.encode_u32(8, 0x45564157)   # "WAVE"
	header.encode_u32(12, 0x20746d66)  # "fmt "
	header.encode_u32(16, 16)
	header.encode_u16(20, 1)           # PCM
	header.encode_u16(22, 1)           # mono
	header.encode_u32(24, sample_rate)
	header.encode_u32(28, byte_rate)
	header.encode_u16(32, 2)           # block align
	header.encode_u16(34, 16)          # bits per sample
	header.encode_u32(36, 0x61746164)  # "data"
	header.encode_u32(40, data_size)

	header.append_array(data)
	return header
