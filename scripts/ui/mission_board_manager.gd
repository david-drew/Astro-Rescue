## res://scripts/modes/mode4/mission_board_manager.gd
extends Control

##
# MissionBoardManager (updated for new scene-machine architecture)
#
# Responsibilities:
#   - Display missions from GameState.available_missions.
#   - Create one button per mission.
#   - Emit intent signal when a mission is selected:
#         EventBus.emit_signal("start_mission_requested", mission_id, mission_cfg)
#   - Do NOT modify GameState internally.
#   - Do NOT trigger scene transitions directly.
#
# Notes:
#   - HQController receives the intent and manages local HQ behavior.
#   - Game.gd owns scene transitions (HQ → Briefing → Orbital → Mission).
##

@export var max_displayed_missions: int = 5
@export var debug_logging: bool = false

@onready var missions_container: Control = %MissionsContainer
@onready var title_label: Label = $Panel/VBoxContainer/TitleLabel
@onready var empty_label: Label = $Panel/EmptyLabel
@onready var close_btn:TextureButton = $CloseButton
@onready var submit_btn:Button  = $Panel/SubmitButton
@onready var vbox:VBoxContainer = $Panel/VBoxContainer

# Internal cache of missions shown
var _displayed_missions: Array = []    # Array[Dictionary]


func _ready() -> void:
	_refresh_from_gamestate()


# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func refresh() -> void:
	# Public entry point called by HQController when HQ becomes visible.
	_refresh_from_gamestate()

	# TODO
	print("[MissionBoard] available_missions size = ", GameState.available_missions.size(),	
	" training_complete=", GameState.training_complete, " training_progress=", GameState.training_progress)

# -------------------------------------------------------------------
# Internal helpers
# -------------------------------------------------------------------

func _refresh_from_gamestate() -> void:
	if missions_container == null:
		push_warning("MissionBoardManager: missions_container missing")
		return

	_clear_mission_list()
	_displayed_missions.clear()

	if not GameState:
		push_warning("MissionBoardManager: GameState missing")
		_show_empty_state(true)
		return

	var missions: Array = GameState.available_missions

	if missions.is_empty():
		if debug_logging:
			print("[MissionBoard] No missions available")
		_show_empty_state(true)
		return

	_show_empty_state(false)

	var count: int = missions.size()
	if count > max_displayed_missions:
		count = max_displayed_missions

	for i in range(count):
		var mission_cfg_raw = missions[i]
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
		empty_label.visible = show
		var current_color: Color = vbox.modulate
		current_color.a = 0.8
		vbox.modulate = current_color
		#vbox.visible = false

func _add_mission_button(queue_index: int, mission_cfg: Dictionary) -> void:
	var button := Button.new()

	var display_name: String = mission_cfg.get("display_name", "")
	if display_name == "":
		display_name = mission_cfg.get("id", "Unknown Mission")

	button.text = display_name

	# Tooltip info
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

	# Store mission index
	button.set_meta("mission_queue_index", queue_index)

	# Connect press event
	button.pressed.connect(Callable(self, "_on_mission_button_pressed").bind(button))

	missions_container.add_child(button)


# -------------------------------------------------------------------
# Event handlers
# -------------------------------------------------------------------

func _on_mission_button_pressed(button: Button) -> void:
	if button == null:
		return

	var queue_index_meta = button.get_meta("mission_queue_index")
	if queue_index_meta == null:
		push_warning("MissionBoardManager: missing mission index metadata")
		return

	var queue_index: int = int(queue_index_meta)
	var missions: Array = GameState.available_missions

	if queue_index < 0 or queue_index >= missions.size():
		push_warning("MissionBoardManager: index out of range: " + str(queue_index))
		return

	var mission_cfg_raw = missions[queue_index]
	if typeof(mission_cfg_raw) != TYPE_DICTIONARY:
		push_warning("MissionBoardManager: mission_cfg not a dictionary")
		return

	var mission_cfg: Dictionary = mission_cfg_raw
	var mission_id: String = mission_cfg.get("id", "")

	if debug_logging:
		print("[MissionBoard] Selected mission: ", mission_id)

	# Emit intent for Game.gd to handle briefing → orbital → mission.
	EventBus.emit_signal("start_mission_requested", mission_id, mission_cfg)
	GameState.current_mission_id = mission_id
	GameState.current_mission_config = mission_cfg


func _on_close_button_pressed() -> void:
	self.visible = false
