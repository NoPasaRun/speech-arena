extends Node

# Синглтон (автозагрузка). Отвечает за:
# 1. Выделенный сервер: держит ENet-порт и раздаёт комнаты по коду (room_id).
#    Один процесс обслуживает СРАЗУ несколько комнат — состояние каждой
#    комнаты живёт в _rooms[room_id], а не в полях этого узла, поэтому
#    комнаты не мешают друг другу.
# 2. Клиент: подключается к выделенному серверу и создаёт/входит в комнату
#    по её коду вместо прямого подключения к IP другого игрока.
# 3. Спавн игроков через общий MultiplayerSpawner (см. Main.gd).
# 4. Релей "сырого" голоса через сервер, в пределах одной комнаты (тестовая
#    реализация — см. README, для продакшена заменить на WebRTC + SFU).
#
# ВНИМАНИЕ (известное ограничение): спавн игроков сейчас идёт через ОДИН
# общий MultiplayerSpawner на весь процесс, поэтому сам факт спавна узла
# технически реплицируется всем — на клиенте чужой комнаты это лишний узел
# в сцене. Но его позиция/поворот (MultiplayerSynchronizer) больше НЕ текут
# за пределы комнаты: public_visibility=false в Player.tscn + точечные
# set_visibility_for() в _grant_room_visibility() ниже. Полностью убрать
# и сам "призрачный" узел можно только настоящим разделением на per-room
# MultiplayerAPI/ENet-пир — сознательно не делали, см. обсуждение в чате.

const SERVER_PORT := 7777
const MAX_PLAYERS := 128
const ROOM_ID_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" # без 0/O, 1/I — легче продиктовать
const ROOM_ID_LEN := 5

signal room_ready(room_id: String)
signal room_join_failed(reason: String)

var server_address := "77.42.43.16" # выделенный сервер (hetzner_gearstore); переопределяется флагом --server=IP

var players_info: Dictionary = {}   # peer_id -> {name, role} — ростер СВОЕЙ комнаты (актуально на клиенте)
var player_nodes: Dictionary = {}   # peer_id -> Node (инстанс Player.tscn), общий для всех комнат в этом процессе
var my_room_id := ""

var _pending_name := "Гость"
var _pending_mode := ""      # "create" | "join"
var _pending_room_id := ""

# ---------- Состояние выделенного сервера (актуально только в его процессе) ----------
class RoomData:
	var room_id: String
	var players_info: Dictionary = {}
	func _init(id: String) -> void:
		room_id = id

var _rooms: Dictionary = {}      # room_id -> RoomData
var _peer_room: Dictionary = {}  # peer_id -> room_id

func _ready() -> void:
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_connected_fail)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--server="):
			server_address = arg.substr("--server=".length())

	if OS.get_cmdline_user_args().has("--dedicated-server"):
		_start_dedicated_server()

func _start_dedicated_server() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(SERVER_PORT, MAX_PLAYERS)
	if err != OK:
		push_error("Не удалось поднять выделенный сервер: %s" % err)
		return
	multiplayer.multiplayer_peer = peer
	print("[DedicatedServer] Слушаю порт %d" % SERVER_PORT)

# ---------------------------------------------------------------------------
# Клиент: подключение к выделенному серверу и вход в комнату по коду
# ---------------------------------------------------------------------------

func create_room(player_name: String) -> void:
	_pending_name = player_name
	_pending_mode = "create"
	_connect_to_server()

func join_room(room_id: String, player_name: String) -> void:
	_pending_name = player_name
	_pending_mode = "join"
	_pending_room_id = room_id.strip_edges().to_upper()
	_connect_to_server()

func _connect_to_server() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(server_address, SERVER_PORT)
	if err != OK:
		push_error("Не удалось подключиться к серверу: %s" % err)
		return
	multiplayer.multiplayer_peer = peer

func _on_connected_ok() -> void:
	match _pending_mode:
		"create":
			rpc_id(1, "_request_create_room", _pending_name)
		"join":
			rpc_id(1, "_request_join_room", _pending_room_id, _pending_name)

func _on_connected_fail() -> void:
	push_error("Подключение не удалось")

func _on_server_disconnected() -> void:
	push_error("Сервер отключился")

# ---------------------------------------------------------------------------
# Сервер: лобби (создание комнаты / вход по коду)
# ---------------------------------------------------------------------------

@rpc("any_peer", "reliable")
func _request_create_room(player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	var room_id := _generate_room_id()
	_rooms[room_id] = RoomData.new(room_id)
	_join_room_internal(room_id, sender_id, player_name)

@rpc("any_peer", "reliable")
func _request_join_room(room_id: String, player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	room_id = room_id.strip_edges().to_upper()
	if not _rooms.has(room_id):
		rpc_id(sender_id, "_room_join_failed", "Комната не найдена")
		return
	_join_room_internal(room_id, sender_id, player_name)

func _join_room_internal(room_id: String, peer_id: int, player_name: String) -> void:
	var room: RoomData = _rooms[room_id]
	var role := "speaker" if room.players_info.is_empty() else "audience"
	var existing_peers := room.players_info.keys()
	room.players_info[peer_id] = {"name": player_name, "role": role}
	_peer_room[peer_id] = room_id
	_spawn_via_spawner(peer_id)
	_grant_room_visibility(peer_id, existing_peers)
	for pid in room.players_info.keys():
		rpc_id(pid, "_room_state", room_id, room.players_info)

# Игрок-спикер жмёт кнопку "Начать сессию" в TurnUI уже ПОСЛЕ телепортации
# в сцену — сессия больше не стартует автоматически при создании комнаты.
@rpc("any_peer", "reliable")
func request_start_session() -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	var room_id := room_of_peer(sender_id)
	if room_id == "" or not _rooms.has(room_id):
		return
	var room: RoomData = _rooms[room_id]
	var info: Dictionary = room.players_info.get(sender_id, {})
	if info.get("role", "") != "speaker":
		return
	TurnManager.start_match(room_id, sender_id)

# Аватары спавнятся через ОДИН общий MultiplayerSpawner на весь процесс (см.
# известное ограничение в шапке файла), поэтому сам факт спавна виден всем
# комнатам. Но позицию/поворот (MultiplayerSynchronizer) включаем только
# внутри своей комнаты — иначе чужая комната видела бы, как двигается не их
# собеседник.
func _grant_room_visibility(new_peer_id: int, existing_peers: Array) -> void:
	var new_sync := _get_synchronizer(new_peer_id)
	for pid in existing_peers:
		var other_sync := _get_synchronizer(pid)
		if new_sync:
			new_sync.set_visibility_for(pid, true)
		if other_sync:
			other_sync.set_visibility_for(new_peer_id, true)

func _get_synchronizer(peer_id: int) -> MultiplayerSynchronizer:
	if not player_nodes.has(peer_id):
		return null
	return player_nodes[peer_id].get_node("MultiplayerSynchronizer") as MultiplayerSynchronizer

func _generate_room_id() -> String:
	var id := ""
	for i in ROOM_ID_LEN:
		id += ROOM_ID_CHARS[randi() % ROOM_ID_CHARS.length()]
	return id if not _rooms.has(id) else _generate_room_id()

func room_of_peer(peer_id: int) -> String:
	return _peer_room.get(peer_id, "")

func room_peer_ids(room_id: String) -> Array:
	if not _rooms.has(room_id):
		return []
	return _rooms[room_id].players_info.keys()

@rpc("authority", "reliable")
func _room_state(room_id: String, data: Dictionary) -> void:
	my_room_id = room_id
	players_info = data
	room_ready.emit(room_id)

@rpc("authority", "reliable")
func _room_join_failed(reason: String) -> void:
	room_join_failed.emit(reason)

# ---------------------------------------------------------------------------
# Сервер: спавн игроков (общий MultiplayerSpawner, см. Main.gd/Main.tscn)
# ---------------------------------------------------------------------------

func _spawn_via_spawner(id: int) -> void:
	if not multiplayer.is_server():
		return
	var players_root := get_tree().current_scene.get_node("Players")
	var spawner: MultiplayerSpawner = players_root.get_node("PlayerSpawner")
	spawner.spawn({"id": id})

func _on_peer_disconnected(id: int) -> void:
	if multiplayer.is_server():
		_server_on_peer_disconnected(id)
	player_nodes.erase(id)

func _server_on_peer_disconnected(id: int) -> void:
	if not _peer_room.has(id):
		return
	var room_id: String = _peer_room[id]
	_peer_room.erase(id)
	if not _rooms.has(room_id):
		return
	var room: RoomData = _rooms[room_id]
	room.players_info.erase(id)
	if player_nodes.has(id):
		player_nodes[id].queue_free()
	if room.players_info.is_empty():
		_rooms.erase(room_id)
		TurnManager.cleanup_room(room_id)
	else:
		for pid in room.players_info.keys():
			rpc_id(pid, "_room_state", room_id, room.players_info)

# ---------- Голос (тестовый релей поверх ENet, в пределах одной комнаты) ----------

@rpc("any_peer", "unreliable_ordered")
func relay_audio(samples: PackedFloat32Array) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	var room_id := room_of_peer(sender_id)
	if room_id == "" or not _rooms.has(room_id):
		return
	for peer_id in _rooms[room_id].players_info.keys():
		if peer_id != sender_id:
			_dispatch_audio.rpc_id(peer_id, sender_id, samples)

@rpc("authority", "unreliable_ordered")
func _dispatch_audio(sender_id: int, samples: PackedFloat32Array) -> void:
	_play_incoming_local(sender_id, samples)

func _play_incoming_local(sender_id: int, samples: PackedFloat32Array) -> void:
	if player_nodes.has(sender_id) and player_nodes[sender_id].has_node("VoiceChat"):
		player_nodes[sender_id].get_node("VoiceChat").play_incoming(samples)
