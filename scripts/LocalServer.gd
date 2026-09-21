extends Node

# Встроенный локальный сервер. При обычном запуске игры NetworkManager
# создаёт этот узел, и он поднимает выделенный сервер — тот же самый проект,
# запущенный дочерним процессом в режиме `--headless -- --dedicated-server`.
# Игроку не нужно ни запускать второй Godot, ни передавать флаги: всё стартует
# одной кнопкой, а сервер сам завершается, когда игра закрыта (см. флаг
# --exit-when-idle в NetworkManager.gd) — так же он гаснет, если игру убили
# без корректного выхода.
#
# Это монолит, который легко расцепить: сервер — тот же код, что и раньше,
# он общается с клиентом только по сети (ENet на 127.0.0.1). Чтобы вынести его
# на отдельную машину, достаточно запустить игру с `--server=IP` (тогда этот
# узел вообще не создаётся) и поднять сервер там командой
# `--headless -- --dedicated-server`.

const LOG_FILE := "user://local_server.log"

var _pid := -1

# Возвращает false, если процесс не удалось запустить.
func start() -> bool:
	var args := PackedStringArray(["--headless"])
	if OS.has_feature("editor"):
		# Игра запущена из редактора: исполняемый файл — сам Godot, ему нужен путь к проекту.
		args.append_array(["--path", ProjectSettings.globalize_path("res://")])
	# Вывод дочернего процесса не виден в консоли редактора — пишем в файл.
	var log_path := ProjectSettings.globalize_path(LOG_FILE)
	args.append_array(["--log-file", log_path])
	args.append_array(["--", "--dedicated-server", "--bind=127.0.0.1", "--exit-when-idle"])
	_pid = OS.create_process(OS.get_executable_path(), args)
	if _pid <= 0:
		push_error("Не удалось запустить локальный сервер: %s" % OS.get_executable_path())
		return false
	print("[LocalServer] запущен (pid %d), лог сервера: %s" % [_pid, log_path])
	return true

func stop() -> void:
	if _pid > 0:
		OS.kill(_pid)
		_pid = -1

func _exit_tree() -> void:
	stop()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		stop()
