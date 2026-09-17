extends Node3D

# Болванчик NPC на сцене: слушает npc_turn_received и отыгрывает
# последовательность жестов, которую прислал бэкенд (см. TurnManager.gd —
# actions теперь список, а не одно значение). Каждый шаг — простой твин по
# трансформу узла, без скелетной анимации: модель может быть любая, лишь бы
# был корневой Node3D. Неизвестные/лишние действия просто дают паузу.

const ACTION_DURATION_SEC := 1.2

var _base_y := 0.0

func _ready() -> void:
	_base_y = position.y
	TurnManager.npc_turn_received.connect(_on_npc_turn_received)

func _on_npc_turn_received(_turn_id: int, _transcript: String, _reply_text: String, actions: PackedStringArray, _score_delta: int, _total_score: int, _audio_base64: String) -> void:
	_play_actions(actions)

func _play_actions(actions: PackedStringArray) -> void:
	var list := actions if not actions.is_empty() else PackedStringArray(["idle"])
	var tween := create_tween()
	for a in list:
		_queue_action(tween, a)

func _queue_action(tween: Tween, action: String) -> void:
	match action:
		"talk":
			var beat := ACTION_DURATION_SEC * 0.25
			tween.tween_property(self, "position:y", _base_y + 0.04, beat)
			tween.tween_property(self, "position:y", _base_y, beat)
			tween.tween_property(self, "position:y", _base_y + 0.04, beat)
			tween.tween_property(self, "position:y", _base_y, beat)
		"turn":
			tween.tween_property(self, "rotation:y", TAU, ACTION_DURATION_SEC).as_relative()
		"nod":
			var half := ACTION_DURATION_SEC * 0.5
			tween.tween_property(self, "rotation:x", 0.15, half)
			tween.tween_property(self, "rotation:x", 0.0, half)
		"shrug":
			var half := ACTION_DURATION_SEC * 0.5
			tween.tween_property(self, "scale:y", 0.92, half)
			tween.tween_property(self, "scale:y", 1.0, half)
		_: # "idle" и всё нераспознанное — просто пауза, не ломаем последовательность
			tween.tween_interval(ACTION_DURATION_SEC * 0.5)
