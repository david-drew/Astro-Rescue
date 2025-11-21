## res://scripts/modes/mode4/hq_controller.gd
extends Control

##
# HQController
#
# Responsibilities:
#   - Entry point for the HQ (Home Base) scene.
#   - Shows either:
#       A) DebriefPanel (if GameState.current_mission_result exists), OR
#       B) MissionBoardPanel (normal HQ mode).
#   - Integrates with SceneManager for training / mission startup.
#
# Notes:
#   - DebriefPanel is hidden by default and shown only when needed.
#   - MissionBoardPanel is visible only when debrief is not active.
##

@export var debug_logging: bool = false

@onready var mission_board_panel: Control = $MissionBoard
@onready var debrief_panel: Control = $DebriefPanel

func _ready() -> void:
	if debug_logging:
		print("[HQ] _ready, checking for pending mission result")

	# Ensure visibility states are correct
	mission_board_panel.visible = false
	debrief_panel.visible = false

	# If there is a pending mission result, open Debrief first.
	if _has_pending_mission_result():
		_show_debrief()
	else:
		_show_mission_board()


# -------------------------------------------------------------------
# Visibility / Flow
# -------------------------------------------------------------------

func _show_mission_board() -> void:
	if debug_logging:
		print("[HQ] Showing mission board")

	debrief_panel.visible = false
	mission_board_panel.visible = true

	# Refresh mission board in case WorldSimManager updated it
	if mission_board_panel.has_method("refresh"):
		mission_board_panel.refresh()


func _show_debrief() -> void:
	if debug_logging:
		print("[HQ] Showing debrief")

	mission_board_panel.visible = false
	debrief_panel.visible = true

	if debrief_panel.has_method("populate_from_gamestate"):
		debrief_panel.populate_from_gamestate(self)


# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

func _has_pending_mission_result() -> bool:
	if not Engine.has_singleton("GameState"):
		return false

	var result = GameState.current_mission_result
	if typeof(result) == TYPE_DICTIONARY and not result.is_empty():
		return true

	return false


# -------------------------------------------------------------------
# Callbacks from DebriefPanel
# -------------------------------------------------------------------

func _on_debrief_continue() -> void:
	##
	# DebriefPanel calls this AFTER:
	#   - GameState.apply_mission_result()
	#   - mission_result_applied signal has fired (WorldSimManager updated training)
	##
	if debug_logging:
		print("[HQ] Debrief finished; deciding next step")

	# Clear previous mission result so next time we start fresh.
	GameState.current_mission_result = {}

	# If training is not complete, immediately start next training mission.
	if not GameState.training_complete:
		if debug_logging:
			print("[HQ] Training not complete → ask SceneManager to start next training mission")

		#if Engine.has_singleton("SceneManager"):
		#	SceneManager.start_training_mission()
		get_node("/root/Game").start_new_career()
		return

	# Otherwise: we stay in HQ and show the mission board.
	if debug_logging:
		print("[HQ] Training complete → return to mission board")

	_show_mission_board()
