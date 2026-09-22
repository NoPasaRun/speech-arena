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

const LocalServer := preload("res://scripts/LocalServer.gd")

const SERVER_PORT := 7777
const MAX_PLAYERS := 128
const LOCAL_SERVER_STARTUP_SEC := 30.0 # сколько ждём, пока встроенный сервер загрузит проект
const IDLE_EXIT_SEC := 10.0            # сервер с --exit-when-idle гаснет, если после ухода последнего клиента никто не вернулся
const NO_CLIENT_EXIT_SEC := 120.0      # ...или если за это время к нему так никто и не подключился
const ROOM_ID_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" # без 0/O, 1/I — легче продиктовать
const ROOM_ID_LEN := 5

signal room_ready(room_id: String)
signal room_join_failed(reason: String)

# По умолчанию игра поднимает свой сервер сама (см. LocalServer.gd) и ходит
# на него. Флаг --server=IP отправляет клиента на чужой сервер и отключает
# встроенный.
var server_address := "127.0.0.1"

var players_info: Dictionary = {}   # peer_id -> {name, role} — ростер СВОЕЙ комнаты (актуально на клиенте)
var player_nodes: Dictionary = {}   # peer_id -> Node (инстанс Player.tscn), общий для всех комнат в этом процессе
var my_room_id := ""

var _pending_name := "Гость"
var _pending_mode := ""      # "create" | "join"
var _pending_room_id := ""

var _local_server: LocalServer
var _local_server_deadline_msec := 0 # до этого момента неудачное подключение считаем "сервер ещё грузится"
var _bind_ip := ""                   # --bind=IP: слушать только этот адрес (у встроенного сервера — 127.0.0.1)
var _exit_when_idle := false         # --exit-when-idle: см. _check_idle_exit

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

	var args := OS.get_cmdline_user_args()
	var explicit_server := false
	for arg in args:
		if arg.begins_with("--server="):
			server_address = arg.substr("--server=".length())
			explicit_server = true
		elif arg.begins_with("--bind="):
			_bind_ip = arg.substr("--bind=".length())
	_exit_when_idle = args.has("--exit-when-idle")

	if args.has("--dedicated-server"):
		_start_dedicated_server()
	elif not explicit_server:
		_start_local_server()

# Обычный запуск игры: поднимаем сервер сами, дочерним процессом.
func _start_local_server() -> void:
	if OS.has_feature("web") or OS.has_feature("mobile"):
		push_error("На этой платформе встроенный сервер недоступен: укажи внешний флагом --server=IP")
		return
	_local_server = LocalServer.new()
	add_child(_local_server)
	if _local_server.start():
		_local_server_deadline_msec = Time.get_ticks_msec() + int(LOCAL_SERVER_STARTUP_SEC * 1000.0)

func _start_dedicated_server() -> void:
	var peer := ENetMultiplayerPeer.new()
	if not _bind_ip.is_empty():
		peer.set_bind_ip(_bind_ip)
	var err := peer.create_server(SERVER_PORT, MAX_PLAYERS)
	if err != OK:
		# Чаще всего порт уже занят другим сервером — тогда игра просто
		# подключится к нему, а этот процесс без сервера смысла не имеет.
		push_error("Не удалось поднять выделенный сервер на порту %d: %s" % [SERVER_PORT, err])
		get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	print("[DedicatedServer] Слушаю %s:%d" % [_bind_ip if not _bind_ip.is_empty() else "*", SERVER_PORT])
	if _exit_when_idle:
		get_tree().create_timer(NO_CLIENT_EXIT_SEC).timeout.connect(_check_idle_exit)

# Встроенный сервер живёт ровно столько, сколько игра: гаснет, если клиентов
# нет (никто не подключился или последний ушёл и никто не вернулся).
func _check_idle_exit() -> void:
	if multiplayer.get_peers().is_empty():
		print("[DedicatedServer] Клиентов нет, завершаюсь")
		get_tree().quit()

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
	if Time.get_ticks_msec() < _local_server_deadline_msec:
		# Встроенный сервер ещё грузит проект (несколько секунд) — пробуем снова.
		await get_tree().create_timer(1.0).timeout
		_connect_to_server()
		return
	push_error("Подключение не удалось")
	room_join_failed.emit("не удалось подключиться к серверу")

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
		if _exit_when_idle:
			# Решение принимаем не сейчас, а через паузу: вдруг игрок сразу вернулся.
			get_tree().create_timer(IDLE_EXIT_SEC).timeout.connect(_check_idle_exit)
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
