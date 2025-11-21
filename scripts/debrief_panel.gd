## res://scripts/modes/mode4/debrief_panel.gd
extends Control

##
# DebriefPanel
#
# Responsibilities:
#   - Display the outcome of the most recent mission using:
#       - GameState.current_mission_config
#       - GameState.current_mission_result
#   - On "Continue":
#       - Apply mission result via GameState.apply_mission_result()
#       - Notify HQController that debrief is done so it can:
#           * Start next training mission (if training not complete), OR
#           * Return to the mission board.
#
# Notes:
#   - This panel is owned by HQController.
#   - HQController calls populate_from_gamestate(self) when it wants to show it.
##

@export var debug_logging: bool = false

# Optional UI nodes – if they don't exist, we just skip updating them.
@onready var mission_title_label: Label      = %MissionTitleLabel if has_node("%MissionTitleLabel") else null
@onready var outcome_label: Label            = %OutcomeLabel if has_node("%OutcomeLabel") else null
@onready var details_label: RichTextLabel    = %DetailsRichText if has_node("%DetailsRichText") else null
@onready var continue_button: Button         = %ContinueButton if has_node("%ContinueButton") else null

# Reference back to HQController for flow control
var _hq_controller: Node = null


func _ready() -> void:
	# Ensure we have a handler for the Continue button, if it exists
	if continue_button != null and not continue_button.pressed.is_connected(Callable(self, "_on_continue_pressed")):
		continue_button.pressed.connect(Callable(self, "_on_continue_pressed"))


# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func populate_from_gamestate(hq_controller: Node) -> void:
	##
	# Called by HQController when this panel should be shown.
	# Reads mission config + result from GameState and updates UI.
	##
	_hq_controller = hq_controller

	if not Engine.has_singleton("GameState"):
		if debug_logging:
			print("[DebriefPanel] GameState not found; cannot populate.")
		return

	var mission_cfg: Dictionary = GameState.current_mission_config
	var result: Dictionary = GameState.current_mission_result

	if result.is_empty():
		if debug_logging:
			print("[DebriefPanel] No current_mission_result; hiding panel.")
		visible = false
		return

	visible = true

	_update_ui_from_data(mission_cfg, result)

# -------------------------------------------------------------------
# Internal helpers
# -------------------------------------------------------------------

func _update_ui_from_data(mission_cfg: Dictionary, result: Dictionary) -> void:
	var mission_id: String = mission_cfg.get("id", "")
	var display_name: String = mission_cfg.get("display_name", "")
	if display_name == "":
		display_name = mission_id

	var success_state: String = result.ge_
