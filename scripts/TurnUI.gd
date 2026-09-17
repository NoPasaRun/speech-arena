extends CanvasLayer

# HUD тестовой сессии: статус хода, обратный отсчёт, счёт и кнопка
# "Завершить ход". Слушает сигналы TurnManager (они приходят на всех
# клиентах через call_local RPC), так что UI одинаково работает и у
# хоста, и у подключившихся. Кнопка завершения хода доступна только
# игроку с ролью "speaker" (см. NetworkManager.players_info) — зрители
# видят статус, но не могут завершать ход за говорящего.

@onready var status_label: Label = $Panel/VBoxContainer/StatusLabel
@onready var start_button: Button = $Panel/VBoxContainer/StartButton
@onready var time_label: Label = $Panel/VBoxContainer/TimeLabel
@onready var score_label: Label = $Panel/VBoxContainer/ScoreLabel
@onready var end_turn_button: Button = $Panel/VBoxContainer/EndTurnButton

var _time_left := 0.0
var _counting_down := false
var _session_started := false

func _ready() -> void:
	end_turn_button.pressed.connect(_on_end_turn_pressed)
	start_button.pressed.connect(_on_start_pressed)
	TurnManager.turn_started.connect(_on_turn_started)
	TurnManager.npc_turn_received.connect(_on_npc_turn_received)
	NetworkManager.room_ready.connect(_on_room_ready)
	status_label.text = "Ожидание начала сессии..."
	time_label.text = ""
	score_label.text = "Счёт: 0"
	end_turn_button.disabled = true
	start_button.visible = false

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

func _is_speaker() -> bool:
	var my_id := multiplayer.get_unique_id()
	var info: Dictionary = NetworkManager.players_info.get(my_id, {})
	return info.get("role", "audience") == "speaker"

func _on_end_turn_pressed() -> void:
	TurnManager.request_end_turn.rpc_id(1)
	end_turn_button.disabled = true

func _on_turn_started(turn_id: int, duration_sec: float) -> void:
	_session_started = true
	start_button.visible = false
	status_label.text = "Ход %d: говори!" % turn_id
	_time_left = duration_sec
	_counting_down = true
	end_turn_button.disabled = not _is_speaker()

func _on_npc_turn_received(_turn_id: int, reply_text: String, _action: String, _score_delta: int, total_score: int, _audio_base64: String) -> void:
	status_label.text = "NPC: %s" % reply_text
	score_label.text = "Счёт: %d" % total_score
	_counting_down = false
	time_label.text = ""
	end_turn_button.disabled = true
