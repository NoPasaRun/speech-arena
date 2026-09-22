extends Node

# Синглтон (автозагрузка). Серверная машина состояний хода тестовой сессии
# "свиданка": ждёт речь+действия игрока в течение хода, в конце хода гонит
# накопленное через цепочку AiBackend и рассылает клиентам ответ NPC.
#
# Один и тот же автозагружаемый узел обслуживает ВСЕ комнаты выделенного
# сервера одновременно: состояние (счёт, текущий ход, таймер) хранится не в
# полях узла, а в словаре _rooms[room_id] -> RoomTurn, так что комнаты не
# делят между собой счёт и не сбивают таймеры друг друга. На клиенте же
# используются поля state/total_score напрямую — там всегда только "своя"
# комната.
#
# Ввод реплики игрока — два равноправных способа, итог всегда текст:
#   - голос (диктовка): пока микрофон открыт (begin_dictation), клиент шлёт
#     аудио (submit_audio_chunk), а сервер каждые LIVE_STT_INTERVAL_SEC
#     заново распознаёт накопленное в Яндекс STT и присылает клиенту текущий
#     текст (dictation_result); после end_dictation приходит итоговый. Настоящего
#     потока нет: потоковый STT Яндекса — gRPC, из GDScript недоступен.
#     Игрок правит текст, как хочет, и отправляет.
#   - клавиатура: игрок просто печатает текст и отправляет.
# Отправка — submit_text(text), дальше _send_turn_to_backend, два шага в
# AiBackend.gd:
#   1. Claude Haiku: текст + события + история комнаты -> reply_text,
#      actions (словарь "talk"/"turn"/"nod"/"shrug"/"idle", см. Npc.gd),
#      score_delta
#   2. Яндекс TTS (голос alena): reply_text -> mp3 (audio_base64)
# Запасных вариантов нет (ни заготовленных реплик, ни другого голоса):
# AiBackend сам повторяет запросы при временных сбоях, а если шаг всё равно
# не удался — _fail_turn честно сообщает клиентам об ошибке (turn_failed) и
# через FAIL_PAUSE_SEC даёт игроку повторить ход. Пустая реплика (игрок
# промолчал до конца таймера) — не сбой: NPC просто отвечает, что не расслышал.
#
# Длительность реплики NPC берётся из самого mp3: на это время сервер
# задерживает старт следующего хода игрока (_on_npc_wait_timeout), чтобы
# таймер игрока не тикал, пока NPC ещё "говорит".

const AiBackend := preload("res://scripts/AiBackend.gd")

const TURN_DURATION_SEC := 30.0
# Клиент сам отправляет то, что успел набрать, когда его отсчёт дошёл до нуля;
# серверный таймер чуть длиннее, чтобы эта отправка успела дойти.
const TURN_GRACE_SEC := 2.0
const FAIL_PAUSE_SEC := 3.0 # сколько игрок видит ошибку, прежде чем начнётся повторный ход
const LIVE_STT_INTERVAL_SEC := 1.5 # как часто обновляется текст во время диктовки
const MAX_TEXT_CHARS := 500

enum State { IDLE, PLAYER_TURN, PROCESSING, NPC_TURN }

signal turn_started(turn_id: int, duration_sec: float)
signal processing_started()
signal turn_failed(reason: String)
# Текст диктовки: is_final == false — промежуточный (запись идёт), true —
# итоговый после закрытия микрофона; ok == false — распознать не удалось.
signal dictation_result(text: String, is_final: bool, ok: bool)
signal npc_turn_received(turn_id: int, transcript: String, reply_text: String, actions: PackedStringArray, score_delta: int, total_score: int, audio_base64: String)

# ---- клиентское состояние (только "своя" комната) ----
var state: State = State.IDLE
var total_score := 0
var mic_open := false # клиент: микрофон открыт для диктовки (VoiceChat шлёт аудио только тогда)

class RoomTurn:
	var state: int = 0 # State.IDLE
	var current_turn_id := 0
	var current_player_id := -1
	var scenario := "restaurant_date"
	var total_score := 0
	var turn_events: Array = []
	var turn_start_ticks_msec := 0
	var audio_buffer: PackedFloat32Array = PackedFloat32Array()
	var audio_rate := 0 # частота, с которой клиент записал audio_buffer (шлёт вместе с чанками)
	var dictating := false     # микрофон игрока открыт, аудио копится в audio_buffer
	var stt_busy := false      # промежуточное распознавание уже идёт — следующее не запускаем
	var stt_gen := 0           # номер последнего запущенного распознавания: устаревшие ответы отбрасываем
	var stt_last_size := 0     # сколько сэмплов было в буфере при последнем запуске
	var submitted_text := ""   # реплика игрока, отправленная в этот ход
	var history: Array = [] # переписка {role, content} для Claude, пополняется через AiBackend.remember
	var timer: Timer
	var npc_wait_timer: Timer
	var live_timer: Timer      # тик промежуточного распознавания во время диктовки

var _rooms: Dictionary = {}  # room_id -> RoomTurn (актуально только на выделенном сервере)
var _ai: AiBackend

func _ready() -> void:
	# Внешние API нужны только процессу, который ведёт ходы. Клиентам ключи
	# не нужны — иначе каждый клиент ругался бы на их отсутствие.
	if OS.get_cmdline_user_args().has("--dedicated-server"):
		_ai = AiBackend.new()
		add_child(_ai)

# ---------------------------------------------------------------------------
# Запуск сессии в комнате. Вызывает NetworkManager на сервере, когда в
# комнате регистрируется первый игрок ("speaker").
# ---------------------------------------------------------------------------
func start_match(room_id: String, player_id: int) -> void:
	if not multiplayer.is_server() or _rooms.has(room_id):
		return
	var rt := RoomTurn.new()
	rt.current_player_id = player_id
	rt.timer = Timer.new()
	rt.timer.one_shot = true
	rt.timer.timeout.connect(_on_turn_timeout.bind(room_id))
	add_child(rt.timer)
	rt.npc_wait_timer = Timer.new()
	rt.npc_wait_timer.one_shot = true
	rt.npc_wait_timer.timeout.connect(_on_npc_wait_timeout.bind(room_id))
	add_child(rt.npc_wait_timer)
	rt.live_timer = Timer.new()
	rt.live_timer.timeout.connect(_on_live_timer.bind(room_id))
	add_child(rt.live_timer)
	_rooms[room_id] = rt
	_start_player_turn(room_id)

func cleanup_room(room_id: String) -> void:
	if not _rooms.has(room_id):
		return
	var rt: RoomTurn = _rooms[room_id]
	rt.timer.queue_free()
	rt.npc_wait_timer.queue_free()
	rt.live_timer.queue_free()
	_rooms.erase(room_id)

func _start_player_turn(room_id: String) -> void:
	var rt: RoomTurn = _rooms[room_id]
	rt.current_turn_id += 1
	rt.state = State.PLAYER_TURN
	rt.turn_events.clear()
	rt.audio_buffer.resize(0)
	rt.audio_rate = 0
	rt.dictating = false
	rt.stt_busy = false
	rt.stt_last_size = 0
	rt.submitted_text = ""
	rt.live_timer.stop()
	rt.turn_start_ticks_msec = Time.get_ticks_msec()
	rt.timer.start(TURN_DURATION_SEC + TURN_GRACE_SEC)
	for pid in NetworkManager.room_peer_ids(room_id):
		_on_turn_started.rpc_id(pid, rt.current_turn_id, TURN_DURATION_SEC)

@rpc("authority", "reliable")
func _on_turn_started(turn_id: int, duration_sec: float) -> void:
	state = State.PLAYER_TURN
	mic_open = false
	turn_started.emit(turn_id, duration_sec)

# ---------------------------------------------------------------------------
# Приём данных от игрока во время хода
# ---------------------------------------------------------------------------

@rpc("any_peer", "reliable")
func submit_audio_chunk(samples: PackedFloat32Array, sample_rate: int) -> void:
	# sample_rate — частота дискретизации микрофона на клиенте (у клиента и
	# у сервера AudioServer.get_mix_rate() может отличаться, а STT нужна
	# именно частота записи).
	if not multiplayer.is_server() or sample_rate < 8000 or sample_rate > 192000:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	var room_id := NetworkManager.room_of_peer(sender_id)
	if room_id == "" or not _rooms.has(room_id):
		return
	var rt: RoomTurn = _rooms[room_id]
	if rt.state != State.PLAYER_TURN or sender_id != rt.current_player_id or not rt.dictating:
		return
	rt.audio_rate = sample_rate
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

# ---------------------------------------------------------------------------
# Клиентский API ввода (его дёргает TurnUI)
# ---------------------------------------------------------------------------

# Открыть микрофон: сервер начнёт копить аудио и присылать текст диктовки.
func begin_dictation() -> void:
	mic_open = true
	request_dictation_start.rpc_id(1)

# Закрыть микрофон: сервер пришлёт итоговый текст (dictation_result, is_final).
func end_dictation() -> void:
	mic_open = false
	request_dictation_stop.rpc_id(1)

# Отправить реплику (набранную или продиктованную и поправленную) — конец хода игрока.
func submit_text(text: String) -> void:
	mic_open = false
	submit_text_turn.rpc_id(1, text)

# ---------------------------------------------------------------------------
# Серверная часть ввода
# ---------------------------------------------------------------------------

# Комната отправителя RPC, если он сейчас говорящий игрок в фазе своего хода;
# иначе "". Вызывать только прямо из тела RPC (нужен get_remote_sender_id).
func _speaker_room_id() -> String:
	if not multiplayer.is_server():
		return ""
	var sender_id := multiplayer.get_remote_sender_id()
	var room_id := NetworkManager.room_of_peer(sender_id)
	if room_id == "" or not _rooms.has(room_id):
		return ""
	var rt: RoomTurn = _rooms[room_id]
	if rt.state != State.PLAYER_TURN or sender_id != rt.current_player_id:
		return ""
	return room_id

@rpc("any_peer", "reliable")
func request_dictation_start() -> void:
	var room_id := _speaker_room_id()
	if room_id == "":
		return
	var rt: RoomTurn = _rooms[room_id]
	rt.audio_buffer.resize(0) # каждая запись — с чистого листа
	rt.audio_rate = 0
	rt.stt_last_size = 0
	rt.dictating = true
	rt.live_timer.start(LIVE_STT_INTERVAL_SEC)

@rpc("any_peer", "reliable")
func request_dictation_stop() -> void:
	var room_id := _speaker_room_id()
	if room_id == "":
		return
	var rt: RoomTurn = _rooms[room_id]
	if not rt.dictating:
		return
	rt.dictating = false
	rt.live_timer.stop()
	_run_dictation_stt(room_id, true)

@rpc("any_peer", "reliable")
func submit_text_turn(text: String) -> void:
	var room_id := _speaker_room_id()
	if room_id == "":
		return
	_end_player_turn(room_id, text.strip_edges().left(MAX_TEXT_CHARS))

func _on_live_timer(room_id: String) -> void:
	if not _rooms.has(room_id):
		return
	var rt: RoomTurn = _rooms[room_id]
	# Пока прошлое распознавание не вернулось (или звука не прибавилось) — ждём.
	if not rt.dictating or rt.stt_busy or rt.audio_buffer.size() == rt.stt_last_size:
		return
	_run_dictation_stt(room_id, false)

# Распознаёт всё, что накопилось в буфере записи, и шлёт текст говорящему.
func _run_dictation_stt(room_id: String, is_final: bool) -> void:
	var rt: RoomTurn = _rooms[room_id]
	var turn_id := rt.current_turn_id
	var player_id := rt.current_player_id
	rt.stt_gen += 1
	var gen := rt.stt_gen
	rt.stt_last_size = rt.audio_buffer.size()
	if not is_final:
		rt.stt_busy = true
	var stt: Dictionary = await _ai.transcribe(rt.audio_buffer, rt.audio_rate)
	if not is_final:
		rt.stt_busy = false
	# Ответ мог опоздать: ход закончился, комнату закрыли или запущено более свежее распознавание.
	if not _rooms.has(room_id) or rt.current_turn_id != turn_id or rt.state != State.PLAYER_TURN:
		return
	if gen != rt.stt_gen or not NetworkManager.room_peer_ids(room_id).has(player_id):
		return
	if not stt.ok and not is_final:
		return # промежуточный сбой не шумим: ошибка уже в логе, следующий тик попробует снова
	_dictation_result.rpc_id(player_id, stt.text, is_final, stt.ok)

@rpc("authority", "reliable")
func _dictation_result(text: String, is_final: bool, ok: bool) -> void:
	dictation_result.emit(text, is_final, ok)

func _on_turn_timeout(room_id: String) -> void:
	if not _rooms.has(room_id):
		return
	# Игрок ничего не отправил (клиент к этому моменту уже отправил бы то, что
	# было в поле) — ход уходит с пустой репликой.
	if _rooms[room_id].state == State.PLAYER_TURN:
		_end_player_turn(room_id, "")

func _end_player_turn(room_id: String, text: String) -> void:
	var rt: RoomTurn = _rooms[room_id]
	rt.timer.stop()
	rt.live_timer.stop()
	rt.dictating = false
	rt.submitted_text = text
	rt.state = State.PROCESSING
	for pid in NetworkManager.room_peer_ids(room_id):
		_on_processing_started.rpc_id(pid)
	_send_turn_to_backend(room_id)

@rpc("authority", "reliable")
func _on_processing_started() -> void:
	state = State.PROCESSING
	mic_open = false
	processing_started.emit()

# ---------------------------------------------------------------------------
# Обработка хода через внешние API (STT -> LLM -> TTS, см. AiBackend.gd)
# ---------------------------------------------------------------------------

# Корутина: вызывается без await из _end_player_turn. Между await'ами
# комнату могут закрыть, поэтому после каждого шага проверяем, что ход всё
# ещё ждёт ответа именно этой комнаты.
func _send_turn_to_backend(room_id: String) -> void:
	var rt: RoomTurn = _rooms[room_id]
	var turn_id := rt.current_turn_id
	var transcript := rt.submitted_text
	var events := rt.turn_events.duplicate()

	var npc: Dictionary = await _ai.npc_reply(rt.scenario, rt.history, transcript, events)
	if not _is_turn_processing(room_id, turn_id):
		return
	if npc.is_empty():
		_fail_turn(room_id, "собеседник не ответил")
		return

	var reply_text: String = npc.reply_text
	var score_delta: int = npc.score_delta
	var emotion := "good" if score_delta > 0 else "neutral"
	var voice: Dictionary = await _ai.synthesize(reply_text, emotion)
	if not _is_turn_processing(room_id, turn_id):
		return
	if voice.is_empty():
		_fail_turn(room_id, "не удалось озвучить ответ")
		return

	AiBackend.remember(rt.history, npc)
	_apply_npc_turn(room_id, transcript, reply_text, PackedStringArray(npc.actions), score_delta, voice.mp3, voice.duration)

func _is_turn_processing(room_id: String, turn_id: int) -> bool:
	if not _rooms.has(room_id):
		return false
	var rt: RoomTurn = _rooms[room_id]
	return rt.state == State.PROCESSING and rt.current_turn_id == turn_id

# Ход не удался: ни подмен, ни заглушек — клиенты получают причину, а
# через FAIL_PAUSE_SEC (тем же таймером, что и пауза после реплики NPC)
# игрок начинает ход заново. История и счёт остаются как были.
func _fail_turn(room_id: String, reason: String) -> void:
	var rt: RoomTurn = _rooms[room_id]
	push_error("[Ход %d] Ход провален: %s" % [rt.current_turn_id, reason])
	rt.state = State.NPC_TURN # пока висит ошибка, ввод игрока не принимается
	for pid in NetworkManager.room_peer_ids(room_id):
		_on_turn_failed.rpc_id(pid, reason)
	rt.npc_wait_timer.start(FAIL_PAUSE_SEC)

@rpc("authority", "reliable")
func _on_turn_failed(reason: String) -> void:
	state = State.NPC_TURN
	mic_open = false
	turn_failed.emit(reason)

func _apply_npc_turn(room_id: String, transcript: String, reply_text: String, actions: PackedStringArray, score_delta: int, mp3: PackedByteArray, duration_sec: float) -> void:
	var rt: RoomTurn = _rooms[room_id]
	print("[Ход %d] Игрок сказал: %s" % [rt.current_turn_id, transcript if transcript != "" else "(тишина)"])
	if not rt.turn_events.is_empty():
		print("[Ход %d] Действия игрока: %s" % [rt.current_turn_id, str(rt.turn_events)])
	rt.state = State.NPC_TURN
	rt.total_score += score_delta
	var audio_base64 := Marshalls.raw_to_base64(mp3)
	for pid in NetworkManager.room_peer_ids(room_id):
		_broadcast_npc_turn.rpc_id(pid, rt.current_turn_id, transcript, reply_text, actions, score_delta, rt.total_score, audio_base64)
	# Следующий ход игрока стартует не сразу, а после того как реплика NPC
	# "доиграет" — иначе таймер игрока тикал бы поверх ещё звучащего ответа.
	rt.npc_wait_timer.start(maxf(duration_sec, 1.0))

func _on_npc_wait_timeout(room_id: String) -> void:
	if _rooms.has(room_id):
		_start_player_turn(room_id)

@rpc("authority", "reliable")
func _broadcast_npc_turn(turn_id: int, transcript: String, reply_text: String, actions: PackedStringArray, score_delta: int, new_total_score: int, audio_base64: String) -> void:
	print("[Ход %d] Ты сказал: %s" % [turn_id, transcript if transcript != "" else "(речь не распознана)"])
	print("[Ход %d] NPC: %s (actions=%s, score_delta=%d, total=%d)" % [turn_id, reply_text, actions, score_delta, new_total_score])
	state = State.NPC_TURN
	total_score = new_total_score
	npc_turn_received.emit(turn_id, transcript, reply_text, actions, score_delta, new_total_score, audio_base64)
	_play_npc_voice(audio_base64)

var _npc_voice: AudioStreamPlayer

# Голос NPC приходит с сервера готовым mp3 (Яндекс TTS, alena) — все клиенты
# комнаты слышат ровно одну и ту же запись.
func _play_npc_voice(audio_base64: String) -> void:
	var stream := AudioStreamMP3.new()
	stream.data = Marshalls.base64_to_raw(audio_base64)
	if stream.get_length() <= 0.0:
		push_error("Ответ NPC пришёл без читаемого mp3-аудио")
		return
	if _npc_voice == null:
		_npc_voice = AudioStreamPlayer.new()
		_npc_voice.bus = "Master"
		add_child(_npc_voice)
	_npc_voice.stream = stream
	_npc_voice.play()

func _broadcast_event(_room_id: String, _action: String) -> void:
	pass # TODO: применить визуальный эффект события на сцену — ждём
		 # утверждённый командой список интерактивных объектов ресторана
