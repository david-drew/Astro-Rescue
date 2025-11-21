## res://scripts/modes/mode1/mission_controller.gd
extends Node
#class_name MissionController

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
@export var lander_path: NodePath
@export var hud_path: NodePath

@export_category("Mission Data")
@export var mission_data_dir: String = "res://data/missions"
@export var mission_file_id: String = ""  # e.g. "training_mission_01" or "mission_01"

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

var _orbit_reached: bool = false
var _orbit_reached_altitude: float = 0.0
var _orbit_reached_time: float = 0.0

var _terrain_generator: TerrainGenerator = null
var _lander: Node = null
var _hud: Node = null


# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------

func _reset_mission_runtime_state() -> void:
	# Reset per-mission runtime state so we can safely start a new mission.
	_mission_state = "not_started"
	_mission_elapsed_time = 0.0

	_current_fuel_ratio = 1.0
	_max_hull_damage_ratio = 0.0
	_crashes_count = 0
	_player_died = false
	_lander_destroyed = false

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

	if terrain_generator_path != NodePath(""):
		_terrain_generator = get_node_or_null(terrain_generator_path) as TerrainGenerator

	if lander_path != NodePath(""):
		_lander = get_node_or_null(lander_path)

	if hud_path != NodePath(""):
		_hud = get_node_or_null(hud_path)

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
			var ws = null
			if WorldSimManager:
				ws = WorldSimManager
			if ws != null and ws.has_method("get_next_training_mission_id"):
				var tid: String = ws.get_next_training_mission_id()
				if tid != "":
					print("\tWARN trying to load mission file backup: ", tid)
					var loaded2 := _load_mission_config_from_json(tid)
					if not loaded2.is_empty():
						_mission_config = loaded2
						GameState.current_mission_config = loaded2.duplicate(true)


	if _mission_config.is_empty():
		print("\tERROR both mission file loads FAILED")
		push_warning("MissionController: No mission config available (GameState empty and file load failed).")
		return

	_mission_id = _mission_config.get("id", "")
	_is_training = bool(_mission_config.get("is_training", false))
	_tier = int(_mission_config.get("tier", 0))

	_failure_rules = _mission_config.get("failure_rules", {})
	_rewards = _mission_config.get("rewards", {})

	# Normalize objectives into runtime-tracked arrays.
	var objectives: Dictionary = _mission_config.get("objectives", {})
	var prim: Array = objectives.get("primary", [])
	var bonus: Array = objectives.get("bonus", [])

	_primary_objectives.clear()
	for obj in prim:
		if typeof(obj) != TYPE_DICTIONARY:
			continue
		var runtime_obj: Dictionary = obj.duplicate(true)
		runtime_obj["status"] = "pending"  # "pending", "completed", "failed"
		runtime_obj["progress"] = {}
		_primary_objectives.append(runtime_obj)

	_bonus_objectives.clear()
	for obj_b in bonus:
		if typeof(obj_b) != TYPE_DICTIONARY:
			continue
		var runtime_obj_b: Dictionary = obj_b.duplicate(true)
		runtime_obj_b["status"] = "pending"
		runtime_obj_b["progress"] = {}
		_bonus_objectives.append(runtime_obj_b)

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
	
	# After computing _mission_time_limit:
	_reset_mission_timer()

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
			_terrain_generator = get_node_or_null(terrain_generator_path) as TerrainGenerator
	if _terrain_generator == null:
		return

	var terrain_config: Dictionary = _mission_config.get("terrain", {})
	if terrain_config.is_empty():
		return

	if debug_logging:
		print("[MissionController] Applying terrain config: ", terrain_config)

	_terrain_generator.generate_terrain(terrain_config)

## FIXED _position_lander_from_spawn() function
## Replace the function in mission_controller.gd with this

func _position_lander_from_spawn() -> void:
	if _lander == null:
		print("[MissionController] ERROR: No Lander, cannot set spawn point.")
		return

	var spawn_cfg: Dictionary = _mission_config.get("spawn", {})
	if spawn_cfg.is_empty():
		print("[MissionController] WARN: Mission has no 'spawn' block; using current lander position.")
		return

	var terrain_cfg: Dictionary = _mission_config.get("terrain", {})

	var start_zone_id: String = String(spawn_cfg.get("start_above_zone_id", ""))
	var height_above_surface: float = float(spawn_cfg.get("height_above_surface", 30000.0))
	var offset_x: float = float(spawn_cfg.get("offset_x", 0.0))
	var initial_velocity_arr: Array = spawn_cfg.get("initial_velocity", [0.0, 0.0])

	# Defaults
	var center_x: float = 0.0
	var surface_y: float = 600.0  # Fallback only

	# ----------------------------------------------------------
	# 1) Get ACTUAL terrain surface from TerrainGenerator
	# ----------------------------------------------------------
	# CRITICAL FIX: Use actual generated terrain surface, not baseline_y
	if _terrain_generator != null:
		# Get actual highest point of generated terrain
		surface_y = _terrain_generator.get_highest_point_y()
		
		if debug_logging:
			print("[MissionController] Using actual terrain surface_y from generator: ", surface_y)
		
		# If spawn is above a specific landing zone, use that zone's surface
		if start_zone_id != "" and start_zone_id != "any":
			var zone_info: Dictionary = _terrain_generator.get_landing_zone_world_info(start_zone_id)
			if not zone_info.is_empty():
				# Use landing zone's center_x and surface_y
				center_x = float(zone_info.get("center_x", center_x))
				# Landing zones have their own surface_y (they're flattened)
				var zone_surface_y = zone_info.get("surface_y", null)
				if zone_surface_y != null:
					surface_y = float(zone_surface_y)
				
				if debug_logging:
					print("[MissionController] Using landing zone '", start_zone_id, "' info:")
					print("  center_x: ", center_x)
					print("  surface_y: ", surface_y)
			else:
				push_warning("[MissionController] Landing zone '", start_zone_id, "' not found in terrain generator!")
				# Fallback to terrain center
				center_x = _terrain_generator.get_center_x()
		else:
			# No specific zone, use terrain center
			center_x = _terrain_generator.get_center_x()
			if debug_logging:
				print("[MissionController] Using terrain center_x: ", center_x)
	else:
		# Fallback: Parse from terrain config (old behavior)
		push_warning("[MissionController] TerrainGenerator not available, using config baseline_y!")
		
		if not terrain_cfg.is_empty():
			surface_y = float(terrain_cfg.get("baseline_y", 600.0))

			var landing_zones: Array = terrain_cfg.get("landing_zones", [])
			if start_zone_id != "" and landing_zones.size() > 0:
				for zone_cfg in landing_zones:
					if typeof(zone_cfg) != TYPE_DICTIONARY:
						continue
					var zid: String = String(zone_cfg.get("id", ""))
					if zid == start_zone_id:
						center_x = float(zone_cfg.get("center_x", 0.0))
						break

			# If we didn't find the specific zone, fall back to terrain center
			if center_x == 0.0:
				var length: float = float(terrain_cfg.get("length", 8000.0))
				center_x = length * 0.5

	# ----------------------------------------------------------
	# 2) Build final spawn position / velocity
	# ----------------------------------------------------------
	var spawn_pos := Vector2(center_x + offset_x, surface_y - height_above_surface)
	var spawn_velocity := Vector2.ZERO

	if initial_velocity_arr.size() >= 2:
		spawn_velocity = Vector2(float(initial_velocity_arr[0]), float(initial_velocity_arr[1]))

	# ----------------------------------------------------------
	# 3) Debug output (ALWAYS show this, not just in debug_logging mode)
	# ----------------------------------------------------------
	print("[MissionController] === SPAWN DEBUG ===")
	print("  Config height_above_surface: ", height_above_surface)
	print("  Actual terrain surface_y: ", surface_y)
	print("  Landing zone ID: ", start_zone_id if start_zone_id != "" else "none (using terrain center)")
	print("  Center X: ", center_x)
	print("  Offset X: ", offset_x)
	print("  Final spawn position: ", spawn_pos)
	print("  Calculated altitude: ", surface_y - spawn_pos.y, " pixels")
	print("  Expected altitude: ", height_above_surface, " pixels")
	
	if abs((surface_y - spawn_pos.y) - height_above_surface) > 1.0:
		push_warning("[MissionController] Altitude mismatch! Check terrain generation.")
	
	if debug_logging:
		print("[MissionController] Initial velocity: ", spawn_velocity)

	# ----------------------------------------------------------
	# 4) Apply spawn position
	# ----------------------------------------------------------
	_lander.global_position = spawn_pos

	PhysicsServer2D.body_set_state(
		_lander.get_rid(),
		PhysicsServer2D.BODY_STATE_TRANSFORM,
		Transform2D.IDENTITY.translated(spawn_pos)
	)

	if _lander is RigidBody2D:
		var rb := _lander as RigidBody2D
		rb.linear_velocity = spawn_velocity
		rb.angular_velocity = 0.0
	
	# Set altitude reference for lander HUD
	if _lander.has_method("set") and "altitude_reference_y" in _lander:
		_lander.set("altitude_reference_y", surface_y)

	print("Positioning Lander at: ", spawn_pos )
	print("Surface Y at: ", surface_y )

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
	if not Engine.has_singleton("EventBus"):
		push_warning("MissionController: EventBus singleton not found; no mission events will be received.")
		return

	var eb := EventBus

	if not eb.is_connected("touchdown", Callable(self, "_on_touchdown")):
		eb.connect("touchdown", Callable(self, "_on_touchdown"))

	if not eb.is_connected("lander_destroyed", Callable(self, "_on_lander_destroyed")):
		eb.connect("lander_destroyed", Callable(self, "_on_lander_destroyed"))

	if not eb.is_connected("fuel_changed", Callable(self, "_on_fuel_changed")):
		eb.connect("fuel_changed", Callable(self, "_on_fuel_changed"))

	if not eb.is_connected("player_died", Callable(self, "_on_player_died")):
		eb.connect("player_died", Callable(self, "_on_player_died"))

	# You can connect to TimeManager's tick if desired.
	var tm = TimeManager.new()
	if not tm.is_connected("time_tick", Callable(self, "_on_time_tick")):
		tm.connect("time_tick", Callable(self, "_on_time_tick"))


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

func begin_mission() -> void:
	##
	# Start (or restart) a mission using the current GameState state.
	# This can be called multiple times per session (e.g., training 01,
	# then 02, then procedural missions), without reloading the scene.
	##
	_reset_mission_runtime_state()
	_load_mission_config()

	# If config failed to load, abort gracefully.
	if _mission_config.is_empty():
		if debug_logging:
			print("[MissionController] begin_mission() aborted: no mission_config loaded.")
		return

	_mission_state = "running"

	if debug_logging:
		print("[MissionController] Mission started: ", _mission_id)

	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("mission_started", _mission_id)

	# Refresh scene references in case something changed (e.g. lander respawned).
	if terrain_generator_path != NodePath(""):
		_terrain_generator = get_node_or_null(terrain_generator_path) as TerrainGenerator

	if lander_path != NodePath(""):
		_lander = get_node_or_null(lander_path)

	if hud_path != NodePath(""):
		_hud = get_node_or_null(hud_path)

	# Apply terrain, spawn, lander modifiers, and HUD config from the mission.
	_apply_mission_setup()


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


func abort_mission(reason: String = "aborted") -> void:
	if _mission_state != "running":
		return

	if debug_logging:
		print("[MissionController] Mission aborted: ", reason)

	_end_mission("fail", reason)


# -------------------------------------------------------------------
# Event handlers
# -------------------------------------------------------------------

func _on_touchdown(touchdown_data: Dictionary) -> void:
	if _mission_state != "running":
		return

	var success: bool = bool(touchdown_data.get("successful", false))
	var impact_data: Dictionary = touchdown_data.get("impact_data", {})
	if impact_data.is_empty():
		return

	if debug_logging:
		print("[MissionController] Touchdown event received: success=", success, " impact_data=", impact_data)

	# Update crash / hull damage info
	var hull_damage_ratio: float = float(impact_data.get("hull_damage_ratio", 0.0))
	if hull_damage_ratio > _max_hull_damage_ratio:
		_max_hull_damage_ratio = hull_damage_ratio

	if not success:
		_crashes_count += 1

	# Evaluate any precision landing objectives.
	_evaluate_precision_landing_objectives(impact_data)
	_evaluate_landing_accuracy_objectives(impact_data)

	# After touchdown: check if objectives are satisfied, and auto-end if configured.
	_check_for_mission_completion()


func _on_lander_destroyed() -> void:
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
	if Engine.has_singleton("GameState"):
		GameState.current_mission_result = mission_result.duplicate(true)

	# Broadcast via EventBus.
	if Engine.has_singleton("EventBus"):
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
	_apply_mission_terrain()
	_position_lander_from_spawn()
	_apply_lander_loadout()
	_apply_hud_instruments()
	_update_hud_timer()


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
