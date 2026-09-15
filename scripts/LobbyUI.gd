extends CanvasLayer

@onready var name_edit: LineEdit = $Panel/VBoxContainer/NameEdit
@onready var ip_edit: LineEdit = $Panel/VBoxContainer/IPEdit
@onready var host_btn: Button = $Panel/VBoxContainer/HostButton
@onready var join_btn: Button = $Panel/VBoxContainer/JoinButton

func _ready() -> void:
	host_btn.pressed.connect(_on_host)
	join_btn.pressed.connect(_on_join)

func _on_host() -> void:
	var pname := name_edit.text if name_edit.text != "" else "Хост"
	NetworkManager.host_game(pname)
	hide()

func _on_join() -> void:
	var pname := name_edit.text if name_edit.text != "" else "Гость"
	var ip := ip_edit.text if ip_edit.text != "" else "127.0.0.1"
	NetworkManager.join_game(ip, pname)
	hide()
