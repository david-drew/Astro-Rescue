# res://scripts/modes/mode1/mission_objectives.gd
extends RefCounted
class_name MissionObjectives

var debug:bool = false

var mc_phase:MissionPhases = MissionPhases.new()

# Runtime objective lists
var active_objectives: Array = []      # current phase primaries (runtime dicts)
var bonus_objectives: Array = []       # legacy top-level bonus (runtime dicts)

# Lightweight shared runtime stats (set by MC / Landing)
var mission_config: Dictionary = {}
var mission_elapsed_time: float = 0.0
var mission_time_limit: float = -1.0
var current_fuel_ratio: float = 1.0
var max_hull_damage_ratio: float = 0.0
var orbit_reached: bool = false

# POI / EVA state used by objectives
var current_poi_inside: String = ""

# Previous landing site objective state (filled by Landing/MC for now)
var previous_landing_site_valid: bool = false
var previous_landing_site_pos: Vector2 = Vector2.ZERO

func init_for_phase(phase: Dictionary, fullmission_config: Dictionary) -> void:
	mission_config = fullmission_config.duplicate(true)
	active_objectives.clear()

	var objs: Array = phase.get("objectives", [])
	for obj in objs:
		if typeof(obj) != TYPE_DICTIONARY:
			continue
		var runtime_obj: Dictionary = obj.duplicate(true)
		runtime_obj["status"] = "pending"
		runtime_obj["progress"] = {}
		active_objectives.append(runtime_obj)

	bonus_objectives.clear()
	var legacy_obj_block: Dictionary = mission_config.get("objectives", {})
	var legacy_bonus: Array = legacy_obj_block.get("bonus", [])
	for obj_b in legacy_bonus:
		if typeof(obj_b) != TYPE_DICTIONARY:
			continue
		var runtime_obj_b: Dictionary = obj_b.duplicate(true)
		runtime_obj_b["status"] = "pending"
		runtime_obj_b["progress"] = {}
		bonus_objectives.append(runtime_obj_b)

	#mission_controller.arm_touchdown_for_current_phase()


func on_poi_entered(poi_id: String) -> void:
	current_poi_inside = poi_id

	# Complete reach_poi objectives in active phase
	for obj in active_objectives:
		if obj.get("status", "pending") != "pending":
			continue
		if obj.get("type", "") != "reach_poi":
			continue

		var target_id: String = str(get_obj_param(obj, "poi_id", ""))
		if target_id != "" and target_id == poi_id:
			obj["status"] = "completed"
			if debug:
				print("[MissionController] Objective completed: reach_poi id=", obj.get("id", ""))

	# Phase completion rule: reached_poi
	mc_phase.check_phase_completion_from_poi(poi_id)


func on_poi_exited(poi_id: String) -> void:
	if current_poi_inside == poi_id:
		current_poi_inside = ""


func on_eva_interacted(target_id: String) -> void:
	#if mission_state != "running":
	#	return

	# Complete rescue_interact objectives
	for obj in active_objectives:
		if obj.get("status", "pending") != "pending":
			continue
		if obj.get("type", "") != "rescue_interact":
			continue

		var t: String = str(get_obj_param(obj, "target_id", ""))
		if t == "" or t != target_id:
			continue

		# If you want timed interaction, we can add progress tracking.
		# For now, complete on interact event.
		obj["status"] = "completed"
		if debug:
			print("[MC-Objectives] Objective completed: rescue_interact id=", obj.get("id", ""))

	#phases_mgr.check_phase_completion_from_rescue(target_id, self)

func on_orbit_reached() -> void:
	orbit_reached = true
	evaluate_return_to_orbit_objectives()

# Evaluation helpers (all moved)
func get_obj_param(obj: Dictionary, key: String, default_value):
	var params: Dictionary = obj.get("params", {})
	if params.has(key):
		return params.get(key, default_value)

	return obj.get(key, default_value)


func get_return_to_orbit_min_altitude() -> float:
	var min_altitude: float = 0.0
	for obj in active_objectives:
		if obj.get("type", "") != "return_to_orbit":
			continue

		var candidate: float = float(get_obj_param(obj, "min_altitude", 0.0))
		if candidate > 0.0 and (min_altitude <= 0.0 or candidate < min_altitude):
			min_altitude = candidate

		# If no explicit return-to-orbit altitude was set on objectives, fall back to the
		# mission's spawn height, which represents the orbital insertion altitude.
		if min_altitude <= 0.0:
			var spawn_cfg: Dictionary = mission_config.get("spawn", {})
			var spawn_height: float = float(spawn_cfg.get("height_above_surface", 0.0))
			if spawn_height > 0.0:
				min_altitude = spawn_height

	# Final fallback: ensure orbit requires a meaningful climb.
	if min_altitude <= 0.0:
		min_altitude = 10000.0

	return min_altitude

func evaluate_landing_objectives(impact_data: Dictionary, success: bool) -> void:
	for obj in active_objectives:
		if obj.get("type", "") != "landing":
			continue
		if obj.get("status", "pending") != "pending":
			continue

		if not success:
			continue

		var target_zone_id: String = get_obj_param(obj, "target_zone_id", "")
		var landing_zone_id: String = impact_data.get("landing_zone_id", "")
		if target_zone_id != "" and target_zone_id != "any" and landing_zone_id != target_zone_id:
			continue

		var max_speed: float = float(get_obj_param(obj, "max_impact_speed", 0.0))
		var impact_speed: float = float(impact_data.get("impact_speed", 0.0))
		if max_speed > 0.0 and impact_speed > max_speed:
			continue

		obj["status"] = "completed"
		#_landing_successful = true
		if debug:
			print("[MC-Objectives] Objective completed: landing id=", obj.get("id", ""))

func evaluate_precision_landing_objectives(impact_data: Dictionary) -> void:
	for obj in active_objectives:
		if obj.get("type", "") != "precision_landing":
			continue
		if obj.get("status", "pending") != "pending":
			continue

		var max_hull_damage: float = float(obj.get("max_hull_damage_ratio", 0.0))
		var hull_damage: float = float(impact_data.get("hull_damage_ratio", 0.0))

		if hull_damage <= max_hull_damage:
			obj["status"] = "completed"
			if debug:
				print("[MC-Objectives] Objective completed: precision_landing id=", obj.get("id", ""))


func evaluate_landing_accuracy_objectives(impact_data: Dictionary) -> void:
	for obj in active_objectives:
		if obj.get("type", "") != "landing_accuracy":
			continue
		if obj.get("status", "pending") != "pending":
			continue

		var landing_zone_id: String = impact_data.get("landing_zone_id", "")
		var expected_zone_id: String = obj.get("landing_zone_id", "")

		if landing_zone_id != "" and landing_zone_id == expected_zone_id:
			obj["status"] = "completed"
			if debug:
				print("[MC-Objectives] Objective completed: landing_accuracy id=", obj.get("id", ""))


func evaluate_return_to_orbit_objectives() -> void:
	for obj in active_objectives:
		if obj.get("type", "") != "return_to_orbit":
			continue
		if obj.get("status", "pending") != "pending":
			continue

		if orbit_reached:
			obj["status"] = "completed"
			if debug:
				print("[MC-Objectives] Objective completed: return_to_orbit id=", obj.get("id", ""))


func evaluate_time_under_objectives() -> void:
	for obj in active_objectives:
		if obj.get("type", "") != "time_under":
			continue
		if obj.get("status", "pending") != "pending":
			continue

		var limit: float = float(obj.get("time_limit_seconds", 0.0))
		if mission_elapsed_time <= limit:
			obj["status"] = "completed"
			if debug:
				print("[MC-Objectives] Objective completed: time_under id=", obj.get("id", ""))



func evaluate_fuel_remaining_objectives() -> void:
	for obj in active_objectives:
		if obj.get("type", "") != "fuel_remaining":
			continue
		if obj.get("status", "pending") != "pending":
			continue

		var min_ratio: float = float(obj.get("min_fuel_ratio", 0.0))
		if current_fuel_ratio >= min_ratio:
			obj["status"] = "completed"
			if debug:
				print("[MC-Objectives] Objective completed: fuel_remaining id=", obj.get("id", ""))


func evaluate_no_damage_objectives() -> void:
	for obj in active_objectives:
		if obj.get("type", "") != "no_damage":
			continue
		if obj.get("status", "pending") != "pending":
			continue

		if max_hull_damage_ratio <= 0.0:
			obj["status"] = "completed"
			if debug:
				print("[MC-Objectives] Objective completed: no_damage id=", obj.get("id", ""))


func force_fail_all_pending_primary(reason: String) -> void:
	for obj in active_objectives:
		if obj.get("status", "pending") == "pending":
			obj["status"] = "failed"
			if debug:
				print("[MC-Objectives] Primary objective failed by reason=", reason, " id=", obj.get("id", ""))


func tick_phase_objectives() -> void:
	if mc_phase.current_phase.is_empty():
		return

	if str(mc_phase.current_phase.get("mode","")) == "buggy":
		check_reach_previous_landing_site()


func check_reach_previous_landing_site() -> void:
	if not previous_landing_site_valid:
		return

	# Find pending reach_previous_landing_site objective and its radius
	var radius: float = 0.0
	var has_obj: bool = false

	for obj in active_objectives:
		if obj.get("status", "pending") != "pending":
			continue
		if obj.get("type", "") != "reach_previous_landing_site":
			continue

		radius = float(get_obj_param(obj, "arrival_radius", 140.0))
		has_obj = true

	if not has_obj:
		return

	# Get the buggy node.
	# Your VehicleBuggy should add itself to group "buggy" on ready.
	var buggy: Node2D = GameState.vehicle.buggy
	var dist: float = buggy.global_position.distance_to(previous_landing_site_pos)

	if dist > radius:
		return

	# Complete all matching objectives
	for obj2 in active_objectives:
		if obj2.get("status", "pending") != "pending":
			continue
		if obj2.get("type", "") != "reach_previous_landing_site":
			continue
		obj2["status"] = "completed"
		if debug:
			print("[MC-Objectives] Objective completed: reach_previous_landing_site id=", obj2.get("id", ""))

	# If phase completion expects this, advance
	#phase_mgr.check_phase_completion_from_previous_landing_site(self)

func any_primary_failed() -> bool:
	# Returns true if any active (primary) objective has status "failed".
	for obj in active_objectives:
		var status := str(obj.get("status", "pending"))
		if status == "failed":
			return true
	return false

func any_primary_pending() -> bool:
	# Returns true if any active (primary) objective is still "pending".
	for obj in active_objectives:
		var status := str(obj.get("status", "pending"))
		if status == "pending":
			return true
	return false
