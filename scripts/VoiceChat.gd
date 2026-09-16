extends Node

# ВНИМАНИЕ: это тестовая реализация голоса для арены — сырой PCM (float32)
# гонится через обычный ENet-канал сервера (unreliable_ordered).
# Для реального продукта (много зрителей, стабильность, эхоподавление,
# компрессия Opus) это нужно заменить на WebRTC + SFU (LiveKit/mediasoup),
# как обсуждали: здесь топология та же (звезда через сервер), просто
# транспорт и кодек кустарные — годится только чтобы проверить архитектуру.

const BUS_NAME := "Mic"
const MIX_RATE := 24000
const CHUNK_FRAMES := 256

var capture_effect: AudioEffectCapture
var playback: AudioStreamGeneratorPlayback
var enabled := false

@onready var mic_player: AudioStreamPlayer = AudioStreamPlayer.new()
@onready var out_player: AudioStreamPlayer = $Playback

func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = AudioServer.get_mix_rate()
	gen.buffer_length = 0.3
	out_player.stream = gen
	out_player.bus = "Master"
	out_player.play()
	playback = out_player.get_stream_playback()

func start_capture() -> void:
	var idx := AudioServer.get_bus_index(BUS_NAME)
	if idx == -1:
		push_warning("Шина '%s' не найдена. Создай её в Audio Bus Layout и добавь эффект Capture (см. README)." % BUS_NAME)
		return

	# Проигрываем вход с микрофона в шину Mic, но саму шину заглушаем,
	# чтобы не слышать себя — Capture-эффект всё равно видит сигнал.
	mic_player.stream = AudioStreamMicrophone.new()
	mic_player.bus = BUS_NAME
	add_child(mic_player)
	mic_player.play()
	AudioServer.set_bus_mute(idx, true)

	for i in AudioServer.get_bus_effect_count(idx):
		var fx := AudioServer.get_bus_effect(idx, i)
		if fx is AudioEffectCapture:
			capture_effect = fx
			break
	if capture_effect == null:
		push_warning("На шине '%s' нет эффекта Capture — добавь его в редакторе." % BUS_NAME)
		return

	enabled = true
	set_process(true)

func _process(_delta: float) -> void:
	if not enabled or capture_effect == null:
		return
	if capture_effect.get_frames_available() < CHUNK_FRAMES:
		return
	var stereo_buf := capture_effect.get_buffer(CHUNK_FRAMES)
	var mono := PackedFloat32Array()
	mono.resize(stereo_buf.size())
	for i in stereo_buf.size():
		mono[i] = stereo_buf[i].x
	print("Отправляю пакет, семплов: ", mono.size())
	NetworkManager.relay_audio.rpc_id(1, mono)

func play_incoming(samples: PackedFloat32Array) -> void:
	if playback == null:
		return
	for s in samples:
		if playback.get_frames_available() > 0:
			playback.push_frame(Vector2(s, s))
