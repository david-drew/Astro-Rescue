extends Node2D

# Game.gd – top-level scene flow controller

enum GameMode {
	LAUNCH_MENU,
	HQ,
	BRIEFING,
	ORBITAL_VIEW,
	MISSION_RUNNING,
	DEBRIEF,
}

var _current_mode: GameMode = GameMode.LAUNCH_MENU

# If false, Orbital View is skipped (HQ -> Brief -> Mission).
@export var use_orbital_view: bool = false
@export var debug_logging: bool = false

# Node references
@onready var systems: Node            = $Systems
@onready var mission_controller: Node = $Systems/MissionController
@onready var world: Node2D            = $World
@onready var orbital_view: Node2D     = $OrbitalView
@onready var player: Player           = $World/Player

@onready var ui_root: CanvasLayer     = $UI
@onready var launch_menu: Control     = $UI/LaunchMenu
@onready var hq_panel: Control        = $UI/HQ
@onready var lander_hud: Control      = $UI/LanderHUD

# IMPORTANT: rename these NodePaths to your real nodes.
@onready var briefing_panel: Control  = $UI/BriefingPanel 
@onready var debrief_panel: Control   = $UI/DebriefPanel 


func _ready() -> void:
	_connect_eventbus()
	_enter_launch_menu()


# -------------------------------------------------------------------
# EventBus wiring
# -------------------------------------------------------------------

func _connect_eventbus() -> void:
	var eb = EventBus

	# Intent signals (from UI)
	if not eb.is_connected("new_game_requested", Callable(self, "_on_new_game_requested")):
		eb.connect("new_game_requested", Callable(self, "_on_new_game_requested"))

	if not eb.is_connected("start_mission_requested", Callable(self, "_on_start_mission_requested")):
		eb.connect("start_mission_requested", Callable(self, "_on_start_mission_requested"))

	# Briefing / Debrief intents (recommend defining these)
	if not eb.is_connected("briefing_launch_requested", Callable(self, "_on_briefing_launch_requested")):
		eb.connect("briefing_launch_requested", Callable(self, "_on_briefing_launch_requested"))

	if not eb.is_connected("debrief_return_requested", Callable(self, "_on_debrief_return_requested")):
		eb.connect("debrief_return_requested", Callable(self, "_on_debrief_return_requested"))

	# Mission lifecycle (from MissionController)
	if not eb.is_connected("mission_started", Callable(self, "_on_mission_started")):
		eb.connect("mission_started", Callable(self, "_on_mission_started"))

	if not eb.is_connected("mission_completed", Callable(self, "_on_mission_completed")):
		eb.connect("mission_completed", Callable(self, "_on_mission_completed"))

	if not eb.is_connected("mission_failed", Callable(self, "_on_mission_failed")):
		eb.connect("mission_failed", Callable(self, "_on_mission_failed"))

	# OrbitalView direct signals (from the node itself)
	# We only connect if the node exists.
	if orbital_view:
		if not orbital_view.is_connected("zone_selected", Callable(self, "_on_orbital_zone_selected")):
			orbital_view.connect("zone_selected", Callable(self, "_on_orbital_zone_selected"))

		if not orbital_view.is_connected("transition_started", Callable(self, "_on_orbital_transition_started")):
			orbital_view.connect("transition_started", Callable(self, "_on_orbital_transition_started"))

		if not orbital_view.is_connected("transition_completed", Callable(self, "_on_orbital_transition_completed")):
			orbital_view.connect("transition_completed", Callable(self, "_on_orbital_transition_completed"))


# -------------------------------------------------------------------
# State transitions (single source of truth)
# -------------------------------------------------------------------

func _set_mode(new_mode: GameMode) -> void:
	if _current_mode == new_mode:
		return

	_current_mode = new_mode

	if debug_logging:
		print("[Game] Mode -> ", new_mode)

	_apply_mode_visibility()
	_apply_mode_processing()


func _apply_mode_visibility() -> void:
	# Hide everything first, then enable exactly what we want.
	launch_menu.visible = false
	hq_panel.visible = false
	briefing_panel.visible = false
	if orbital_view:
		orbital_view.visible = false
	if lander_hud:
		lander_hud.visible = false
	debrief_panel.visible = false
	world.visible = false

	if _current_mode == GameMode.LAUNCH_MENU:
		if launch_menu:
			launch_menu.visible = true

	if _current_mode == GameMode.HQ:
		if hq_panel:
			hq_panel.visible = true

	if _current_mode == GameMode.BRIEFING:
		briefing_panel.visible = true
		briefing_panel.populate_from_gamestate()

	if _current_mode == GameMode.ORBITAL_VIEW:
		if orbital_view:
			orbital_view.visible = true

	if _current_mode == GameMode.MISSION_RUNNING:
		lander_hud.visible = true
		world.visible = true

	if lander_hud:
		lander_hud.visible = world.visible

	if _current_mode != GameMode.MISSION_RUNNING:
		if player:
			player.enter_hq()

	if _current_mode == GameMode.DEBRIEF:
		if debrief_panel:
			debrief_panel.visible = true

func _apply_mode_processing() -> void:
	# Disable world ticking unless a mission is running.
	if not world:
		return

	if _current_mode == GameMode.MISSION_RUNNING:
		world.process_mode = Node.PROCESS_MODE_INHERIT
		world.set_process(true)
		world.set_physics_process(true)
	else:
		world.process_mode = Node.PROCESS_MODE_DISABLED
		world.set_process(false)
		world.set_physics_process(false)

func _enter_launch_menu() -> void:
	_set_mode(GameMode.LAUNCH_MENU)

func _enter_hq() -> void:
	_set_mode(GameMode.HQ)

func _enter_briefing() -> void:
	_set_mode(GameMode.BRIEFING)

func _enter_orbital_view() -> void:
	_set_mode(GameMode.ORBITAL_VIEW)

func _enter_mission_running() -> void:
	_set_mode(GameMode.MISSION_RUNNING)

func _enter_debrief() -> void:
	_set_mode(GameMode.DEBRIEF)


# -------------------------------------------------------------------
# Intent handlers (UI -> Game)
# -------------------------------------------------------------------

func _on_new_game_requested() -> void:
	if debug_logging:
		print("[Game] new_game_requested")

	GameState.reset_profile()
	_enter_hq()


func _on_start_mission_requested(mission_id: String, mission_config: Dictionary) -> void:
	# HQ/MissionBoard intent to start a mission.
	if debug_logging:
		print("[Game] start_mission_requested: ", mission_id)

	# Store in GameState for MissionController to read.
	GameState.current_mission_id = mission_id
	GameState.current_mission_config = mission_config

	# Flow: HQ -> Briefing (always)
	_enter_briefing()


func _on_briefing_launch_requested() -> void:
	# Player clicked "Launch" in briefing.
	if debug_logging:
		print("[Game] briefing_launch_requested")

	var mc:Node = get_node_or_null("/root/Game/Systems/MissionController")
	mc.prepare_mission()

func _on_debrief_return_requested() -> void:
	# Player dismissed debrief.
	if debug_logging:
		print("[Game] debrief_return_requested")

	_enter_hq()


# -------------------------------------------------------------------
# Orbital View handlers
# -------------------------------------------------------------------

func _on_orbital_zone_selected(zone_id: String) -> void:
	# OrbitalView picked a landing zone.
	if debug_logging:
		print("[Game] orbital zone_selected: ", zone_id)

	# Store this in GameState so MissionController / TerrainGenerator can use it.
	GameState.landing_zone_id = zone_id


func _on_orbital_dialogue_completed() -> void:
	# If orbital view has optional dialogue gating.
	if debug_logging:
		print("[Game] orbital dialogue_completed")
	# No transition by default; zone selection or transition_completed drives mission start.


func _on_orbital_transition_started() -> void:
	if debug_logging:
		print("[Game] orbital transition_started")


func _on_orbital_transition_completed() -> void:
	if debug_logging:
		print("[Game] orbital transition_completed")

	_start_mission_from_brief_or_orbit()


func _start_mission_from_brief_or_orbit() -> void:
	# Shared start point after Brief or after OrbitalView.
	_enter_mission_running()
	mission_controller.prepare_mission()


# -------------------------------------------------------------------
# Mission lifecycle handlers (MissionController -> Game)
# -------------------------------------------------------------------

func _on_mission_started(mission_id:String="") -> void:
	if debug_logging:
		print("[Game] mission_started: ", mission_id)

	_enter_mission_running()

func _on_mission_completed(mission_id: String, result: Dictionary) -> void:
	if debug_logging:
		print("[Game] mission_completed: ", mission_id)

	# Flow: Mission -> Debrief
	_enter_debrief()


func _on_mission_failed(mission_id: String, reason: String, result: Dictionary) -> void:
	if debug_logging:
		print("[Game] mission_failed: ", mission_id, " reason=", reason)

	# Flow: Mission -> Debrief (fail variant)
	_enter_debrief()
