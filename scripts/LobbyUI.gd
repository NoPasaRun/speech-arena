extends CanvasLayer

@onready var name_edit: LineEdit = $Panel/VBoxContainer/NameEdit
@onready var room_id_edit: LineEdit = $Panel/VBoxContainer/RoomIdEdit
@onready var host_btn: Button = $Panel/VBoxContainer/HostButton
@onready var join_btn: Button = $Panel/VBoxContainer/JoinButton
@onready var status_label: Label = $Panel/VBoxContainer/StatusLabel

func _ready() -> void:
	host_btn.pressed.connect(_on_host)
	join_btn.pressed.connect(_on_join)
	NetworkManager.room_ready.connect(_on_room_ready)
	NetworkManager.room_join_failed.connect(_on_room_join_failed)

func _on_host() -> void:
	var pname := name_edit.text if name_edit.text != "" else "Хост"
	_set_busy("Создаю комнату...")
	NetworkManager.create_room(pname)

func _on_join() -> void:
	var pname := name_edit.text if name_edit.text != "" else "Гость"
	var room_id := room_id_edit.text
	_set_busy("Подключаюсь...")
	NetworkManager.join_room(room_id, pname)

func _set_busy(text: String) -> void:
	status_label.text = text
	host_btn.disabled = true
	join_btn.disabled = true

func _on_room_ready(room_id: String) -> void:
	status_label.text = "Комната: %s" % room_id
	name_edit.editable = false
	room_id_edit.editable = false

func _on_room_join_failed(reason: String) -> void:
	status_label.text = "Ошибка: %s" % reason
	host_btn.disabled = false
	join_btn.disabled = false
