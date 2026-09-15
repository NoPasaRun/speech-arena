extends Node3D

func _ready() -> void:
	var spawner: MultiplayerSpawner = $Players/PlayerSpawner
	spawner.spawn_function = _spawn_player

func _spawn_player(data: Dictionary) -> Node:
	var player_scene: PackedScene = preload("res://scenes/Player.tscn")
	var p := player_scene.instantiate()
	var id: int = data["id"]
	p.name = str(id)
	p.set_multiplayer_authority(id)
	NetworkManager.player_nodes[id] = p
	return p
