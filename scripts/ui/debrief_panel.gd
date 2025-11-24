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
#       - Emit a single intent signal to Game's state machine.
#
# Notes:
#   - This panel is now *decoupled* from HQController.
#   - Game.gd listens for "debrief_continue_requested".
##

@export var debug_logging: bool = false

# Optional UI nodes
@onready var mission_title_label: Label = $VBoxContainer/TitleLabel
@onready var outcome_label: Label = $VBoxContainer/OutcomeLabel
@onready var details_label: RichTextLabel = $VBoxContainer/DetailsRichText
@onready var return_button: Button = $VBoxContainer/ReturnButton

# Internal state
var mission_id: String = ""
var result: Dictionary = {}


func _ready() -> void:
	if return_button != null:
		if not return_button.pressed.is_connected(Callable(self, "_on_return_pressed")):
			return_button.pressed.connect(Callable(self, "_on_return_pressed"))


# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func populate_from_gamestate() -> void:
	##
	# Called by Game.gd when entering the DEBRIEF state.
	# Reads mission config + result from GameState and updates UI.
	##

	if not Engine.has_singleton("GameState"):
		if debug_logging:
			print("[DebriefPanel] GameState not found; cannot populate.")
		visible = false
		return

	var mission_cfg: Dictionary = GameState.current_mission_config
	result = GameState.current_mission_result

	if result.is_empty():
		if debug_logging:
			print("[DebriefPanel] No mission result; hiding panel.")
		visible = false
		return

	visible = true
	_update_ui_from_data(mission_cfg)


# -------------------------------------------------------------------
# Internal helpers
# -------------------------------------------------------------------

func _update_ui_from_data(mission_cfg: Dictionary) -> void:
	# Mission ID + display name
	mission_id = mission_cfg.get("id", "")
	var display_name: String = mission_cfg.get("display_name", "")
	if display_name == "":
		display_name = mission_id

	if mission_title_label:
		mission_title_label.text = display_name

	# Success/failure text
	var success_state: String = result.get("success_state", "unknown")

	if outcome_label:
		outcome_label.text = success_state.capitalize()

	# Details (optional rich text)
	if details_label:
		var summary_text := ""
		if result.has("summary"):
			summary_text = result["summary"]
		else:
			summary_text = "[i]No summary provided.[/i]"
		details_label.text = summary_text


# -------------------------------------------------------------------
# Button handler
# -------------------------------------------------------------------

func _on_return_pressed() -> void:
	# Notify Game.gd that player wants to leave the debrief.
	EventBus.emit_signal("debrief_return_requested")

	if debug_logging:
		print("[DebriefPanel] Continue pressed; debrief finished.")
