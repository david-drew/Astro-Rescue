## res://scripts/modes/mode4/mission_board_manager.gd
extends Control

##
# MissionBoardManager
#
# Responsibilities:
#  - Read missions from GameState.available_missions.
#  - Display up to max_displayed_missions in a simple list.
#  - On selection:
#       - Set GameState.current_mission_config via set_current_mission_config().
#       - Rely on GameState/EventBus.mission_config_set for scene transitions
#         (handled by a SceneManager or game.gd elsewhere).
#
# Notes:
#  - Works with both authored JSON missions and future procedural missions.
#  - Does not care how GameState.available_missions is populated.
##

@export var max_displayed_missions: int = 5

# Container that will hold the clickable mission entries (e.g. Buttons).
@onready var missions_container: Control = %MissionsContainer

# Optional label to show when no missions are available (if present in the scene).
@onready var empty_label:Label = $MarginContainer/EmtpyLabel

# Internal cache of missions currently displayed.
var _displayed_missions: Array = []    # Array[Dictionary]


func _ready() -> void:
	_refresh_from_gamestate()


# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func refresh() -> void:
	##
	# Public method: call this when GameState.available_missions changes
	# (e.g., after WorldSimManager / MissionGenerator updates the list).
	##
	_refresh_from_gamestate()


# -------------------------------------------------------------------
# Internal helpers
# -------------------------------------------------------------------

func _refresh_from_gamestate() -> void:
	if missions_container == null:
		push_warning("MissionBoardManager: missions_container is not set. Ensure a %MissionsContainer node exists.")
		return

	_clear_mission_list()
	_displayed_missions.clear()

	if not GameState:
		push_warning("MissionBoardManager: GameState autoload not found.")
		return

	var source_missions: Array = GameState.available_missions

	if source_missions.is_empty():
		_show_empty_state(true)
		return

	_show_empty_state(false)

	var count: int = source_missions.size()
	if count > max_displayed_missions:
		count = max_displayed_missions

	for i in range(count):
		var mission_cfg_raw = source_missions[i]
		if typeof(mission_cfg_raw) != TYPE_DICTIONARY:
			continue

		var mission_cfg: Dictionary = mission_cfg_raw
		_displayed_missions.append(mission_cfg)
		_add_mission_button(i, mission_cfg)


func _clear_mission_list() -> void:
	if missions_container == null:
		return

	for child in missions_container.get_children():
		missions_container.remove_child(child)
		child.queue_free()


func _show_empty_state(show: bool) -> void:
	if empty_label == null:
		return
	empty_label.visible = show


func _add_mission_button(queue_index: int, mission_cfg: Dictionary) -> void:
	var button := Button.new()

	var display_name: String = mission_cfg.get("display_name", "")
	if display_name == "":
		display_name = mission_cfg.get("id", "Unknown mission")

	button.text = display_name

	# Tooltip: show a bit more info if available.
	var tier: int = int(mission_cfg.get("tier", 0))
	var is_training: bool = bool(mission_cfg.get("is_training", false))
	var tooltip_lines: Array = []

	tooltip_lines.append("ID: " + mission_cfg.get("id", "unknown"))
	tooltip_lines.append("Tier: " + str(tier))
	if is_training:
		tooltip_lines.append("Type: Training")
	else:
		tooltip_lines.append("Type: Regular")

	var rewards: Dictionary = mission_cfg.get("rewards", {})
	if not rewards.is_empty():
		var base_credits: int = int(rewards.get("base_credits", 0))
		var bonus_credits: int = int(rewards.get("bonus_credits", 0))
		tooltip_lines.append("Base Credits: " + str(base_credits))
		if bonus_credits != 0:
			tooltip_lines.append("Bonus Credits: " + str(bonus_credits))

	button.tooltip_text = "\n".join(tooltip_lines)

	# Store the index into GameState.available_missions on the button metadata.
	button.set_meta("mission_queue_index", queue_index)

	# Connect button press.
	button.pressed.connect(Callable(self, "_on_mission_button_pressed").bind(button))

	missions_container.add_child(button)


# -------------------------------------------------------------------
# Event handlers
# -------------------------------------------------------------------

func _on_mission_button_pressed(button: Button) -> void:
	if not GameState:
		push_warning("MissionBoardManager: GameState autoload not found; cannot start mission.")
		return

	if button == null:
		return

	var queue_index_meta = button.get_meta("mission_queue_index")
	if queue_index_meta == null:
		push_warning("MissionBoardManager: Button has no mission_queue_index metadata.")
		return

	var queue_index: int = int(queue_index_meta)

	var missions_array: Array = GameState.available_missions
	if queue_index < 0 or queue_index >= missions_array.size():
		push_warning("MissionBoardManager: Mission index out of range: " + str(queue_index))
		return

	var mission_cfg_raw = missions_array[queue_index]
	if typeof(mission_cfg_raw) != TYPE_DICTIONARY:
		push_warning("MissionBoardManager: Selected mission is not a Dictionary.")
		return

	var mission_cfg: Dictionary = mission_cfg_raw

	# Set the current mission config in GameState. This will:
	#  - Increment GameState's internal mission counter.
	#  - Emit EventBus.mission_config_set(mission_id, mission_config).
	GameState.set_current_mission_config(mission_cfg)

	# Optional: if you want to immediately remove this mission from the available list
	# (so it is not re-offered), you can uncomment this block.
	#
	# missions_array.remove_at(queue_index)
	# GameState.available_missions = missions_array
	# refresh()

	# Scene transition into Mode 1 is handled elsewhere (e.g., a SceneManager or game.gd)
	# that listens to EventBus.mission_config_set and loads the Mode 1 scene.
