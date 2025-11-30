## res://scripts/systems/mission_controller.gd
extends Node
class_name MissionController

##
# MissionController (Mode 1 - Lander)
#
# Responsibilities:
#  - Read MissionConfig from GameState.current_mission_config
#  - Track mission state and elapsed time
#  - Track and evaluate objectives (primary + bonus)
#  - React to runtime events (touchdown, fuel changes, lander destroyed, player death)
#  - Decide mission outcome (success / partial / fail)
#  - Build a mission_result Dictionary and store it in GameState.current_mission_result
#  - Notify the rest of the game via EventBus.mission_completed / mission_failed
#
# It does NOT:
#  - Generate missions (MissionGenerator does that)
#  - Apply meta-progression (GameState.apply_mission_result should be called later,
#    usually from the Debrief screen)
##

var mc_phase: MissionPhases = MissionPhases.new()
var mc_goal: MissionObjectives = MissionObjectives.new()
var mc_landing: MissionLanding = MissionLanding.new()
var mc_setup: MissionSetup = MissionSetup.new()
var mc_orbit: MissionOrbitalFlow = MissionOrbitalFlow.new()
var mc_result: MissionResults = MissionResults.new()

var _death_cause: String = ""
var _death_context: Dictionary = {}

# -------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------

@export var debug: bool = true							# If true, prints debug info about objectives and mission state.
@export var auto_end_on_all_primary_complete: bool = true			# If true, mission auto-ends when all primary objectives are completed.

@export_category("Scene References")
@export var terrain_generator_path: NodePath
#@export var terrain_tiles_controller_path: NodePath 
@export var lander_path: NodePath
@export var hud_path: NodePath
@export var orbital_view_path: NodePath = NodePath("")  # NEW!

@export_category("Mission Data")
@export var mission_data_dir: String = "res://data/missions"
@export var mission_file_id: String = ""  # e.g. "training_mission_01" or "mission_01"
var _chosen_zone_id: String = ""
var _mission_begun: bool = false
var _mission_prepared: bool = false


# -------------------------------------------------------------------
# Internal state
# -------------------------------------------------------------------

var mission_config: Dictionary = {}
var _mission_id: String = ""
var _is_training: bool = false
var _tier: int = 0

var _mission_state: String = "not_started"  # "not_started", "running", "success", "partial", "fail"

var _failure_rules: Dictionary = {}
var _rewards: Dictionary = {}

var _mission_elapsed_time: float = 0.0
var _mission_time_limit: float = -1.0
var _mission_timer: Timer = null

var _current_fuel_ratio: float = 1.0
var _player_died: bool = false
var _lander_destroyed: bool = false
var _landing_successful: bool = false

var _orbit_reached: bool = false
var _orbit_reached_altitude: float = 0.0
var _orbit_reached_time: float = 0.0

var _terrain_generator: Node = null
#var _terrain_tiles_controller: TerrainTilesController = null
var _lander: RigidBody2D = null
var _hud: Node = null
var _orbital_view: OrbitalView = null  			# NEW!
var _using_orbital_view: bool = true  			# NEW!
var _orbital_transition_complete: bool = false  # NEW!
var _player: Player = null

var _current_poi_inside: String = ""


# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------

func _reset_mission_runtime_state() -> void:
	# Reset per-mission runtime state so we can safely start a new mission.
	_mission_prepared = false
	_mission_begun = false
	_mission_state = "not_started"		# TODO - these 2 vars look like dupes
	
	_chosen_zone_id = ""
	_mission_elapsed_time = 0.0

	_current_fuel_ratio = 1.0
	_player_died = false
	_lander_destroyed = false
	_landing_successful = false

	_orbit_reached = false
	_orbit_reached_altitude = 0.0
	_orbit_reached_time = 0.0

	_failure_rules.clear()
	_rewards.clear()

	# Clear any existing mission timer; _load_mission_config() will
	# compute a new time limit and recreate the timer as needed.
	if _mission_timer != null:
		if _mission_timer.is_inside_tree():
			_mission_timer.stop()
			_mission_timer.queue_free()
	_mission_timer = null
	_mission_time_limit = -1.0
	_player = null


func _ready() -> void:
	# Only connect signals and cache references here.
	# Actual mission startup is driven by begin_mission(), so we can
	# cleanly support multiple missions per session and an external
	# scene flow controller (Game.gd).
	_connect_eventbus_signals()
	mc_phase.init(self)
	mc_orbit.orbital_ready_to_land.connect(_on_orbital_ready_to_land)

	# Landing forgiveness
	mc_landing.landing_tolerance_mult = 1.4

	_terrain_generator = null

	if lander_path != NodePath(""):
		_lander = get_node_or_null(lander_path)
		

	if hud_path != NodePath(""):
		_hud = get_node_or_null(hud_path)

	# NEW: Cache orbital view reference
	if orbital_view_path != NodePath(""):
		_orbital_view = get_node_or_null(orbital_view_path) as OrbitalView
		if _orbital_view != null:
			mc_orbit.connect_orbital_view_signals()

	if debug:
		print("[MissionController] Ready. Waiting for begin_mission() call.")

func _process(delta: float) -> void:
	if _mission_state != "running":
		return

	_mission_elapsed_time += delta
	#mc_goal.previous_landing_site_valid = mc_landing.previous_landing_site_valid
	#mc_goal.previous_landing_site_pos = mc_landing.previous_landing_site_pos

	#mc_goal.tick_phase_objectives()
	#mc_phase.check_phase_completion_from_previous_landing_site()

	mc_setup.update_hud_timer(_mission_elapsed_time, _mission_time_limit)


# -------------------------------------------------------------------
# Config load
# -------------------------------------------------------------------

func _load_mission_config() -> void:
	# Load mission configuration using WorldSimManager as the resolver.
	if not GameState:
		push_warning("MissionController: GameState singleton not found; cannot load mission config.")
		return

	var WSM := WorldSimManager.new()

	mission_config.clear()

	var resolved_id: String = WSM.resolve_mission_id_for_launch()
	if resolved_id == "":
		push_warning("MissionController: No mission id resolved for launch.")
		return

	_mission_id = resolved_id

	var cfg: Dictionary = WSM.get_mission_config(_mission_id)
	if cfg.is_empty():
		push_warning("MissionController: No mission config found for mission_id=" + _mission_id)
		return

	mission_config = cfg.duplicate(true)
	GameState.current_mission_id = _mission_id
	GameState.current_mission_config = mission_config.duplicate(true)

	# Landing forgiveness multiplier (v1.4+). Defaults to 1.0.
	# Bigger = more tolerant of speed/impact.
	mc_landing.landing_tolerance_mult = float(mission_config.get("mission_modifiers", {}).get("landing_tolerance_mult", 1.0))
	if mc_landing.landing_tolerance_mult <= 0.0:
		mc_landing.landing_tolerance_mult = 1.4

	# IMPORTANT: is_training no longer exists. Training is derived from category.
	var cat: String = str(mission_config.get("category", "normal"))
	_is_training = (cat == "tutorial" or cat == "training")

	_tier = int(mission_config.get("tier", 0))

	_failure_rules = mission_config.get("failure_rules", {})
	_rewards = mission_config.get("rewards", {})
	
	print("[MC] Loaded mission_config.rewards for ", _mission_id, ": ", _rewards)	# TODO DELETE

	# -------------------------
	# v1.4 Phases + Objectives
	# -------------------------
	mc_phase.build_runtime_phases_from_config(mission_config)
	mc_phase.set_current_phase(0)
	#mc_goal.init_for_phase(mc_phase.current_phase, mission_config)
	mc_landing.arm_for_phase(mc_phase.current_phase)

	# Time limit
	_mission_time_limit = float(_failure_rules.get("time_limit_seconds", -1.0))
	# Apply sensible defaults if no explicit time limit was configured.
	# Training missions get a long window (e.g. 15 minutes) by default.
	# Non-training missions still get a generous default unless they specify tighter timing.
	if _mission_time_limit <= 0.0:
		if _is_training:
			_mission_time_limit = 900.0  # 15 minutes for training missions
		else:
			_mission_time_limit = 600.0  # 10 minutes default for regular missions

	_reset_mission_timer()


# -------------------------------------------------------------------
# Mission setup
# -------------------------------------------------------------------


func _setup_mission_timer() -> void:
	_reset_mission_timer()

func _reset_mission_timer() -> void:
	# Kill any existing timer safely.
	if _mission_timer != null:
		if _mission_timer.is_inside_tree():
			_mission_timer.stop()
		_mission_timer.queue_free()
	_mission_timer = null

	# Only create a timer if the mission actually has a time limit.
	if _mission_time_limit <= 0.0:
		if debug:
			print("[MissionController] No mission time limit; timer disabled.")
		return

	# Create the fresh timer.
	_mission_timer = Timer.new()
	_mission_timer.one_shot = true
	_mission_timer.autostart = false
	_mission_timer.wait_time = _mission_time_limit

	add_child(_mission_timer)
	_mission_timer.timeout.connect(_on_mission_timer_timeout)

	# Start it now that it's valid.
	_mission_timer.start()

	if debug:
		print("[MissionController] Mission timer started; limit=", _mission_time_limit, "s).")


# -------------------------------------------------------------------
# EventBus wiring
# -------------------------------------------------------------------

func _connect_eventbus_signals() -> void:
	var eb := EventBus

	if not eb.is_connected("touchdown", Callable(self, "_on_touchdown")):
		eb.connect("touchdown", Callable(self, "_on_touchdown"))

	if not eb.is_connected("lander_destroyed", Callable(self, "_on_lander_destroyed")):
		eb.connect("lander_destroyed", Callable(self, "_on_lander_destroyed"))

	if not eb.is_connected("fuel_changed", Callable(self, "_on_fuel_changed")):
		eb.connect("fuel_changed", Callable(self, "_on_fuel_changed"))

	if eb.has_signal("lander_altitude_changed") and not eb.is_connected("lander_altitude_changed", Callable(self, "_on_lander_altitude_changed")):
		eb.connect("lander_altitude_changed", Callable(self, "_on_lander_altitude_changed"))

	if not eb.is_connected("player_died", Callable(self, "_on_player_died")):
		eb.connect("player_died", Callable(self, "_on_player_died"))

	if not EventBus.is_connected("poi_entered", Callable(self, "_on_poi_entered")):
		EventBus.connect("poi_entered", Callable(self, "_on_poi_entered"))

	if not EventBus.is_connected("poi_exited", Callable(self, "_on_poi_exited")):
		EventBus.connect("poi_exited", Callable(self, "_on_poi_exited"))

	if not EventBus.is_connected("eva_interacted", Callable(self, "_on_eva_interacted")):
		EventBus.connect("eva_interacted", Callable(self, "_on_eva_interacted"))


	# You can connect to TimeManager's tick if desired.
	#var tm = TimeManager.new()
	if not eb.is_connected("time_tick", Callable(self, "_on_time_tick")):
		eb.connect("time_tick", Callable(self, "_on_time_tick"))
			
	eb.connect("lander_entered_landing_zone", Callable(self, "_on_landing"))		# Might want to remove this or "touchdown"


func _on_time_tick(channel_id: String, dt_game: float, _dt_real: float) -> void:
	if _mission_state != "running":
		return

	# Only care about the HUD-friendly tick cadence.
	if channel_id != "ui_hud":
		return

	_mission_elapsed_time += dt_game
	mc_setup.update_hud_timer(_mission_elapsed_time, _mission_time_limit)


# -------------------------------------------------------------------
# External calls from other scripts
# -------------------------------------------------------------------


func prepare_mission() -> void:
	##
	# Start (or restart) a mission using the current GameState state.
	# 1. Prepare Mission 			- we prep but don't fully start
	# 2. start_orbital_view() 		- select landing zone from orbit 
	#									- calls start_landing_gameplay() when done
	# 3. start_landing_gameplay()	- activate mission (mission is running)
	##
	if _mission_prepared:
		if debug:
			print("[MC] prepare_mission() ignored; already prepared.")
		return

	_reset_mission_runtime_state()
	print("[MC] prepare_mission() after _reset_mission_runtime_state")
	_load_mission_config()
	
	print("[MC] prepare_mission() after _load_mission_config, mission_config empty? ", mission_config.is_empty())


	# If config failed to load, abort gracefully.
	if mission_config.is_empty():
		if debug:
			print("[MissionController] prepare_mission() aborted: no mission_config loaded.")
		return

	print("\tprepare_mission: Check: 1")
	_chosen_zone_id = GameState.landing_zone_id

	# NEW: Check if mission uses orbital view
	var orbital_cfg: Dictionary = mission_config.get("orbital_view", {})
	_using_orbital_view = orbital_cfg.get("enabled", true)
	#_using_orbital_view = orbital_cfg.get("enabled", false)
	
	if debug:
		print("[MissionController] Mission prepped: ", _mission_id)
		print("[MissionController] Using orbital view: ", _using_orbital_view)
	
	# DON'T set mission_state or emit signal yet if using orbital view!
	# These will be set after the transition completes
	
	# Refresh scene references
	if terrain_generator_path != NodePath(""):
		_terrain_generator = get_node_or_null(terrain_generator_path) as Node
	
	if lander_path != NodePath(""):
		_lander = get_node_or_null(lander_path)
	
	if hud_path != NodePath(""):
		_hud = get_node_or_null(hud_path)
	
	if orbital_view_path != NodePath(""):
		_orbital_view = get_node_or_null(orbital_view_path) as OrbitalView

	prep_mc_setup(terrain_generator_path, lander_path, hud_path, 
		orbital_view_path, _terrain_generator, _lander, _hud, _orbital_view)

	# Generate terrain FIRST (needed for both paths)
	mc_setup.apply_mission_terrain(mission_config, debug)
	mc_setup.apply_mission_tiles(mission_config, debug)
	mc_setup.hide_landing_gameplay(debug)
	
	_mission_prepared = true

	EventBus.emit_signal("set_vehicle_mode", "lander")
	
	if _using_orbital_view and _orbital_view != null:
		mc_setup.hide_landing_gameplay(debug)

		# Provide terrain generator to orbital flow (now should be non-null)
		var tg := mc_setup.terrain_generator
		var ov := mc_setup.orbital_view
		if ov == null:
			ov = _orbital_view

		var spawn_alt := float(mission_config.get("spawn", {}).get("height_above_surface", 12000.0))
		if tg != null:
			tg.set_meta("spawn_altitude_fallback", spawn_alt)

		mc_orbit.start_orbital_flow(ov, tg, mission_config, debug)
	else:
		start_landing_gameplay()    # we shouldn't be here


func start_landing_gameplay() -> void:
	# Phase B: reveal terrain + spawn/position lander + activate camera.
	if not _mission_prepared:
		push_warning("[MC] Cannot start landing; mission not prepared.")
		return	

	if _mission_begun:
		if debug:
			print("[MC] start_landing_gameplay() ignored; already begun.")
		return

	mc_setup.show_landing_gameplay(mission_config, _chosen_zone_id, debug)

	# Ensure lander ref is current (Systems nodes can't trust _ready-time binding).
	mc_setup.refresh_scene_refs(get_tree().current_scene)

	mc_setup.set_player_vehicle_mode("lander")
	if _lander == null:
		push_warning("[MissionController] start_landing_gameplay(): lander is null.")
		return

	# Let the lander reset itself and apply loadout/mission config.
	if _lander.has_method("apply_mission_modifiers"):
		_lander.apply_mission_modifiers(mission_config)

	if _chosen_zone_id != "":
		mc_setup.position_lander_from_spawn(mission_config, _chosen_zone_id, debug)

	mc_setup.enable_gameplay_camera(debug)
	_mission_state = "running"
	
	EventBus.emit_signal("mission_started", _mission_id)
	
	_mission_begun = true

func prep_mc_setup(tgp:NodePath, lp:NodePath, hp:NodePath, ovp:NodePath, tg:Node, lnd:Node, hud:Node, ov:Node):
	# Sync MissionSetup with the live scene nodes and paths
	mc_setup.terrain_generator_path = tgp
	mc_setup.lander_path = lp
	mc_setup.hud_path = hp
	mc_setup.orbital_view_path = ovp

	# Also push the direct references in, so MissionSetup doesn't depend solely on paths
	mc_setup.terrain_generator = tg
	mc_setup.lander = lnd
	mc_setup.hud = hud
	mc_setup.orbital_view = ov

	# Make sure MissionSetup rebinds everything before terrain generation
	var scene_root := get_tree().current_scene
	if scene_root != null:
		mc_setup.refresh_scene_refs(scene_root)
	else:
		push_warning("[MC] prepare_mission(): current_scene is null during refresh_scene_refs")

func notify_orbit_reached(altitude: float) -> void:
	##
	# Call this from your LanderController / environment logic when
	# the lander has achieved a successful escape / orbit condition.
	##
	if _mission_state != "running":
		return

	_orbit_reached = true
	_orbit_reached_altitude = altitude
	_orbit_reached_time = _mission_elapsed_time

	if mc_goal != null:
		mc_goal.on_orbit_reached({"altitude": altitude})


func abort_mission(reason: String = "aborted") -> void:
	if _mission_state != "running":
		return

	if debug:
		print("[MissionController] Mission aborted: ", reason)

	_end_mission("fail", reason)


# -------------------------------------------------------------------
# Event handlers
# -------------------------------------------------------------------

func _on_landing(zone_id: String, zone_info: Dictionary) -> void:
	if debug:
		print("[MissionController] Fallback landing handler for zone_id=", zone_id)

	# Build a minimal touchdown-like payload for the objectives system.
	var touchdown_data: Dictionary = {
		"successful": false,              # We do not know; treat cautiously
		"impact_data": zone_info.duplicate(true)
	}

	_on_touchdown(touchdown_data)


func _on_touchdown(touchdown_data: Dictionary) -> void:
	if _mission_state != "running":
		return

	mc_landing.landing_successful = true 		# TODO: DEBUG may be hacky

	mc_landing.on_touchdown(
		touchdown_data,
		true,
		mc_phase.uses_v1_4_phases,
		mc_goal,
		mc_phase,
		debug,
		self
	)


# TODO: Use cause & context
func _on_lander_destroyed(cause:String, context:Dictionary) -> void:
	if _mission_state != "running":
		return

	_lander_destroyed = true

	if debug:
		print("[MissionController] Lander destroyed; mission failed.")

	_end_mission("fail", "lander_destroyed")


func _on_fuel_changed(current_ratio: float) -> void:
	if _mission_state != "running":
		return

	_current_fuel_ratio = clamp(current_ratio, 0.0, 1.0)

func _on_lander_altitude_changed(altitude_meters: float) -> void:
	if _mission_state != "running":
		return

	#print("ORBIT REACHED: ", _orbit_reached)
	#print("LANDNIG SUCCESS: ", mc_landing.landing_successful)

	# Only consider return-to-orbit after a successful landing.
	if _orbit_reached or not mc_landing.landing_successful:
		return

	var required_altitude: float = mc_goal.get_return_to_orbit_min_altitude()
	var req_altitude_meters = required_altitude / 3 - 500.0

	# TODO DELETE
	#print("\t...........................Now we want this altitude: ", req_altitude_meters, " vs ", altitude_meters)
	if altitude_meters >= req_altitude_meters:
		print("\t..............NOTIFY ORBIT REACHED")
		notify_orbit_reached(altitude_meters)
		if mc_landing.landing_successful and _orbit_reached:
			_end_mission("success", "landed_and_returned_to_orbit")

		#mc_goal.evaluate_return_to_orbit_objectives()


func _on_player_died(cause: String, context: Dictionary) -> void:
	if _mission_state != "running":
		return

	_player_died = true
	_death_cause = cause
	_death_context = context.duplicate(true)  # keep a copy for result/debrief

	if debug:
		print("[MissionController] Player died; mission failed. cause=", cause, " context=", context)

	# You can choose what to use as the 'reason' string:
	# - keep the old generic "player_died"
	# - or use the specific cause
	var reason := "player_died"
	if cause != "":
		reason = cause  # e.g. "lander_crash_high_speed_impact"

	_end_mission("fail", reason)



func _on_mission_timer_timeout() -> void:
	if _mission_state != "running":
		return

	if debug:
		print("[MissionController] Time limit exceeded (", _mission_time_limit, "s).")

	# Any remaining primary objectives are failed by time limit.
	mc_goal.force_fail_all_pending_primary("time_limit")
	_end_mission("fail", "time_limit_exceeded")



# -------------------------------------------------------------------
# Mission end and result building
# -------------------------------------------------------------------
func _end_mission(success_state: String, reason: String) -> void:
	if _mission_state != "running":
		return

	_mission_state = success_state

	if _mission_timer != null and _mission_timer.is_stopped() == false:
		_mission_timer.stop()

	_update_objectives_metrics()

	if mc_goal != null:
		mc_goal.finalize_for_mission_end()

	var summary := {}
	if mc_goal != null:
		summary = mc_goal.get_summary_state()
		if debug:
			print("[MissionController] Mission summary: ", summary)

	var primary := []
	var bonus := []
	if mc_goal != null:
		primary = mc_goal.get_primary_objectives()
		bonus = mc_goal.get_bonus_objectives()

	var stats := {
		"max_hull_damage_ratio": mc_landing.max_hull_damage_ratio,
		"crashes":               mc_landing.crashes_count,
		"player_died":           _player_died,
		"lander_destroyed":      _lander_destroyed,
		"orbit_reached":         _orbit_reached,
		"orbit_reached_altitude": _orbit_reached_altitude,
		"orbit_reached_time":     _orbit_reached_time,
		"death_cause":            _death_cause,
		"death_context":          _death_context,
	}

	var mission_result := mc_result.build(
		_mission_id,
		_is_training,
		_tier,
		success_state,
		reason,
		_mission_elapsed_time,
		_mission_time_limit,
		primary,
		bonus,
		stats,
		_rewards
	)

	GameState.current_mission_result = mission_result.duplicate(true)

	if success_state == "success" or success_state == "partial":
		EventBus.emit_signal("mission_completed", _mission_id, mission_result)
	else:
		EventBus.emit_signal("mission_failed", _mission_id, reason, mission_result)


# ==================================================================
# UPDATE: _show_landing_gameplay() in mission_controller.gd
# ==================================================================

func on_poi_entered(poi_id: String, poi_info: Dictionary) -> void:
	if _mission_state != "running":
		return

	mc_goal.on_poi_entered(poi_id)
	mc_phase.check_phase_completion_from_poi(poi_id)

func on_poi_exited(poi_id: String, poi_info: Dictionary) -> void:
	mc_goal.on_poi_exited(poi_id)

func on_eva_interacted(target_id: String) -> void:
	if _mission_state != "running":
		return

	mc_goal.on_eva_interacted(target_id)
	mc_phase.check_phase_completion_from_rescue(target_id)

func _on_orbital_ready_to_land(zone_id: String) -> void:
	_chosen_zone_id = zone_id
	start_landing_gameplay()

func _evaluate_end_condition_objectives() -> void:
	# Keep MissionObjectives in sync with the latest mission state
	# so "end-condition" primaries (time_under, fuel_remaining, no_damage)
	# can be evaluated before we decide success/fail.
	print("\t...................Eval End Condition.................")
	mc_goal.mission_elapsed_time = _mission_elapsed_time
	mc_goal.mission_time_limit = _mission_time_limit
	mc_goal.current_fuel_ratio = _current_fuel_ratio
	mc_goal.orbit_reached = _orbit_reached

	mc_goal.evaluate_time_under_objectives()
	mc_goal.evaluate_fuel_remaining_objectives()
	mc_goal.evaluate_no_damage_objectives()

func _update_objectives_metrics() -> void:
	if mc_goal == null:
		return

	var metrics := {
		"elapsed_time": _mission_elapsed_time,
		"time_limit": _mission_time_limit,
		"fuel_ratio": _current_fuel_ratio,
		"max_hull_damage_ratio": mc_landing.max_hull_damage_ratio,
		"crashes": mc_landing.crashes_count,
		"orbit_reached": _orbit_reached
	}
	mc_goal.set_metrics(metrics)

func reset():
	_mission_prepared = false
	_mission_begun    = false
	mission_config = {}
	_mission_id    = ""
	_death_cause   = ""
	_death_context = {}
	_mission_state = "not_started" 
	_orbit_reached = false
	
	_failure_rules  = {}
	_rewards        = {}

	_mission_elapsed_time   = 0.0
	_mission_time_limit     = -1.0
	_mission_timer          = null

	_current_fuel_ratio     = 1.0
	_player_died      		= false
	_lander_destroyed       = false
	_landing_successful     = false

	_orbit_reached          = false
	_orbit_reached_time     = 0.0
	_orbit_reached_altitude = 0.0

	# Make sure the landing helper's state doesn't leak between missions.
	if mc_landing != null:
		mc_landing.landing_successful = false
		mc_landing.crashes_count = 0
		mc_landing.max_hull_damage_ratio = 0.0

	# _rewards = {} 			# TODO: Rewards must be PROCESSED before reset
	
	#mc_phase.reset()
	mc_goal.reset()
	#mc_landing.reset()
	#mc_setup.reset()
	#mc_orbit.reset()
	#mc_result.reset()
	
	
