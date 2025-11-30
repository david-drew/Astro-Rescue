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

var stats:Dictionary = {}
var death_cause:String = ""
var death_reason:String = ""
var death_context:Dictionary = {}


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

	if not GameState:
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

	# TODO - these aren't fully used
	stats  = result.get("stats", {})
	death_cause  = stats.get("death_cause", "")
	death_reason = stats.get("death_reason", "")

	# Details (optional rich text)
	if details_label:
		var summary_text := ""
		if result.has("summary"):
			summary_text = result["summary"]
		elif death_reason != "":
			summary_text = death_reason
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

func get_human_readable_death_reason() -> String:
	match death_cause:
		"lander_crash_high_speed_impact":
			var speed: float = death_context.get("speed", death_context.get("impact_speed", 0.0))
			return "You impacted the surface at %0.1f m/s. The lander couldn’t survive that." % speed

		"lander_crash_hard_landing":
			var v_vert: float = death_context.get("vertical_speed", 0.0)
			var tilt: float = death_context.get("tilt_deg", 0.0)
			return "Your landing exceeded safe vertical speed (%.1f m/s) or tilt (%.1f°)." % [v_vert, tilt]

		_:
			return "The lander was destroyed."
