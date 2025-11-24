## res://scripts/modes/mode1/mission_controller.gd
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

# -------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------

@export var debug_logging: bool = false							# If true, prints debug info about objectives and mission state.
@export var auto_end_on_all_primary_complete: bool = true			# If true, mission auto-ends when all primary objectives are completed.

@export_category("Scene References")
@export var terrain_generator_path: NodePath
@export var terrain_tiles_controller_path: NodePath 
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

var _mission_config: Dictionary = {}
var _mission_id: String = ""
var _is_training: bool = false
var _tier: int = 0

var _mission_state: String = "not_started"  # "not_started", "running", "success", "partial", "fail"

var _primary_objectives: Array = []  # Array[Dictionary] with runtime fields
var _bonus_objectives: Array = []    # Array[Dictionary] with runtime fields

var _failure_rules: Dictionary = {}
var _rewards: Dictionary = {}

var _mission_elapsed_time: float = 0.0
var _mission_time_limit: float = -1.0
var _mission_timer: Timer = null

var _current_fuel_ratio: float = 1.0
var _max_hull_damage_ratio: float = 0.0
var _crashes_count: int = 0
var _player_died: bool = false
var _lander_destroyed: bool = false
var _landing_successful: bool = false

# Touchdown gating / debounce
var _touchdown_armed: bool = false
var _touchdown_consumed_for_phase: bool = false
var _last_touchdown_ms: int = -999999

# Landing forgiveness
var _landing_tolerance_mult: float = 1.4


var _orbit_reached: bool = false
var _orbit_reached_altitude: float = 0.0
var _orbit_reached_time: float = 0.0

var _terrain_generator: Node = null
var _terrain_tiles_controller: TerrainTilesController = null
var _lander: RigidBody2D = null
var _hud: Node = null
var _orbital_view: OrbitalView = null  			# NEW!
var _using_orbital_view: bool = false  			# NEW!
var _orbital_transition_complete: bool = false  # NEW!

# --- v1.4 mission json phase runtime ---
var _phases: Array = []                 # raw phase dicts from mission json (or legacy-wrapped)
var _current_phase_index: int = -1
var _current_phase: Dictionary = {}

var _active_objectives: Array = []      # objectives for current phase (runtime-tracked)
var _active_bonus_objectives: Array = [] # optional; if you decide to support per-phase bonus later

# Legacy support flags
var _uses_v1_4_phases: bool = true


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
	_max_hull_damage_ratio = 0.0
	_crashes_count = 0
	_player_died = false
	_lander_destroyed = false
	_landing_successful = false

	_orbit_reached = false
	_orbit_reached_altitude = 0.0
	_orbit_reached_time = 0.0

	_primary_objectives.clear()
	_bonus_objectives.clear()
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


func _ready() -> void:
	# Only connect signals and cache references here.
	# Actual mission startup is driven by begin_mission(), so we can
	# cleanly support multiple missions per session and an external
	# scene flow controller (Game.gd).
	_connect_eventbus_signals()

	_terrain_generator = null

	if lander_path != NodePath(""):
		_lander = get_node_or_null(lander_path)

	if hud_path != NodePath(""):
		_hud = get_node_or_null(hud_path)

	# NEW: Cache orbital view reference
	if orbital_view_path != NodePath(""):
		_orbital_view = get_node_or_null(orbital_view_path) as OrbitalView
		if _orbital_view != null:
			_connect_orbital_view_signals()

	if debug_logging:
		print("[MissionController] Ready. Waiting for begin_mission() call.")

func _process(delta: float) -> void:
	if _mission_state != "running":
		return

	_mission_elapsed_time += delta
	_update_hud_timer()


# -------------------------------------------------------------------
# Config load
# -------------------------------------------------------------------

func _load_mission_config() -> void:
	# Load mission configuration.
	# Priority:
	#   1) Use GameState.current_mission_config if non-empty (e.g., set by MissionGenerator).
	#   2) Otherwise, if mission_file_id is set, load JSON from disk under mission_data_dir.

	if not GameState:
		push_warning("MissionController: GameState singleton not found; cannot load mission config.")
		return

	_mission_config = GameState.current_mission_config
	if _mission_config.is_empty():
		# 1) If mission_file_id is manually set (testing) → load JSON
		if mission_file_id != "":
			print("\tWARN trying to load mission file: ", mission_file_id)

			var loaded := _load_mission_config_from_json(mission_file_id)
			if not loaded.is_empty():
				_mission_config = loaded
				GameState.current_mission_config = loaded.duplicate(true)

		# 2) If empty AND using real game flow → ask WorldSimManager
		if _mission_config.is_empty():
			var ws = WorldSimManager.new()
			if ws != null and ws.has_method("get_next_training_mission_id"):
				var tid: String = ws.get_next_training_mission_id()
				if tid != "":
					print("\tWARN trying to load mission file backup: ", tid)
					var loaded2 := _load_mission_config_from_json(tid)
					if not loaded2.is_empty():
						_mission_config = loaded2
						GameState.current_mission_config = loaded2.duplicate(true)

	if _mission_config.is_empty():
		push_warning("MissionController: No mission config available (GameState empty and file load failed).")
		return

	_mission_id = _mission_config.get("id", "")

	# Landing forgiveness multiplier (v1.4+). Defaults to 1.0.
	# Bigger = more tolerant of speed/impact.
	_landing_tolerance_mult = float(_mission_config.get("mission_modifiers", {}).get("landing_tolerance_mult", 1.0))
	if _landing_tolerance_mult <= 0.0:
		_landing_tolerance_mult = 1.0

	# IMPORTANT: is_training no longer exists. Training is category == "tutorial".
	var cat: String = str(_mission_config.get("category", ""))
	_is_training = (cat == "tutorial")

	_tier = int(_mission_config.get("tier", 0))

	_failure_rules = _mission_config.get("failure_rules", {})
	_rewards = _mission_config.get("rewards", {})

	# -------------------------
	# v1.4 Phases + Objectives
	# -------------------------
	_build_runtime_phases_from_config()

	# Initialize runtime objectives for phase 0 (or legacy-wrapped phase)
	_set_current_phase(0)

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


func _build_runtime_phases_from_config() -> void:	
	_phases.clear()
	_uses_v1_4_phases = false

	var raw_phases: Array = _mission_config.get("phases", [])
	if raw_phases.size() > 0:
		# v1.4 mission
		_uses_v1_4_phases = true

		for p in raw_phases:
			if typeof(p) != TYPE_DICTIONARY:
				continue
			_phases.append(p.duplicate(true))

		return

	# -------------------------
	# Legacy fallback (pre-1.4)
	# Wrap top-level spawn/objectives into a single lander phase
	# -------------------------
	var legacy_spawn: Dictionary = _mission_config.get("spawn", {})
	var legacy_objectives: Dictionary = _mission_config.get("objectives", {})
	var legacy_primary: Array = legacy_objectives.get("primary", [])

	var legacy_phase: Dictionary = {
		"id": "legacy_descent",
		"mode": "lander",
		"spawn": legacy_spawn,
		"objectives": legacy_primary,
		"completion": {
			# Legacy missions end their only phase on landing.
			# Your existing touchdown handler + objectives should determine success.
			"type": "legacy"
		}
	}

	_phases.append(legacy_phase)


func _set_current_phase(index: int) -> void:
	if _phases.is_empty():
		push_warning("MissionController: No phases available after build.")
		_current_phase_index = -1
		_current_phase = {}
		_active_objectives.clear()
		_active_bonus_objectives.clear()
		return

	if index < 0 or index >= _phases.size():
		push_warning("MissionController: Phase index out of range: " + str(index))
		return

	_current_phase_index = index
	_current_phase = _phases[index]

	# Build runtime objectives for this phase.
	_active_objectives.clear()
	_active_bonus_objectives.clear()

	var objs: Array = _current_phase.get("objectives", [])
	for obj in objs:
		if typeof(obj) != TYPE_DICTIONARY:
			continue
		var runtime_obj: Dictionary = obj.duplicate(true)
		runtime_obj["status"] = "pending"  # "pending", "completed", "failed"
		runtime_obj["progress"] = {}
		_active_objectives.append(runtime_obj)

	# Legacy bonus objectives still exist at top level; keep them global for now.
	_bonus_objectives.clear()
	var legacy_obj_block: Dictionary = _mission_config.get("objectives", {})
	var legacy_bonus: Array = legacy_obj_block.get("bonus", [])
	for obj_b in legacy_bonus:
		if typeof(obj_b) != TYPE_DICTIONARY:
			continue
		var runtime_obj_b: Dictionary = obj_b.duplicate(true)
		runtime_obj_b["status"] = "pending"
		runtime_obj_b["progress"] = {}
		_bonus_objectives.append(runtime_obj_b)

	# Keep old arrays in sync so the rest of your controller doesn't explode.
	_primary_objectives = _active_objectives.duplicate(true)

	print("\t.............Current Phase Set..................") 		# TODO DELETE
	_arm_touchdown_for_current_phase()



func _load_mission_config_from_json(id_or_filename: String) -> Dictionary:
	##
	# Load a mission JSON from mission_data_dir.
	# id_or_filename:
	#   - "training_mission_01"  -> mission_data_dir + "/training_mission_01.json"
	#   - "mission_01.json"      -> mission_data_dir + "/mission_01.json"
	##
	var dir: String = mission_data_dir
	if not dir.ends_with("/"):
		dir += "/"

	var filename: String = id_or_filename
	if not filename.ends_with(".json"):
		filename += ".json"

	var full_path: String = dir + filename

	var file := FileAccess.open(full_path, FileAccess.READ)
	if file == null:
		push_warning("MissionController: Failed to open mission JSON: " + full_path)
		return {}

	var text := file.get_as_text()
	file.close()

	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("MissionController: Mission JSON is not a dictionary: " + full_path)
		return {}

	return data


# -------------------------------------------------------------------
# Mission setup
# -------------------------------------------------------------------

func _apply_mission_terrain() -> void:
	if _terrain_generator == null:
		if terrain_generator_path != NodePath(""):
			_terrain_generator = get_node_or_null(terrain_generator_path) as Node
	if _terrain_generator == null:
		return

	var terrain_config: Dictionary = _mission_config.get("terrain", {})
	if terrain_config.is_empty():
		return

	if debug_logging:
		print("[MissionController] Applying terrain config: ", terrain_config)

	_terrain_generator.generate_terrain(terrain_config)
	
	# Notify gravity/physics systems that terrain is ready.
	var gravity_mgr := get_node_or_null("../GravityFieldManager")
	if gravity_mgr != null and gravity_mgr.has_method("update_from_terrain"):
		gravity_mgr.update_from_terrain(_terrain_generator)

	# Optional global signal if other systems listen.
	EventBus.emit_signal("terrain_generated", _terrain_generator)

	# TODO DEBUG
	if _terrain_generator and _terrain_generator.has_method("get_landing_zone_ids"):
		var ids: Array = _terrain_generator.get_landing_zone_ids()
		print("[MissionController] Terrain zones now: ", ids)
	elif _terrain_generator and _terrain_generator.has_method("landing_zones"):
		print("[MissionController] Terrain zones dict keys: ", _terrain_generator.landing_zones.keys())


func _get_terrain_tiles_controller() -> TerrainTilesController:
	if _terrain_tiles_controller == null:
		if terrain_tiles_controller_path != NodePath(""):
			_terrain_tiles_controller = get_node_or_null(terrain_tiles_controller_path) as TerrainTilesController
	return _terrain_tiles_controller

func _apply_mission_tiles() -> void:
	var tiles_controller := _get_terrain_tiles_controller()
	if tiles_controller == null:
		return

	if _mission_config.is_empty():
		return

	tiles_controller.build_tiles_from_mission(_mission_config)


func _position_lander_from_spawn(zid:String="") -> void:
	if _lander == null:
		print("[MissionController] ERROR: No Lander, cannot set spawn point.")
		return

	# Bind or confirm terrain generator.
	if _terrain_generator == null and terrain_generator_path != NodePath(""):
		_terrain_generator = get_tree().current_scene.get_node_or_null(terrain_generator_path) as Node
	if _terrain_generator == null:
		push_warning("[MissionController] Cannot position lander; no TerrainGenerator available.")
		return

	# If a zone was selected via OrbitalView, use that first.
	if zid != "":
		var zone_info:Dictionary = _terrain_generator.get_landing_zone_world_info(zid)
		if zone_info != null:
			var default_spawn_height := 10000.0
			#landing_zone.spawn_position = Vector2( zone_center_x, surface_y - default_spawn_height )
			
			#var spawn_pos: Vector2 = zone_info.spawn_position		# hallucination, but we might want something like this later
			var spawn_pos:Vector2 = Vector2(500.0,-10000.0)
			
			# Safety: offset above terrain if provided
			if zone_info.has("spawn_offset"):
				spawn_pos.y -= float(zone_info.spawn_offset)

			# RigidBody2D-safe teleport
			if _lander is RigidBody2D:
				PhysicsServer2D.body_set_state(
					_lander.get_rid(),
					PhysicsServer2D.BODY_STATE_TRANSFORM,
					Transform2D.IDENTITY.translated(spawn_pos)
				)
			else:
				_lander.global_position = spawn_pos

			if debug_logging:
				print("[MissionController] Positioned lander at zone '%s' : %s" % [zid, str(spawn_pos)])

			return
		else:
			push_warning("[MissionController] Zone '%s' not found; falling back to mission default spawn." % zid)

	# Fallback: original fixed mission spawn config
	var spawn_cfg: Dictionary = _mission_config.get("spawn", {})
	if spawn_cfg.is_empty():
		print("[MissionController] WARN: Mission has no 'spawn' block; using current lander position.")
		return

	var spawn_pos: Vector2 = spawn_cfg.get("position", _lander.global_position)
	spawn_pos = Vector2(500.0,-10000.0)
	print("\tUsing backup spawn POS")

	if _lander is RigidBody2D:
		PhysicsServer2D.body_set_state(
			_lander.get_rid(),
			PhysicsServer2D.BODY_STATE_TRANSFORM,
			Transform2D.IDENTITY.translated(spawn_pos)
		)
	else:
		_lander.global_position = spawn_pos

	if debug_logging:
		print("[MissionController] Positioned lander from fixed mission spawn: ", spawn_pos)

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
		if debug_logging:
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

	if debug_logging:
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

	# You can connect to TimeManager's tick if desired.
	#var tm = TimeManager.new()
	if not eb.is_connected("time_tick", Callable(self, "_on_time_tick")):
		eb.connect("time_tick", Callable(self, "_on_time_tick"))
			
	EventBus.connect("lander_entered_landing_zone", Callable(self, "_on_landing"))		# Might want to remove this or "touchdown"


func _on_time_tick(channel_id: String, dt_game: float, _dt_real: float) -> void:
	if _mission_state != "running":
		return

	# Only care about the HUD-friendly tick cadence.
	if channel_id != "ui_hud":
		return

	_mission_elapsed_time += dt_game
	_update_hud_timer()


# -------------------------------------------------------------------
# External calls from other scripts
# -------------------------------------------------------------------

#func begin_mission() -> void:
func prepare_mission() -> void:
	##
	# Start (or restart) a mission using the current GameState state.
	# 1. Prepare Mission 			- we prep but don't fully start
	# 2. start_orbital_view() 		- select landing zone from orbit 
	#									- calls start_landing_gameplay() when done
	# 3. start_landing_gameplay()	- activate mission (mission is running)
	##
	if _mission_prepared:
		if debug_logging:
			print("[MC] prepare_mission() ignored; already prepared.")
		return
	
	_reset_mission_runtime_state()
	_load_mission_config()
	
	# If config failed to load, abort gracefully.
	if _mission_config.is_empty():
		if debug_logging:
			print("[MissionController] prepare_mission() aborted: no mission_config loaded.")
		return
	
	# NEW: Check if mission uses orbital view
	var orbital_cfg: Dictionary = _mission_config.get("orbital_view", {})
	_using_orbital_view = orbital_cfg.get("enabled", false)
	
	if debug_logging:
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
	
	# Generate terrain FIRST (needed for both paths)
	_apply_mission_terrain()
	_apply_mission_tiles()
	
	_hide_landing_gameplay()
	
	_mission_prepared = true
	
	# Branch based on orbital view usage
	# Start with OV = required to run OrbitalView
	if _using_orbital_view and _orbital_view != null:
		_start_with_orbital_view()
	else:
		start_landing_gameplay()

func start_landing_gameplay() -> void:
	# Phase B: reveal terrain + spawn/position lander + activate camera.
	if not _mission_prepared:
		push_warning("[MC] Cannot start landing; mission not prepared.")
		return	

	if _mission_begun:
		if debug_logging:
			print("[MC] start_landing_gameplay() ignored; already begun.")
		return

	_show_landing_gameplay()

	# Ensure lander ref is current (Systems nodes can't trust _ready-time binding).
	_bind_lander()
	if _lander == null:
		push_warning("[MissionController] start_landing_gameplay(): lander is null.")
		return

	# Let the lander reset itself and apply loadout/mission config.
	if _lander.has_method("apply_mission_modifiers"):
		_lander.apply_mission_modifiers(_mission_config)

	if _chosen_zone_id != "":
		_position_lander_from_spawn(_chosen_zone_id)

	_enable_gameplay_camera()
	_mission_state = "running"
	
	if EventBus.has_signal("mission_started"):
		EventBus.emit_signal("mission_started")
	
	_mission_begun = true

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

	if debug_logging:
		print("[MissionController] Orbit reached at altitude=", altitude, " time=", _orbit_reached_time)

	EventBus.emit_signal("orbit_reached")


func abort_mission(reason: String = "aborted") -> void:
	if _mission_state != "running":
		return

	if debug_logging:
		print("[MissionController] Mission aborted: ", reason)

	_end_mission("fail", reason)


# -------------------------------------------------------------------
# Event handlers
# -------------------------------------------------------------------
func _on_landing(zone_id:String, zone_info: Dictionary) -> void:
	print("TOUCHDOWN (landing)!!")
	_on_touchdown(zone_info)

func _on_touchdown(touchdown_data: Dictionary) -> void:
	if _mission_state != "running":
		return

	# Ignore touchdown if we aren't in a descent lander phase
	if _uses_v1_4_phases:
		if not _touchdown_armed:
			return
		if _touchdown_consumed_for_phase:
			return

		# Debounce rapid repeats (bounce/slide contacts)
		var now_ms: int = Time.get_ticks_msec()
		if now_ms - _last_touchdown_ms < 500:
			return
		_last_touchdown_ms = now_ms

	var success: bool = bool(touchdown_data.get("successful", touchdown_data.get("success", false)))
	var impact_data: Dictionary = touchdown_data.get("impact_data", touchdown_data)
	if impact_data.is_empty():
		return

	# Apply forgiveness: relax impact speed / success classification a bit.
	# If your touchdown sender includes an impact/velocity magnitude, scale it down for evaluation.
	# We do NOT lie to physics — only to objective evaluation and crash classification.
	var eval_impact_data: Dictionary = impact_data.duplicate(true)
	if eval_impact_data.has("impact_speed"):
		var spd: float = float(eval_impact_data.get("impact_speed", 0.0))
		eval_impact_data["impact_speed"] = spd / _landing_tolerance_mult
	if eval_impact_data.has("vertical_speed"):
		var vsp: float = float(eval_impact_data.get("vertical_speed", 0.0))
		eval_impact_data["vertical_speed"] = vsp / _landing_tolerance_mult
	if eval_impact_data.has("horizontal_speed"):
		var hsp: float = float(eval_impact_data.get("horizontal_speed", 0.0))
		eval_impact_data["horizontal_speed"] = hsp / _landing_tolerance_mult

	# If the sender gave a boolean success, and we scaled speeds,
	# we can optionally re-derive success if a speed threshold exists.
	# Otherwise leave success as-is.
	if eval_impact_data.has("max_safe_impact_speed"):
		var max_safe: float = float(eval_impact_data.get("max_safe_impact_speed", 30.0))
		var used_speed: float = float(eval_impact_data.get("impact_speed", 0.0))
		if max_safe > 0.0 and used_speed <= max_safe:
			success = true

	if debug_logging:
		print("[MissionController] Touchdown event received: success=", success, " impact_data=", impact_data, " tol_mult=", _landing_tolerance_mult)

	# Update crash / hull damage info
	var hull_damage_ratio: float = float(impact_data.get("hull_damage_ratio", 0.0))
	if hull_damage_ratio > _max_hull_damage_ratio:
		_max_hull_damage_ratio = hull_damage_ratio

	if not success:
		_crashes_count += 1
	else:
		_landing_successful = true

	# Always evaluate landing-related objectives on touchdown
	_evaluate_landing_objectives(eval_impact_data, success)
	_evaluate_precision_landing_objectives(eval_impact_data)
	_evaluate_landing_accuracy_objectives(eval_impact_data)

	# v1.4: see if this touchdown completes the current lander phase
	_check_phase_completion_from_touchdown(success, eval_impact_data)

	if _uses_v1_4_phases:
		# Consume touchdown for this descent phase so bounces can't re-trigger
		_touchdown_consumed_for_phase = true
	else:
		_check_for_mission_completion()


func _check_phase_completion_from_touchdown(success: bool, impact_data: Dictionary) -> void:
	print("\t..........Check Phase TDown Completion............")		# TODO DELETE
	
	if not _uses_v1_4_phases:
		return

	if _current_phase.is_empty():
		return

	var mode: String = str(_current_phase.get("mode", ""))
	if mode != "lander":
		return

	var comp: Dictionary = _current_phase.get("completion", {})
	var ctype: String = str(comp.get("type", ""))

	# Legacy-wrapped phases don't drive advancement here.
	if ctype == "" or ctype == "legacy":
		return

	# If touchdown wasn't successful, don't advance phases here.
	# Your existing objective/fail logic will handle mission failure.
	if not success:
		return

	# Try to read which zone we landed in (if TerrainGenerator provides it).
	var landed_zone_id: String = ""
	if impact_data.has("zone_id"):
		landed_zone_id = str(impact_data.get("zone_id", ""))
	elif impact_data.has("landing_zone_id"):
		landed_zone_id = str(impact_data.get("landing_zone_id", ""))

	var ok: bool = false

	if ctype == "landed_in_zone":
		var target_zone: String = str(comp.get("zone_id", ""))
		if target_zone == "any" or target_zone == "any_marked":
			ok = true
		elif landed_zone_id != "" and landed_zone_id == target_zone:
			ok = true

	# You can add more touchdown-driven completion types later if needed.

	if ok:
		if debug_logging:
			print("[MissionController] Phase complete on touchdown. Advancing from phase ", _current_phase_index)
		_advance_phase()


func _advance_phase() -> void:
	if _current_phase_index < 0:
		return

	var next_index: int = _current_phase_index + 1
	if next_index >= _phases.size():
		# No more phases; rely on existing mission completion path.
		_check_for_mission_completion()
		return

	_set_current_phase(next_index)

	# Enter next phase mode. Keep this minimal for now.
	_enter_current_phase()


func _enter_current_phase() -> void:
	if _current_phase.is_empty():
		return

	var mode: String = str(_current_phase.get("mode", ""))

	if debug_logging:
		print("[MissionController] Entering phase ", _current_phase_index, " mode=", mode, " id=", _current_phase.get("id", ""))

	# Lander phases after touchdown (e.g., ascent) don't need a scene swap.
	# Player is already in lander gameplay; objectives now guide takeoff.
	if mode == "lander":
		return

	# Buggy / EVA will be wired later.
	# We avoid calling missing methods to keep this patch safe.
	if mode == "buggy":
		print("\t................We want buggy phase.................") 	# TODO DELETE
		EventBus.emit_signal("phase_mode_requested", "buggy", _current_phase)
		return

	if mode == "rescue":
		print("\t................We want EVA phase.................") 		# TODO DELETE
		EventBus.emit_signal("phase_mode_requested", "rescue", _current_phase)
		return


# TODO: Use cause & context
func _on_lander_destroyed(cause:String, context:Dictionary) -> void:
	if _mission_state != "running":
		return

	_lander_destroyed = true

	if debug_logging:
		print("[MissionController] Lander destroyed; mission failed.")

	_end_mission("fail", "lander_destroyed")


func _on_fuel_changed(current_ratio: float) -> void:
		if _mission_state != "running":
				return

		_current_fuel_ratio = clamp(current_ratio, 0.0, 1.0)

func _on_lander_altitude_changed(altitude_meters: float) -> void:
		if _mission_state != "running":
				return

		# Only consider return-to-orbit after a successful landing.
		if _orbit_reached or not _landing_successful:
				return

		var required_altitude: float = _get_return_to_orbit_min_altitude()

		if altitude_meters >= required_altitude:
				notify_orbit_reached(altitude_meters)
				_evaluate_return_to_orbit_objectives()
				_check_for_mission_completion()


func _on_player_died() -> void:
	if _mission_state != "running":
		return

	_player_died = true

	if debug_logging:
		print("[MissionController] Player died; mission failed.")

	_end_mission("fail", "player_died")


func _on_mission_timer_timeout() -> void:
	if _mission_state != "running":
		return

	if debug_logging:
		print("[MissionController] Time limit exceeded (", _mission_time_limit, "s).")

	# Any remaining primary objectives are failed by time limit.
	_force_fail_all_pending_primary("time_limit")
	_end_mission("fail", "time_limit_exceeded")

# -------------------------------------------------------------------
# Objective evaluation
# -------------------------------------------------------------------

func _get_obj_param(obj: Dictionary, key: String, default_value):
		var params: Dictionary = obj.get("params", {})
		if params.has(key):
				return params.get(key, default_value)
		return obj.get(key, default_value)

func _get_return_to_orbit_min_altitude() -> float:
	var min_altitude: float = 0.0
	for obj in _primary_objectives:
		if obj.get("type", "") != "return_to_orbit":
			continue

		var candidate: float = float(_get_obj_param(obj, "min_altitude", 0.0))
		if candidate > 0.0 and (min_altitude <= 0.0 or candidate < min_altitude):
			min_altitude = candidate

		# If no explicit return-to-orbit altitude was set on objectives, fall back to the
		# mission's spawn height, which represents the orbital insertion altitude.
		if min_altitude <= 0.0:
			var spawn_cfg: Dictionary = _mission_config.get("spawn", {})
			var spawn_height: float = float(spawn_cfg.get("height_above_surface", 0.0))
			if spawn_height > 0.0:
				min_altitude = spawn_height

	# Final fallback: ensure orbit requires a meaningful climb.
	if min_altitude <= 0.0:
		min_altitude = 10000.0

	return min_altitude

func _evaluate_landing_objectives(impact_data: Dictionary, success: bool) -> void:
		for obj in _primary_objectives:
				if obj.get("type", "") != "landing":
						continue
				if obj.get("status", "pending") != "pending":
						continue

				if not success:
						continue

				var target_zone_id: String = _get_obj_param(obj, "target_zone_id", "")
				var landing_zone_id: String = impact_data.get("landing_zone_id", "")
				if target_zone_id != "" and target_zone_id != "any" and landing_zone_id != target_zone_id:
						continue

				var max_speed: float = float(_get_obj_param(obj, "max_impact_speed", 0.0))
				var impact_speed: float = float(impact_data.get("impact_speed", 0.0))
				if max_speed > 0.0 and impact_speed > max_speed:
						continue

				obj["status"] = "completed"
				_landing_successful = true
				if debug_logging:
						print("[MissionController] Objective completed: landing id=", obj.get("id", ""))

func _evaluate_precision_landing_objectives(impact_data: Dictionary) -> void:
	for obj in _primary_objectives:
		if obj.get("type", "") != "precision_landing":
			continue
		if obj.get("status", "pending") != "pending":
			continue

		var max_hull_damage: float = float(obj.get("max_hull_damage_ratio", 0.0))
		var hull_damage: float = float(impact_data.get("hull_damage_ratio", 0.0))

		if hull_damage <= max_hull_damage:
			obj["status"] = "completed"
			if debug_logging:
				print("[MissionController] Objective completed: precision_landing id=", obj.get("id", ""))


func _evaluate_landing_accuracy_objectives(impact_data: Dictionary) -> void:
	for obj in _primary_objectives:
		if obj.get("type", "") != "landing_accuracy":
			continue
		if obj.get("status", "pending") != "pending":
			continue

		var landing_zone_id: String = impact_data.get("landing_zone_id", "")
		var expected_zone_id: String = obj.get("landing_zone_id", "")

		if landing_zone_id != "" and landing_zone_id == expected_zone_id:
			obj["status"] = "completed"
			if debug_logging:
				print("[MissionController] Objective completed: landing_accuracy id=", obj.get("id", ""))


func _evaluate_return_to_orbit_objectives() -> void:
	for obj in _primary_objectives:
		if obj.get("type", "") != "return_to_orbit":
			continue
		if obj.get("status", "pending") != "pending":
			continue

		if _orbit_reached:
			obj["status"] = "completed"
			if debug_logging:
				print("[MissionController] Objective completed: return_to_orbit id=", obj.get("id", ""))


func _evaluate_time_under_objectives() -> void:
	for obj in _primary_objectives:
		if obj.get("type", "") != "time_under":
			continue
		if obj.get("status", "pending") != "pending":
			continue

		var limit: float = float(obj.get("time_limit_seconds", 0.0))
		if _mission_elapsed_time <= limit:
			obj["status"] = "completed"
			if debug_logging:
				print("[MissionController] Objective completed: time_under id=", obj.get("id", ""))


func _evaluate_fuel_remaining_objectives() -> void:
	for obj in _primary_objectives:
		if obj.get("type", "") != "fuel_remaining":
			continue
		if obj.get("status", "pending") != "pending":
			continue

		var min_ratio: float = float(obj.get("min_fuel_ratio", 0.0))
		if _current_fuel_ratio >= min_ratio:
			obj["status"] = "completed"
			if debug_logging:
				print("[MissionController] Objective completed: fuel_remaining id=", obj.get("id", ""))


func _evaluate_no_damage_objectives() -> void:
	for obj in _primary_objectives:
		if obj.get("type", "") != "no_damage":
			continue
		if obj.get("status", "pending") != "pending":
			continue

		if _max_hull_damage_ratio <= 0.0:
			obj["status"] = "completed"
			if debug_logging:
				print("[MissionController] Objective completed: no_damage id=", obj.get("id", ""))


func _force_fail_all_pending_primary(reason: String) -> void:
	for obj in _primary_objectives:
		if obj.get("status", "pending") == "pending":
			obj["status"] = "failed"
			if debug_logging:
				print("[MissionController] Primary objective failed by reason=", reason, " id=", obj.get("id", ""))


func _check_for_mission_completion() -> void:
	# Check if all primary objectives are completed.
	var any_pending_primary: bool = false
	var any_failed_primary: bool = false
	for obj in _primary_objectives:
		var status: String = obj.get("status", "pending")
		if status == "pending":
			any_pending_primary = true
		elif status == "failed":
			any_failed_primary = true

	if any_failed_primary:
		_end_mission("fail", "primary_objective_failed")
	elif not any_pending_primary and auto_end_on_all_primary_complete:
		_end_mission("success", "all_primary_completed")


# -------------------------------------------------------------------
# Mission end and result building
# -------------------------------------------------------------------

func _end_mission(success_state: String, reason: String) -> void:
	if _mission_state != "running":
		return

	_mission_state = success_state

	if _mission_timer != null and _mission_timer.is_stopped() == false:
		_mission_timer.stop()

	# Evaluate any objective types that depend on final state.
	_evaluate_return_to_orbit_objectives()
	_evaluate_time_under_objectives()
	_evaluate_fuel_remaining_objectives()
	_evaluate_no_damage_objectives()

	# Mark any remaining pending primary objectives as failed.
	var had_failed_primary_before: bool = false
	for obj in _primary_objectives:
		if obj.get("status", "pending") == "pending":
			obj["status"] = "failed"
		if obj.get("status", "pending") == "failed":
			had_failed_primary_before = true

	# If the mission was otherwise successful but some primaries failed here,
	# downgrade the mission state to "partial".
	if success_state == "success" and had_failed_primary_before:
		success_state = "partial"
		_mission_state = "partial"

	# Build final mission_result.
	var mission_result := _build_mission_result(success_state, reason)

	# Store in GameState so Debrief UI can read it.
	GameState.current_mission_result = mission_result.duplicate(true)

	# Broadcast via EventBus.
	if success_state == "success" or success_state == "partial":
		EventBus.emit_signal("mission_completed", _mission_id, mission_result)
	else:
		EventBus.emit_signal("mission_failed", _mission_id, reason, mission_result)

	if debug_logging:
		print("[MissionController] Mission ended: id=", _mission_id, " state=", success_state, " reason=", reason)
		print("[MissionController] Result: ", mission_result)


func _build_mission_result(success_state: String, reason: String) -> Dictionary:
	var primary_results: Array = []
	for obj in _primary_objectives:
		primary_results.append({
			"id": obj.get("id", ""),
			"type": obj.get("type", ""),
			"template_id": obj.get("template_id", ""),
			"status": obj.get("status", "pending"),
			"is_primary": true
		})

	var bonus_results: Array = []
	for obj_b in _bonus_objectives:
		bonus_results.append({
			"id": obj_b.get("id", ""),
			"type": obj_b.get("type", ""),
			"template_id": obj_b.get("template_id", ""),
			"status": obj_b.get("status", "pending"),
			"is_primary": false
		})

	var mission_result: Dictionary = {
		"mission_id": _mission_id,
		"is_training": _is_training,
		"tier": _tier,
		"success_state": success_state,
		"failure_reason": reason,
		"elapsed_time": _mission_elapsed_time,
		"time_limit": _mission_time_limit,
		"primary_objectives": primary_results,
		"bonus_objectives": bonus_results,
		"stats": {
			"max_hull_damage_ratio": _max_hull_damage_ratio,
			"crashes": _crashes_count,
			"player_died": _player_died,
			"lander_destroyed": _lander_destroyed,
			"orbit_reached": _orbit_reached,
			"orbit_reached_altitude": _orbit_reached_altitude,
			"orbit_reached_time": _orbit_reached_time
		},
		"rewards": _rewards
	}

	return mission_result


# -------------------------------------------------------------------
# HUD updates
# -------------------------------------------------------------------

func _apply_mission_setup() -> void:
	##
	# Apply all mission configuration.
	# NOTE: When using orbital view, only terrain is applied initially.
	# Lander positioning happens after transition.
	##
	
	# Terrain is always applied first
	if not _using_orbital_view:
		# Only apply full setup if not using orbital view
		_position_lander_from_spawn()
		_apply_mission_modifiers()
		_apply_mission_hud_config()
		
		#_apply_mission_terrain()
		#_apply_mission_tiles() 
		#_position_lander_from_spawn()
		#_apply_lander_loadout()
		#_apply_hud_instruments()
		#_update_hud_timer()


func _apply_lander_loadout() -> void:
	if _lander == null and lander_path != NodePath(""):
		_lander = get_node_or_null(lander_path)
	if _lander == null:
		return

	var loadout_config: Dictionary = _mission_config.get("lander_loadout", {})
	if loadout_config.is_empty():
		return

	if _lander.has_method("apply_mission_loadout"):
		_lander.call("apply_mission_loadout", loadout_config)
	else:
		if debug_logging:
			print("[MissionController] Lander does not implement apply_mission_loadout")


func _apply_hud_instruments() -> void:
	if _hud == null and hud_path != NodePath(""):
		_hud = get_node_or_null(hud_path)
	if _hud == null:
		return

	var hud_config: Dictionary = _mission_config.get("hud", {})
	if hud_config.is_empty():
		return

	if _hud.has_method("apply_mission_hud_config"):
		_hud.call("apply_mission_hud_config", hud_config)
	else:
		if debug_logging:
			print("[MissionController] HUD does not implement apply_mission_hud_config")

func _apply_mission_modifiers() -> void:
	##
	# Apply mission modifiers to the lander (fuel, thrust, rotation, etc.)
	##
	if _lander == null:
		if debug_logging:
			print("[MissionController] Cannot apply modifiers: no lander reference")
		return
	
	var modifiers: Dictionary = _mission_config.get("mission_modifiers", {})
	if modifiers.is_empty():
		if debug_logging:
			print("[MissionController] No mission modifiers to apply")
		return
	
	if debug_logging:
		print("[MissionController] Applying mission modifiers: ", modifiers)
	
	# Fuel capacity multiplier
	
	if "fuel_capacity_multiplier" in modifiers:
		var multiplier := float(modifiers.get("fuel_capacity_multiplier", 1.0))
		if "fuel_capacity" in _lander:
			var base_fuel: float = _lander.get("fuel_capacity")
			_lander.set("fuel_capacity", base_fuel * multiplier)
			if debug_logging:
				print("[MissionController] Fuel capacity: ", base_fuel, " -> ", base_fuel * multiplier)
	
	# Thrust multiplier
	if "thrust_multiplier" in modifiers:
		var multiplier := float(modifiers.get("thrust_multiplier", 1.0))
		if "base_thrust_force" in _lander:
			var base_thrust: float = _lander.get("base_thrust_force")
			_lander.set("base_thrust_force", base_thrust * multiplier)
			if debug_logging:
				print("[MissionController] Thrust: ", base_thrust, " -> ", base_thrust * multiplier)
	
	# Rotation acceleration multiplier
	if "rotation_accel_multiplier" in modifiers:
		var multiplier := float(modifiers.get("rotation_accel_multiplier", 1.0))
		if "rotation_accel" in _lander:
			var base_rotation: float = _lander.get("rotation_accel")
			_lander.set("rotation_accel", base_rotation * multiplier)
			if debug_logging:
				print("[MissionController] Rotation accel: ", base_rotation, " -> ", base_rotation * multiplier)
	
	# Max angular speed multiplier
	if "max_angular_speed_multiplier" in modifiers:
		var multiplier := float(modifiers.get("max_angular_speed_multiplier", 1.0))
		if "max_angular_speed" in _lander:
			var base_speed: float = _lander.get("max_angular_speed")
			_lander.set("max_angular_speed", base_speed * multiplier)
			if debug_logging:
				print("[MissionController] Max angular speed: ", base_speed, " -> ", base_speed * multiplier)
	
	# Starting fuel ratio
	if "start_fuel_ratio" in modifiers:
		var ratio := float(modifiers.get("start_fuel_ratio", 1.0))
		if _lander.has_method("set_fuel_ratio"):
			_lander.call("set_fuel_ratio", ratio)
			if debug_logging:
				print("[MissionController] Starting fuel ratio: ", ratio)
				
		elif "_current_fuel" in _lander and "fuel_capacity" in _lander:
			var capacity: float = _lander.get("fuel_capacity")
			_lander.set("_current_fuel", capacity * ratio)
			if debug_logging:
				print("[MissionController] Starting fuel: ", capacity * ratio)


func _apply_mission_hud_config() -> void:
	##
	# Configure HUD visibility based on mission settings
	##
	if _hud == null:
		if debug_logging:
			print("[MissionController] Cannot apply HUD config: no HUD reference")
		return
	
	var hud_config: Dictionary = _mission_config.get("hud_instruments", {})
	if hud_config.is_empty():
		if debug_logging:
			print("[MissionController] No HUD config to apply")
		return
	
	if debug_logging:
		print("[MissionController] Applying HUD config: ", hud_config)
	
	# Check if player can override HUD settings
	var allow_override := bool(hud_config.get("allow_player_override", true))
	
	# Apply each HUD setting if the HUD has the corresponding method/property
	if hud_config.has("show_altitude"):
		var show := bool(hud_config.get("show_altitude", true))
		if _hud.has_method("set_altitude_visible"):
			_hud.call("set_altitude_visible", show)
		elif "show_altitude" in _hud:
			_hud.set("show_altitude", show)
		if debug_logging:
			print("[MissionController] HUD altitude: ", show)
	
	if hud_config.has("show_fuel"):
		var show := bool(hud_config.get("show_fuel", true))
		if _hud.has_method("set_fuel_visible"):
			_hud.call("set_fuel_visible", show)
		elif "show_fuel" in _hud:
			_hud.set("show_fuel", show)
		if debug_logging:
			print("[MissionController] HUD fuel: ", show)
	
	if hud_config.has("show_wind"):
		var show := bool(hud_config.get("show_wind", false))
		if _hud.has_method("set_wind_visible"):
			_hud.call("set_wind_visible", show)
		elif "show_wind" in _hud:
			_hud.set("show_wind", show)
		if debug_logging:
			print("[MissionController] HUD wind: ", show)
	
	if hud_config.has("show_gravity"):
		var show := bool(hud_config.get("show_gravity", true))
		if _hud.has_method("set_gravity_visible"):
			_hud.call("set_gravity_visible", show)
		elif "show_gravity" in _hud:
			_hud.set("show_gravity", show)
		if debug_logging:
			print("[MissionController] HUD gravity: ", show)
	
	if hud_config.has("show_timer"):
		var show := bool(hud_config.get("show_timer", true))
		if _hud.has_method("set_timer_visible"):
			_hud.call("set_timer_visible", show)
		elif "show_timer" in _hud:
			_hud.set("show_timer", show)
		if debug_logging:
			print("[MissionController] HUD timer: ", show)
	
	# Store override permission if HUD supports it
	if "allow_player_override" in _hud:
		_hud.set("allow_player_override", allow_override)

func _update_hud_timer() -> void:
	if _hud == null and hud_path != NodePath(""):
		_hud = get_node_or_null(hud_path)
	if _hud == null:
		return

	if not _hud.has_method("update_mission_timer"):
		return

	var remaining: float = _mission_time_limit
	if _mission_time_limit > 0.0:
		remaining = max(0.0, _mission_time_limit - _mission_elapsed_time)

	_hud.call("update_mission_timer", _mission_elapsed_time, remaining)


func _connect_orbital_view_signals() -> void:
	if _orbital_view == null:
		return
	
	if not _orbital_view.is_connected("zone_selected", Callable(self, "_on_orbital_zone_selected")):
		_orbital_view.connect("zone_selected", Callable(self, "_on_orbital_zone_selected"))
	
	if not _orbital_view.is_connected("transition_started", Callable(self, "_on_orbital_transition_started")):
		_orbital_view.connect("transition_started", Callable(self, "_on_orbital_transition_started"))
	
	if not _orbital_view.is_connected("transition_completed", Callable(self, "_on_orbital_transition_completed")):
		_orbital_view.connect("transition_completed", Callable(self, "_on_orbital_transition_completed"))
	
	if debug_logging:
		print("[MissionController] OrbitalView signals connected")

func _on_orbital_transition_started() -> void:
	##
	# Called when camera transition begins
	# Pass the target world position to orbital view
	##
	if debug_logging:
		print("[MissionController] Orbital transition started")
	
	# Get target position we stored earlier
	var target_pos: Vector2 = get_meta("transition_target_position", Vector2.ZERO)
	
	if target_pos == Vector2.ZERO:
		push_warning("[MissionController] No target position stored for transition!")
		# Fallback
		if _terrain_generator != null:
			var center_x:float  = _terrain_generator.get_center_x()
			var surface_y:float = _terrain_generator.get_highest_point_y()
			target_pos = Vector2(center_x, surface_y - 12000.0)
	
	# Tell orbital view to zoom to this position
	if _orbital_view != null and _orbital_view.has_method("begin_zoom_to_position"):
		_orbital_view.begin_zoom_to_position(target_pos)
		
		if debug_logging:
			print("[MissionController] Camera zooming to: ", target_pos)


# ==================================================================
# STEP 5: Add Signal Handlers for OrbitalView
# ==================================================================

func _on_orbital_zone_selected(zone_id: String) -> void:
	if debug_logging:
		print("[MissionController] Orbital zone selected: ", zone_id)

	# If begin_mission still couldn't load config, bail.
	if _mission_config.is_empty():
		push_warning("[MissionController] Cannot proceed from orbital selection; mission_config empty.")
		return

	if _terrain_generator == null and terrain_generator_path != NodePath(""):
		_terrain_generator = get_node_or_null(terrain_generator_path) as Node

	# Store selected zone for spawn positioning
	if not _mission_config.has("spawn"):
		_mission_config["spawn"] = {}
	_mission_config["spawn"]["start_above_zone_id"] = zone_id
	
	# Get the actual world position of this landing zone
	var target_position := Vector2.ZERO
	
	if _terrain_generator != null:
		# Get landing zone info from terrain generator
		var zone_info: Dictionary = _terrain_generator.get_landing_zone_world_info(zone_id)
		_chosen_zone_id = zone_id

		if not zone_info.is_empty():
			var center_x: float = float(zone_info.get("center_x", 0.0))
			var surface_y: float = float(zone_info.get("surface_y", 600.0))
			
			# Position camera high above the zone for landing
			var spawn_altitude: float = float(_mission_config.get("spawn", {}).get("height_above_surface", 12000.0))
			target_position = Vector2(center_x, surface_y - spawn_altitude)
			
			if debug_logging:
				print("[MissionController] Landing zone world position: ", target_position)
		else:
			push_warning("[MissionController] Could not find landing zone info for: ", zone_id)
			# Fallback to terrain center
			var center_x:float  = _terrain_generator.get_center_x()
			var surface_y:float = _terrain_generator.get_highest_point_y()
			target_position = Vector2(center_x, surface_y - 12000.0)
	
	# Store target position for camera transition
	set_meta("transition_target_position", target_position)

func _on_orbital_transition_completed() -> void:
	if debug_logging:
		print("[MissionController] Orbital transition completed")
	
	_orbital_transition_complete = true
	start_landing_gameplay()
	
	# Hide orbital view (disables orbital camera)
	if _orbital_view != null:
		_orbital_view.hide_orbital_view()
	
	# Enable gameplay camera
	_enable_gameplay_camera()
	
	# Show world/lander
	_show_landing_gameplay()
	
	# NOW start the mission and emit signal
	_mission_state = "running"
	
	print("\t\t.......MISSION STARTED.................")
	EventBus.emit_signal("mission_started", _mission_id)

func _enable_gameplay_camera() -> void:
	##
	# Enable the gameplay camera (usually attached to lander or separate)
	##
	# Camera on lander
	if _lander != null and _lander.has_node("Camera2D"):
		var cam := _lander.get_node("Camera2D") as Camera2D
		if cam != null:
			cam.enabled = true
			if debug_logging:
				print("[MissionController] Lander camera enabled")


func _start_with_orbital_view() -> void:
	##
	# Start mission with orbital view sequence
	##
	if debug_logging:
		print("[MissionController] Starting with orbital view...")
	
	# Hide world BEFORE showing orbital view
	_hide_landing_gameplay()
	
	# Setup orbital view
	var orbital_cfg: Dictionary = _mission_config.get("orbital_view", {})
	_orbital_view.initialize(orbital_cfg)
	_orbital_view.show_orbital_view()
	
	# Don't start mission or emit signal yet - wait for transition
	_mission_state = "not_started"
	
	if debug_logging:
		print("[MissionController] Orbital view active, waiting for zone selection")

func _start_without_orbital_view() -> void:
	##
	# Start mission immediately (old behavior)
	##
	if debug_logging:
		print("[MissionController] Starting without orbital view (direct landing)")
	
	# Show world
	_show_landing_gameplay()
	
	# NOW set state and emit signal
	_mission_state = "running"
	
	EventBus.emit_signal("mission_started", _mission_id)


func _hide_landing_gameplay() -> void:
	##
	# Hide World node and Lander for orbital view
	##

	# Ensure we are bound to the real generator/tiles before hiding.
	if terrain_generator_path != NodePath(""):
		_terrain_generator = get_node_or_null(terrain_generator_path) as Node
	if terrain_tiles_controller_path != NodePath(""):
		_terrain_tiles_controller = get_node_or_null(terrain_tiles_controller_path)

	var world_node := get_node_or_null("/root/Game/World")
	if world_node != null:
		world_node.visible = false
		if debug_logging:
			print("[MissionController] World node hidden")
	
	# IMPORTANT: Freeze and hide the gameplay lander (RigidBody2D)
	if _lander != null:
		_lander.visible = false
		
		# Freeze physics so it doesn't fall during orbital view
		if _lander is RigidBody2D:
			_lander.freeze = true
			if debug_logging:
				print("[MissionController] Lander frozen (physics disabled)")
		
		if debug_logging:
			print("[MissionController] Lander hidden")
	
	# Hide terrain
	if _terrain_generator != null:
		var terrain_body:StaticBody2D = _terrain_generator.get_terrain_body()
		if terrain_body != null:
			terrain_body.visible = false
	
	# Hide terrain tiles
	if _terrain_tiles_controller != null:
		if _terrain_tiles_controller.has_method("hide_tiles"):
			_terrain_tiles_controller.hide_tiles()
	
	if debug_logging:
		print("[MissionController] Landing gameplay hidden")


# ==================================================================
# UPDATE: _show_landing_gameplay() in mission_controller.gd
# ==================================================================

func _show_landing_gameplay() -> void:
	##
	# Show World node and Lander after orbital transition
	##
	var world_node := get_node_or_null("/root/Game/World")
	if world_node != null:
		world_node.visible = true
		if debug_logging:
			print("[MissionController] World node shown")
	
	var _lander:RigidBody2D = get_node_or_null("/root/Game/World/Lander")
	
	# Show terrain
	if _terrain_generator != null:
		var terrain_body:StaticBody2D = _terrain_generator.get_terrain_body()
		if terrain_body != null:
			terrain_body.visible = true
	
	# Show terrain tiles
	if _terrain_tiles_controller != null:
		if _terrain_tiles_controller.has_method("show_tiles"):
			_terrain_tiles_controller.show_tiles()
	
	# Position lander FIRST (while still frozen)
	_position_lander_from_spawn()
	
	# IMPORTANT: Show and unfreeze the gameplay lander
	if _lander != null:
		_lander.visible = true
		
		# Unfreeze physics so gameplay can begin
		if _lander is RigidBody2D:
			_lander.freeze = false
			
			# Reset velocities to ensure clean start
			_lander.linear_velocity = Vector2.ZERO
			_lander.angular_velocity = 0.0
			
			if debug_logging:
				print("[MissionController] Lander unfrozen (physics enabled)")
		
		if debug_logging:
			print("[MissionController] Lander shown at position: ", _lander.global_position)
	
	# Apply mission modifiers and HUD config
	_apply_mission_modifiers()
	_apply_mission_hud_config()
	
	if debug_logging:
		print("[MissionController] Landing gameplay shown")

func _bind_lander() -> void:
	# Clear stale reference
	_lander = null

	var scene := get_tree().current_scene
	if scene == null:
		return

	# 1) Preferred method: use the exported NodePath (inspector-friendly)
	if lander_path != NodePath(""):
		var ln := scene.get_node_or_null(lander_path)
		if ln != null:
			_lander = ln as Node2D
			return

	# 2) Fallback: try to find World/Lander
	var world_node := scene.get_node_or_null("World")
	if world_node != null:
		var ln2 := world_node.get_node_or_null("Lander")
		if ln2 != null:
			_lander = ln2 as Node2D
			return

	# 3) Last-resort fallback: check group "lander" (if you ever want this)
	# var landers := scene.get_tree().get_nodes_in_group("lander")
	# if landers.size() > 0:
	#     _lander = landers[0] as Node2D

func _arm_touchdown_for_current_phase() -> void:
	_touchdown_armed = false
	_touchdown_consumed_for_phase = false

	if _current_phase.is_empty():
		return

	var mode: String = str(_current_phase.get("mode", ""))
	if mode != "lander":
		return

	# We only want touchdown processing on descent-like lander phases.
	var pid: String = str(_current_phase.get("id", ""))
	if pid.find("descent") != -1 or pid.find("landing") != -1 or pid.find("legacy") != -1:
		_touchdown_armed = true
