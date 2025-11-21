extends Node2D

##
# Game.gd – top-level scene flow controller
#
# Modes:
#   LAUNCH_MENU  – initial main menu
#   HQ           – home base between missions
#   MODE1        – lander gameplay (MissionController runs here)
#
# It does NOT swap scenes. It uses the fixed node layout:
#
# Game (Node2D)
#   ├─ Systems (Node)
#   │    └─ MissionController, TerrainGenerator, etc.
#   ├─ World (Node2D)
#   │    ├─ StarfieldBG
#   │    ├─ TerrainRoot
#   │    └─ Lander (RigidBody2D)       [instanced in the scene]
#   └─ UI (CanvasLayer)
#        ├─ LaunchMenu (Control)
#        ├─ HQ (Control)
#        ├─ LanderHUD (Control)
#        └─ DialoguePanel (Control)
##

enum GameMode {
	LAUNCH_MENU,
	HQ,
	MODE1,
}

var _current_mode: GameMode = GameMode.LAUNCH_MENU

# Node references
@onready var systems: Node          = $Systems
@onready var mission_controller: Node = $Systems/MissionController
@onready var world: Node2D          = $World
@onready var lander: Node           = $World.get_node_or_null("Lander")

@onready var ui_root: CanvasLayer   = $UI
@onready var launch_menu: Control   = $UI/LaunchMenu
@onready var hq_panel: Control      = $UI/HQ
@onready var lander_hud: Control    = $UI/LanderHUD
@onready var dialogue_panel: Control = $UI/DialoguePanel if $UI.has_node("DialoguePanel") else null

@export var debug_logging: bool = false


func _ready() -> void:
	_connect_eventbus()
	_enter_launch_menu()


# -------------------------------------------------------------------
# EventBus wiring
# -------------------------------------------------------------------

func _connect_eventbus() -> void:
	if not Engine.has_singleton("EventBus"):
		push_warning("[Game] EventBus singleton not found; mission flow will not react to events.")
		return

	var eb = EventBus

	if not eb.is_connected("mission_config_set", Callable(self, "_on_mission_config_set")):
		eb.connect("mission_config_set", Callable(self, "_on_mission_config_set"))

	if not eb.is_connected("mission_completed", Callable(self, "_on_mission_completed")):
		eb.connect("mission_completed", Callable(self, "_on_mission_completed"))

	if not eb.is_connected("mission_failed", Callable(self, "_on_mission_failed")):
		eb.connect("mission_failed", Callable(self, "_on_mission_failed"))


# -------------------------------------------------------------------
# Mode entry helpers
# -------------------------------------------------------------------

func _enter_launch_menu() -> void:
	_current_mode = GameMode.LAUNCH_MENU

	if debug_logging:
		print("[Game] Entering LAUNCH_MENU")

	if launch_menu:
		launch_menu.visible = true
	if hq_panel:
		hq_panel.visible = false
	if lander_hud:
		lander_hud.visible = false

	# Optional: hide lander during menu
	if lander:
		lander.visible = false


func _enter_mode1() -> void:
	_current_mode = GameMode.MODE1

	if debug_logging:
		print("[Game] Entering MODE1 (lander mission)")

	if launch_menu:
		hq_panel.visible    = false
		lander_hud.visible  = false
		launch_menu.visible = true
	if hq_panel:
		launch_menu.visible = false
		lander_hud.visible  = false
		hq_panel.visible    = true
	if lander_hud:
		launch_menu.visible = false
		hq_panel.visible    = false
		lander_hud.visible  = true

	# Show lander during gameplay if it exists
	if lander:
		lander.visible = true


func _enter_hq() -> void:
	_current_mode = GameMode.HQ

	if debug_logging:
		print("[Game] Entering HQ")

	if launch_menu:
		launch_menu.visible = false
	if hq_panel:
		hq_panel.visible = true
	if lander_hud:
		lander_hud.visible = false

	# Optional: hide lander while in HQ
	if lander:
		lander.visible = false


# -------------------------------------------------------------------
# Public API for UI to call
# -------------------------------------------------------------------

func start_new_career() -> void:
	##
	# Called from LaunchMenu "New Game" button.
	# For now:
	#  - Reset profile via GameState.reset_profile()
	#  - Enter MODE1; MissionController	 will use training logic
	##
	if debug_logging:
		print("[Game] start_new_career() called")

	GameState.reset_profile()
	$Systems/MissionController.begin_mission()
	_enter_mode1()


func return_to_hq_after_mission() -> void:
	##
	# HQController / DebriefPanel can call this explicitly if needed.
	##
	_enter_hq()


# -------------------------------------------------------------------
# Event handlers – mission lifecycle
# -------------------------------------------------------------------

func _on_mission_config_set(mission_id: String, mission_config: Dictionary) -> void:
	##
	# Mission was selected from HQ's MissionBoard.
	# We just enter MODE1; MissionController is responsible for using
	# GameState.current_mission_config.
	##
	if debug_logging:
		print("[Game] mission_config_set → starting mission: ", mission_id)

	_enter_mode1()


func _on_mission_completed(mission_id: String, result: Dictionary) -> void:
	if debug_logging:
		print("[Game] mission_completed: ", mission_id)

	_enter_hq()


func _on_mission_failed(mission_id: String, reason: String, result: Dictionary) -> void:
	if debug_logging:
		print("[Game] mission_failed: ", mission_id, " reason=", reason)

	_enter_hq()
