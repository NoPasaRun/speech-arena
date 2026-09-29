extends Node
## Автозагрузка: фоновая музыка арены. Запускается один раз, когда локальный
## игрок попадает в комнату (создал её или подключился), и плавно нарастает
## из тишины, чтобы не бить по ушам.

const TRACK_PATH := "res://models/shrek.mp3"
const FADE_IN_SECONDS := 2.5
const TARGET_VOLUME_DB := -8.0
const SILENT_VOLUME_DB := -80.0

var _player: AudioStreamPlayer


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	add_child(_player)

	var stream := load(TRACK_PATH) as AudioStreamMP3
	stream.loop = true
	_player.stream = stream
	_player.volume_db = SILENT_VOLUME_DB


func play_room_music() -> void:
	if _player.playing:
		return
	_player.volume_db = SILENT_VOLUME_DB
	_player.play()
	create_tween().tween_property(_player, "volume_db", TARGET_VOLUME_DB, FADE_IN_SECONDS)
