extends CanvasLayer

# HUD тестовой сессии: статус хода, обратный отсчёт, счёт, поле ввода реплики
# (клавиатура или голос), кнопка микрофона и кнопка "Отправить". Слушает
# сигналы TurnManager (они приходят на всех клиентах через RPC), так что UI
# одинаково работает и у хоста, и у подключившихся. Вводить и отправлять
# реплику может только игрок с ролью "speaker" (см. NetworkManager.players_info)
# — зрители видят статус, но ход за говорящего не делают.
#
# Ввод голосом: "Говорить" открывает микрофон, и пока идёт запись, текст в
# поле обновляется по мере распознавания (то, что там было до записи, остаётся
# в начале). "Стоп" закрывает микрофон и приносит итоговый текст, который
# можно поправить руками. "Отправить" (или Enter) отправляет то, что в поле;
# когда отсчёт хода дошёл до нуля, отправляется то, что успели набрать.
# Поле ввода и кнопки создаются в коде (_build_input_controls): панель в
# Main.tscn рассчитана только на статус и одну кнопку.

const MIC_IDLE_TEXT := "Говорить"
const MIC_ACTIVE_TEXT := "Стоп"
const MIC_BUSY_TEXT := "Распознаю..."

@onready var panel: Panel = $Panel
@onready var status_label: Label = $Panel/VBoxContainer/StatusLabel
@onready var start_button: Button = $Panel/VBoxContainer/StartButton
@onready var time_label: Label = $Panel/VBoxContainer/TimeLabel
@onready var score_label: Label = $Panel/VBoxContainer/ScoreLabel
@onready var send_button: Button = $Panel/VBoxContainer/EndTurnButton # узел из сцены, здесь это "Отправить"

var input_edit: LineEdit
var mic_button: Button

var _time_left := 0.0
var _counting_down := false
var _session_started := false
var _input_enabled := false
var _dictation_prefix := "" # текст, который уже был в поле, когда включили микрофон

func _ready() -> void:
	_build_input_controls()
	send_button.pressed.connect(_send)
	start_button.pressed.connect(_on_start_pressed)
	TurnManager.turn_started.connect(_on_turn_started)
	TurnManager.processing_started.connect(_on_processing_started)
	TurnManager.npc_turn_received.connect(_on_npc_turn_received)
	TurnManager.turn_failed.connect(_on_turn_failed)
	TurnManager.dictation_result.connect(_on_dictation_result)
	NetworkManager.room_ready.connect(_on_room_ready)
	status_label.text = "Ожидание начала сессии..."
	time_label.text = ""
	score_label.text = "Счёт: 0"
	start_button.visible = false
	_set_input_enabled(false)

func _build_input_controls() -> void:
	# Панель из сцены рассчитана на статус и одну кнопку — расширяем под поле ввода.
	panel.offset_left = -260.0
	panel.offset_right = 260.0
	panel.offset_bottom = panel.offset_top + 230.0

	input_edit = LineEdit.new()
	input_edit.placeholder_text = "Скажи в микрофон или напиши реплику"
	input_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_edit.max_length = TurnManager.MAX_TEXT_CHARS
	input_edit.text_submitted.connect(_on_text_submitted)

	mic_button = Button.new()
	mic_button.toggle_mode = true
	mic_button.text = MIC_IDLE_TEXT
	mic_button.toggled.connect(_on_mic_toggled)

	var row := HBoxContainer.new()
	row.add_child(input_edit)
	row.add_child(mic_button)
	var box := send_button.get_parent()
	box.add_child(row)
	box.move_child(row, send_button.get_index()) # поле ввода — над кнопкой "Отправить"
	send_button.text = "Отправить"

func _on_room_ready(_room_id: String) -> void:
	if not _session_started:
		start_button.visible = _is_speaker()

func _on_start_pressed() -> void:
	NetworkManager.request_start_session.rpc_id(1)
	start_button.visible = false

func _process(delta: float) -> void:
	if not _counting_down:
		return
	_time_left = maxf(_time_left - delta, 0.0)
	time_label.text = "Осталось: %d сек" % ceili(_time_left)
	if _time_left <= 0.0:
		_counting_down = false
		# Время вышло: уходит то, что успели набрать (даже если поле пустое).
		_send(true)

func _is_speaker() -> bool:
	var my_id := multiplayer.get_unique_id()
	var info: Dictionary = NetworkManager.players_info.get(my_id, {})
	return info.get("role", "audience") == "speaker"

# Включает/выключает весь блок ввода. Выключение заодно закрывает микрофон в UI
# (сервер узнаёт о конце диктовки из submit_text / конца хода).
func _set_input_enabled(enabled: bool) -> void:
	_input_enabled = enabled
	input_edit.editable = enabled
	mic_button.disabled = not enabled
	send_button.disabled = not enabled
	if not enabled:
		mic_button.set_pressed_no_signal(false)
		mic_button.text = MIC_IDLE_TEXT

func _on_text_submitted(_text: String) -> void:
	_send()

# force — отправить, даже если поле пустое (истёк таймер хода).
func _send(force := false) -> void:
	if not _input_enabled:
		return
	var text := input_edit.text.strip_edges()
	if text.is_empty() and not force:
		status_label.text = "Скажи что-нибудь или напиши реплику — пустую не отправить"
		return
	_set_input_enabled(false)
	TurnManager.submit_text(text)

func _on_mic_toggled(pressed: bool) -> void:
	if pressed:
		_dictation_prefix = input_edit.text.strip_edges()
		input_edit.editable = false # пока идёт запись, текст пишет распознавание
		mic_button.text = MIC_ACTIVE_TEXT
		status_label.text = "Слушаю... скажи реплику и нажми «Стоп»"
		TurnManager.begin_dictation()
	else:
		mic_button.disabled = true # до прихода итогового текста
		mic_button.text = MIC_BUSY_TEXT
		TurnManager.end_dictation()

func _on_dictation_result(text: String, is_final: bool, ok: bool) -> void:
	if not _input_enabled:
		return
	if ok:
		input_edit.text = (_dictation_prefix + " " + text).strip_edges()
		input_edit.caret_column = input_edit.text.length()
	if not is_final:
		return
	# Итоговый текст: возвращаем управление игроку, чтобы он мог поправить и отправить.
	mic_button.set_pressed_no_signal(false)
	mic_button.text = MIC_IDLE_TEXT
	mic_button.disabled = false
	input_edit.editable = true
	input_edit.grab_focus()
	if not ok:
		status_label.text = "Не удалось распознать речь. Напиши реплику или запиши ещё раз."
	elif text.strip_edges().is_empty():
		status_label.text = "Речь не распознана (микрофон тихий или пустой). Запиши ещё раз или напиши текстом."
	else:
		status_label.text = "Проверь текст, поправь при необходимости и нажми «Отправить» (Enter)"

func _on_processing_started() -> void:
	_counting_down = false
	time_label.text = ""
	status_label.text = "NPC думает..."
	_set_input_enabled(false)

func _on_turn_failed(reason: String) -> void:
	status_label.text = "Ошибка: %s. Повтори ход через пару секунд." % reason
	_counting_down = false
	time_label.text = ""
	_set_input_enabled(false)

func _on_turn_started(turn_id: int, duration_sec: float) -> void:
	_session_started = true
	start_button.visible = false
	status_label.text = "Ход %d: говори или пиши!" % turn_id
	_time_left = duration_sec
	_counting_down = true
	input_edit.text = ""
	_dictation_prefix = ""
	var speaker := _is_speaker()
	_set_input_enabled(speaker)
	if speaker:
		# Для ввода нужна мышь: игровая камера захватывает её (см. Player.gd).
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		input_edit.grab_focus()

func _on_npc_turn_received(_turn_id: int, _transcript: String, reply_text: String, _actions: PackedStringArray, _score_delta: int, total_score: int, _audio_base64: String) -> void:
	status_label.text = "NPC: %s" % reply_text
	score_label.text = "Счёт: %d" % total_score
	_counting_down = false
	time_label.text = ""
	_set_input_enabled(false)
