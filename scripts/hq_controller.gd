## res://scripts/modes/mode4/hq_controller.gd
extends Control

##
# HQController
#
# Responsibilities (clean architecture version):
#   - Local UI controller for the HQ screen.
#   - Shows and hides HQ subpanels:
#         * MissionBoard
#         * CrewManager
#         * Store
#         * DebriefPanel (when Game enters DEBRIEF state)
#   - Emits intent signals for mission selection.
#   - Does NOT manage mission flow or training flow.
#   - Does NOT apply mission results.
#
# Scene flow is owned by Game.gd.
##

@export var debug_logging: bool = false

# Subpanels (safe to rename in scene)
@onready var mission_board_panel: Control = $MissionBoard
@onready var crew_manager_panel: Control = $CrewManager if has_node("CrewManager") else null
@onready var store_panel: Control = $Store if has_node("Store") else null

# Optional tabs/buttons (if your HQ UI uses tabs)
@onready var mission_tab_button: Button = get_node_or_null("Tabs/MissionTab")
@onready var crew_tab_button: Button    = get_node_or_null("Tabs/CrewTab")
@onready var store_tab_button: Button   = get_node_or_null("Tabs/StoreTab")

@onready var mission_button: Button = $ControlPanel/PanelBG/VBox/MissionButton
@onready var crew_button: Button    = $ControlPanel/PanelBG/VBox/CrewButton
@onready var store_button: Button   = $ControlPanel/PanelBG/VBox/StoreButton


'''
Crew Info to Track - Here or ...?
validate cost / stock
mutate GameState (money/rep)
add crew member / apply upgrade / add fuel
emit succeeded/failed
'''


func _ready() -> void:
	# Wire tab buttons (if present)
	if mission_tab_button and not mission_tab_button.pressed.is_connected(Callable(self, "_on_tab_mission")):
		mission_tab_button.pressed.connect(Callable(self, "_on_tab_mission"))

	if crew_tab_button and not crew_tab_button.pressed.is_connected(Callable(self, "_on_tab_crew")):
		crew_tab_button.pressed.connect(Callable(self, "_on_tab_crew"))

	if store_tab_button and not store_tab_button.pressed.is_connected(Callable(self, "_on_tab_store")):
		store_tab_button.pressed.connect(Callable(self, "_on_tab_store"))

	if mission_button != null:
		if not mission_button.pressed.is_connected(Callable(self, "_on_tab_mission")):
			mission_button.pressed.connect(Callable(self, "_on_tab_mission"))

	if crew_button != null:
		if not crew_button.pressed.is_connected(Callable(self, "_on_tab_crew")):
			crew_button.pressed.connect(Callable(self, "_on_tab_crew"))

	if store_button != null:
		if not store_button.pressed.is_connected(Callable(self, "_on_tab_store")):
			store_button.pressed.connect(Callable(self, "_on_tab_store"))

	var wsm:Node = WorldSimManager.new()
	wsm.refresh_board_missions_for_hq()
	$MissionBoard.refresh()

	# Default view: MissionBoard
	#_show_mission_board()

	# If DEBRIEF state entered, Game.gd will make this panel visible and call populate_from_gamestate()
	# HQController does NOT check mission_result anymore.


# -------------------------------------------------------------------
# Subpanel switching
# -------------------------------------------------------------------

func _hide_all() -> void:
	if mission_board_panel:
		mission_board_panel.visible = false
	if crew_manager_panel:
		crew_manager_panel.visible = false
	if store_panel:
		store_panel.visible = false


func _show_mission_board() -> void:
	if debug_logging:
		print("[HQ] Showing Mission Board")

	_hide_all()
	if mission_board_panel:
		mission_board_panel.visible = true
		if mission_board_panel.has_method("refresh"):
			mission_board_panel.refresh()


func _show_crew_manager() -> void:
	if debug_logging:
		print("[HQ] Showing Crew Manager")

	_hide_all()
	if crew_manager_panel:
		crew_manager_panel.visible = true
		if crew_manager_panel.has_method("refresh"):
			crew_manager_panel.refresh()


func _show_store() -> void:
	if debug_logging:
		print("[HQ] Showing Store")

	_hide_all()
	if store_panel:
		store_panel.visible = true
		if store_panel.has_method("refresh"):
			store_panel.refresh()


func _show_debrief() -> void:
	# Game.gd handles when this panel becomes visible.
	if debug_logging:
		print("[HQ] Showing Debrief Panel")

	_hide_all()


# -------------------------------------------------------------------
# Intent from Debrief (Game.gd will transition state)
# -------------------------------------------------------------------

func _on_debrief_continue_requested() -> void:
	if debug_logging:
		print("[HQ] Debrief dismissed → return to HQ panels")
	_show_mission_board()


# -------------------------------------------------------------------
# Tab callbacks (optional)
# -------------------------------------------------------------------

func _on_tab_mission() -> void:
	_show_mission_board()

func _on_tab_crew() -> void:
	_show_crew_manager()

func _on_tab_store() -> void:
	_show_store()


# -------------------------------------------------------------------
# MissionBoard → HQController intent
# -------------------------------------------------------------------
# MissionBoard can call this when a player selects a mission.

func start_mission_from_board(mission_id: String, mission_config: Dictionary) -> void:
	if debug_logging:
		print("[HQ] Mission selected from Board → emitting user intent")

	EventBus.emit_signal("start_mission_requested", mission_id, mission_config)
