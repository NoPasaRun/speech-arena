extends Node

# Синглтон (автозагрузка). Отвечает за:
# 1. Хостинг/подключение к комнате (ENet, топология звезда: Client-Server-Client)
# 2. Спавн игроков в сцене
# 3. Релей "сырого" голоса через сервер (тестовая реализация — см. README,
#    для продакшена заменить на WebRTC + SFU типа LiveKit/mediasoup)

const PORT := 7777
const MAX_PLAYERS := 32

var players_info: Dictionary = {}   # peer_id -> {name, role}
var player_nodes: Dictionary = {}   # peer_id -> Node (инстанс Player.tscn)
var _pending_name := "Гость"

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_connected_fail)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	
func _spawn_via_spawner(id: int) -> void:
	if not multiplayer.is_server():
		return
	var players_root := get_tree().current_scene.get_node("Players")
	var spawner: MultiplayerSpawner = players_root.get_node("PlayerSpawner")
	spawner.spawn({"id": id})

func host_game(player_name: String) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		push_error("Не удалось создать сервер: %s" % err)
		return
	multiplayer.multiplayer_peer = peer
	players_info[1] = {"name": player_name, "role": "speaker"}
	_spawn_via_spawner(1)

func join_game(address: String, player_name: String) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, PORT)
	if err != OK:
		push_error("Не удалось подключиться: %s" % err)
		return
	multiplayer.multiplayer_peer = peer
	_pending_name = player_name

func _on_peer_connected(_id: int) -> void:
	pass # ждём, пока клиент сам зарегистрируется (см. _on_connected_ok)

func _on_connected_ok() -> void:
	var my_id := multiplayer.get_unique_id()
	rpc_id(1, "_register_player", my_id, _pending_name)

@rpc("any_peer", "reliable")
func _register_player(id: int, player_name: String) -> void:
	if not multiplayer.is_server():
		return
	players_info[id] = {"name": player_name, "role": "audience"}
	rpc("_sync_players", players_info)
	_spawn_via_spawner(id)

@rpc("authority", "reliable")
func _sync_players(data: Dictionary) -> void:
	players_info = data

func _on_peer_disconnected(id: int) -> void:
	players_info.erase(id)
	if multiplayer.is_server() and player_nodes.has(id):
		player_nodes[id].queue_free()
	player_nodes.erase(id)

func _on_connected_fail() -> void:
	push_error("Подключение не удалось")

func _on_server_disconnected() -> void:
	push_error("Сервер отключился")

# ---------- Голос (тестовый релей поверх ENet, топология звезда) ----------

@rpc("any_peer", "call_local", "unreliable_ordered")
func relay_audio(samples: PackedFloat32Array) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id == 0:
		sender_id = multiplayer.get_unique_id()
	for peer_id in multiplayer.get_peers():
		if peer_id != sender_id:
			_dispatch_audio.rpc_id(peer_id, sender_id, samples)
	if sender_id != multiplayer.get_unique_id():
		_play_incoming_local(sender_id, samples)

@rpc("authority", "unreliable_ordered")
func _dispatch_audio(sender_id: int, samples: PackedFloat32Array) -> void:
	_play_incoming_local(sender_id, samples)

func _play_incoming_local(sender_id: int, samples: PackedFloat32Array) -> void:
	if player_nodes.has(sender_id) and player_nodes[sender_id].has_node("VoiceChat"):
		player_nodes[sender_id].get_node("VoiceChat").play_incoming(samples)
