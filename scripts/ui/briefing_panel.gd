## res://scripts/modes/mode1/briefing_panel.gd
extends Control

##
# BriefingPanel (pre-mission)
#
# Responsibilities:
#   - Display the briefing for the current mission.
#   - On "Launch", emit an intent signal to Game.gd.
#
# Flow:
#   - Game.gd enters BRIEFING state and calls populate_from_gamestate()
#     (or legacy callers may still call show_briefing()).
#   - Player presses Launch.
#   - Panel emits EventBus.briefing_launch_requested.
#
# Notes:
#   - This panel is decoupled from MissionController.
#   - Mission config/result live in GameState.
##

@export var debug_logging: bool = false

# Optional UI nodes (safe lookups)
@onready var title_label: Label = get_node_or_null("VBoxContainer/TitleLabel")
@onready var description_label: Label = get_node_or_null("VBoxContainer/DescriptionLabel")
@onready var launch_button: Button = get_node_or_null("VBoxContainer/LaunchButton")

# Cached data for display/debug
var mission_id: String = ""
var mission_config: Dictionary = {}


func _ready() -> void:
	visible = false

	if launch_button != null:
		if not launch_button.pressed.is_connected(Callable(self, "_on_launch_pressed")):
			launch_button.pressed.connect(Callable(self, "_on_launch_pressed"))


# -------------------------------------------------------------------
# Public API (new)
# -------------------------------------------------------------------

func populate_from_gamestate() -> void:
	##
	# Preferred entrypoint.
	# Called by Game.gd when entering BRIEFING state.
	##

	if not Engine.has_singleton("GameState"):
		if debug_logging:
			print("[BriefingPanel] GameState not found; cannot populate.")
		visible = false
		return

	var cfg: Dictionary = GameState.current_mission_config
	if cfg.is_empty():
		if debug_logging:
			print("[BriefingPanel] No current_mission_config; hiding panel.")
		visible = false
		return

	_show_from_config(cfg)


# -------------------------------------------------------------------
# Public API (legacy / backward compatible)
# -------------------------------------------------------------------

func show_briefing(cfg: Dictionary, controller: Node) -> void:
	##
	# Legacy entrypoint used previously by MissionController.
	# We ignore 'controller' now to avoid flow coupling.
	##
	_show_from_config(cfg)


# -------------------------------------------------------------------
# Internal helpers
# -------------------------------------------------------------------

func _show_from_config(cfg: Dictionary) -> void:
	mission_config = cfg
	mission_id = cfg.get("id", "")

	var mission_name: String = cfg.get("display_name", "")
	if mission_name == "":
		mission_name = mission_id

	var description: String = ""
	if cfg.has("mission_brief"):
		description = str(cfg["mission_brief"])
	elif cfg.has("description"):
		description = str(cfg["description"])
	else:
		description = "Prepare for landing."

	if title_label != null:
		title_label.text = mission_name

	if description_label != null:
		description_label.text = description

	if debug_logging:
		print("[BriefingPanel] Briefing loaded for mission: ", mission_id)

	visible = true


# -------------------------------------------------------------------
# Button callback
# -------------------------------------------------------------------

func _on_launch_pressed() -> void:
	if debug_logging:
		print("[BriefingPanel] Launch pressed")

	visible = false

	# Intent-only signal; Game.gd handles the transition.
	EventBus.emit_signal("briefing_launch_requested")
