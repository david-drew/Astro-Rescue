## res://scripts/modes/mode1/pre_mission_panel.gd
extends Control

##
# PreMissionPanel
#
# Used by MissionController for the "orbit briefing" phase before gameplay begins.
# Behavior:
#   - MissionController calls show_briefing(mission_config, controller)
#   - The panel displays:
#        * Mission title
#        * Mission description (optional)
#        * Begin Mission button
#   - When the player presses the button:
#         * Calls controller.start_gameplay_after_briefing()
#         * Hides itself
#
# This panel does NOT drive mission flow—MissionController always owns the logic.
##

@export var debug_logging: bool = false

# Optional UI nodes if present in the scene.
# These names can be changed if needed — just update your scene to match.
@onready var title_label: Label = %TitleLabel if has_node("%TitleLabel") else null
@onready var description_label: Label = %DescriptionLabel if has_node("%DescriptionLabel") else null
@onready var begin_button: Button = %BeginButton if has_node("%BeginButton") else null

# MissionController reference (assigned when show_briefing() is called)
var _mission_controller: Node = null


func _ready() -> void:
	# Hide panel on startup
	visible = false

	# Wire up the Begin button
	if begin_button != null and not begin_button.pressed.is_connected(Callable(self, "_on_begin_pressed")):
		begin_button.pressed.connect(Callable(self, "_on_begin_pressed"))


# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func show_briefing(mission_config: Dictionary, controller: Node) -> void:
	##
	# Called by MissionController at the start of training missions.
	##
	_mission_controller = controller

	var mission_id:String = mission_config.get("id", "")
	var mission_name:String = mission_config.get("display_name", mission_id)
	var description := ""

	# Training missions often contain a text block or can have an optional note
	if mission_config.has("mission_brief"):
		description = str(mission_config["mission_brief"])
	elif mission_config.has("description"):
		description = str(mission_config["description"])
	else:
		description = "Prepare for landing."

	if title_label != null:
		title_label.text = mission_name

	if description_label != null:
		description_label.text = description

	if debug_logging:
		print("[PreMissionPanel] Briefing loaded for mission: ", mission_id)

	visible = true

# -------------------------------------------------------------------
# Button callback
# -------------------------------------------------------------------

func _on_begin_pressed() -> void:
	if debug_logging:
		print("[PreMissionPanel] Begin Mission pressed")

	visible = false

	if _mission_controller != null and _mission_controller.has_method("start_gameplay_after_briefing"):
		_mission_controller.start_gameplay_after_briefing()
	else:
		if debug_logging:
			print("[PreMissionPanel] MissionController missing start_gameplay_after_briefing()")
