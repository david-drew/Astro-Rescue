extends RefCounted
class_name MissionObjectives		# MissionObjectivesV2

signal objective_updated(objective_id: String, new_state: Dictionary)
signal objectives_changed(snapshot: Array)

var debug: bool = false

var _mission_id: String = ""
var _objectives: Array = []

var _metrics: Dictionary = {
	"elapsed_time": 0.0,
	"time_limit": 0.0,
	"fuel_ratio": 1.0,
	"max_hull_damage_ratio": 0.0,
	"crashes": 0,
	"orbit_reached": false
}


# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func load_from_config(mission_id: String, mission_config: Dictionary) -> void:
	_mission_id = mission_id
	_objectives.clear()

	var raw_objectives: Array = mission_config.get("objectives", [])
	for raw in raw_objectives:
		var obj: Dictionary = {}
		obj["id"] = str(raw.get("id", ""))
		obj["type"] = str(raw.get("type", ""))
		obj["description"] = str(raw.get("description", ""))
		obj["is_primary"] = bool(raw.get("is_primary", true))

		var params: Dictionary = raw.get("params", {})
		obj["params"] = params.duplicate(true)
		obj["status"] = "pending"
		obj["progress"] = {}

		_validate_objective_type(obj)	# Sanity check
		_objectives.append(obj)

	if debug:
		print("[MissionObjectivesV2] Loaded ", _objectives.size(), " objectives for mission ", _mission_id)


func reset_state() -> void:
	for obj in _objectives:
		obj["status"] = "pending"
		obj["progress"] = {}
	if debug:
		print("[MissionObjectivesV2] State reset")

func reset() -> void:
	##
	# Full reset so this instance can be safely reused for another mission.
	##
	_mission_id = ""
	_objectives.clear()

	_metrics = {
		"elapsed_time": 0.0,
		"time_limit": 0.0,
		"fuel_ratio": 1.0,
		"max_hull_damage_ratio": 0.0,
		"crashes": 0,
		"orbit_reached": false
	}

	if debug:
		print("[MissionObjectivesV2] Full reset (mission id and metrics cleared)")


func set_metrics(metrics: Dictionary) -> void:
	for key in _metrics.keys():
		if metrics.has(key):
			_metrics[key] = metrics[key]

	if debug:
		print("[MissionObjectivesV2] Metrics updated: ", _metrics)

# High-level event entry point
func handle_event(event_type: String, payload: Dictionary) -> void:
	if debug:
		print("[MissionObjectives] handle_event type=", event_type, " payload=", payload)

	match event_type:
		"touchdown":
			_evaluate_landing_related(payload)
		"orbit_reached":
			_metrics["orbit_reached"] = true
			_evaluate_return_to_orbit(payload)
		"player_died":
			_evaluate_player_death(payload)
		"damage_event":
			_evaluate_damage_based(payload)
		"zone_reached":
			_evaluate_reach_zone(payload)
		"poi_reached":
			_evaluate_reach_poi(payload)
		"rescue_interaction_completed":
			_evaluate_rescue_interact(payload)
		"mission_tick":
			pass
		_:
			if debug:
				print("[MissionObjectives] Unknown event_type: ", event_type)

	_emit_objectives_changed()

# Wrappers for Mission Controller
func on_zone_reached(zone_id: String) -> void:
	handle_event("zone_reached", {"zone_id": zone_id})

func on_poi_reached(poi_id: String) -> void:
	handle_event("poi_reached", {"poi_id": poi_id})

func on_rescue_interaction_completed(target_id: String) -> void:
	handle_event("rescue_interaction_completed", {"target_id": target_id})

func on_touchdown(touchdown_data: Dictionary) -> void:
	handle_event("touchdown", touchdown_data)

func on_orbit_reached(data: Dictionary) -> void:
	handle_event("orbit_reached", data)

func on_player_died(cause: String, context: Dictionary) -> void:
	var payload := {"cause": cause, "context": context}
	handle_event("player_died", payload)

func on_damage_event(data: Dictionary) -> void:
	handle_event("damage_event", data)


# Called by MissionController right before building MissionResult.
# This is where we evaluate metrics-based objectives that depend on final state
# (time_under, fuel_remaining, no_damage, etc.).
func finalize_for_mission_end() -> void:
	_evaluate_time_based_final()
	_evaluate_fuel_based_final()
	_evaluate_damage_based_final()

	if debug:
		print("[MissionObjectivesV2] finalize_for_mission_end")

	_emit_objectives_changed()


# Summary/queries ----------------------------------------------------

func get_summary_state() -> Dictionary:
	var primary_completed := 0
	var primary_failed := 0
	var primary_pending := 0
	var bonus_completed := 0
	var bonus_failed := 0
	var bonus_pending := 0

	for obj in _objectives:
		var is_primary := bool(obj.get("is_primary", true))
		var status := str(obj.get("status", "pending"))
		if is_primary:
			if status == "completed":
				primary_completed += 1
			elif status == "failed":
				primary_failed += 1
			else:
				primary_pending += 1
		else:
			if status == "completed":
				bonus_completed += 1
			elif status == "failed":
				bonus_failed += 1
			else:
				bonus_pending += 1

	var overall_state := "running"
	if primary_failed > 0:
		overall_state = "fail"
	elif primary_pending == 0 and primary_completed > 0:
		# All primaries finished, none failed.
		# If any bonus failed, consider that partial; otherwise success.
		if bonus_failed > 0:
			overall_state = "partial"
		else:
			overall_state = "success"

	return {
		"overall_state": overall_state,
		"primary_completed": primary_completed,
		"primary_failed": primary_failed,
		"primary_pending": primary_pending,
		"bonus_completed": bonus_completed,
		"bonus_failed": bonus_failed,
		"bonus_pending": bonus_pending
	}


func any_primary_failed() -> bool:
	for obj in _objectives:
		if not bool(obj.get("is_primary", true)):
			continue
		if str(obj.get("status", "pending")) == "failed":
			return true
	return false


func are_all_primary_completed() -> bool:
	var has_primary := false
	for obj in _objectives:
		if not bool(obj.get("is_primary", true)):
			continue
		has_primary = true
		var status := str(obj.get("status", "pending"))
		if status != "completed":
			return false
	if not has_primary:
		return false
	return true


func get_objectives_snapshot() -> Array:
	var result: Array = []
	for obj in _objectives:
		result.append(obj.duplicate(true))
	return result


func get_primary_objectives() -> Array:
	var result: Array = []
	for obj in _objectives:
		if bool(obj.get("is_primary", true)):
			result.append(obj.duplicate(true))
	return result


func get_bonus_objectives() -> Array:
	var result: Array = []
	for obj in _objectives:
		if not bool(obj.get("is_primary", true)):
			result.append(obj.duplicate(true))
	return result


# -------------------------------------------------------------------
# Internal helpers
# -------------------------------------------------------------------

func _mark_completed(obj: Dictionary) -> void:
	var old_status := str(obj.get("status", "pending"))
	obj["status"] = "completed"
	if debug:
		print("[MissionObjectivesV2] completed ", obj.get("id", ""), " (was ", old_status, ")")
	_emit_objective_updated(obj)


func _mark_failed(obj: Dictionary) -> void:
	var old_status := str(obj.get("status", "pending"))
	obj["status"] = "failed"
	if debug:
		print("[MissionObjectivesV2] failed ", obj.get("id", ""), " (was ", old_status, ")")
	_emit_objective_updated(obj)


func _emit_objective_updated(obj: Dictionary) -> void:
	var oid := str(obj.get("id", ""))
	var snapshot := obj.duplicate(true)
	emit_signal("objective_updated", oid, snapshot)


func _emit_objectives_changed() -> void:
	var snapshot := get_objectives_snapshot()
	emit_signal("objectives_changed", snapshot)


func _get_param(obj: Dictionary, name: String, default_value: Variant) -> Variant:
	var params: Dictionary = obj.get("params", {})
	if params.has(name):
		return params[name]
	return default_value


# -------------------------------------------------------------------
# Evaluation: event-driven objectives
# -------------------------------------------------------------------

func _evaluate_landing_related(touchdown_data: Dictionary) -> void:
	var impact_speed := float(touchdown_data.get("impact_speed", 0.0))
	var landing_zone_id := str(touchdown_data.get("landing_zone_id", ""))
	var successful := bool(touchdown_data.get("successful", false))

	if debug:
		print("[MissionObjectivesV2] touchdown: success=", successful,
			" impact_speed=", impact_speed,
			" zone=", landing_zone_id)

	for obj in _objectives:
		if str(obj.get("type", "")) != "landing":
			continue
		if str(obj.get("status", "pending")) != "pending":
			continue

		var oid := str(obj.get("id", ""))
		var target_zone_id := str(_get_param(obj, "target_zone_id", "any"))
		var max_impact_speed := float(_get_param(obj, "max_impact_speed", 0.0))

		if debug:
			print("[MissionObjectivesV2] eval landing id=", oid,
				" success=", successful,
				" target_zone_id=", target_zone_id,
				" impact_speed=", impact_speed,
				" max_impact_speed=", max_impact_speed)

		if not successful:
			continue

		if target_zone_id != "" and target_zone_id != "any" and landing_zone_id != target_zone_id:
			continue

		if max_impact_speed > 0.0 and impact_speed > max_impact_speed:
			continue

		_mark_completed(obj)


func _evaluate_return_to_orbit(data: Dictionary) -> void:
	var altitude := float(data.get("altitude", 0.0))
	if debug:
		print("[MissionObjectivesV2] orbit_reached altitude=", altitude)

	for obj in _objectives:
		if str(obj.get("type", "")) != "return_to_orbit":
			continue
		if str(obj.get("status", "pending")) != "pending":
			continue

		var min_altitude := float(_get_param(obj, "min_altitude", 0.0))
		if min_altitude > 0.0 and altitude < min_altitude:
			continue

		_mark_completed(obj)


func _evaluate_player_death(payload: Dictionary) -> void:
	# If you ever want objectives that fail explicitly on death (e.g. "keep crew alive"),
	# this is where you'd implement them. For now we don't auto-fail anything here.
	if debug:
		print("[MissionObjectivesV2] player_died event: ", payload)


func _evaluate_damage_based(payload: Dictionary) -> void:
	# Optional: if you emit fine-grained damage events, handle them here.
	# For now, we rely on final metrics in _evaluate_damage_based_final.
	if debug:
		print("[MissionObjectivesV2] damage_event: ", payload)


# -------------------------------------------------------------------
# Evaluation: metrics-based objectives (usually at mission end)
# -------------------------------------------------------------------

func _evaluate_time_based_final() -> void:
	var elapsed_time := float(_metrics.get("elapsed_time", 0.0))

	for obj in _objectives:
		if str(obj.get("type", "")) != "time_under":
			continue
		if str(obj.get("status", "pending")) != "pending":
			continue

		var time_limit := float(_get_param(obj, "time_limit_seconds", 0.0))
		if time_limit <= 0.0:
			continue

		if elapsed_time <= time_limit:
			_mark_completed(obj)
		else:
			_mark_failed(obj)


func _evaluate_fuel_based_final() -> void:
	var fuel_ratio := float(_metrics.get("fuel_ratio", 1.0))

	for obj in _objectives:
		if str(obj.get("type", "")) != "fuel_remaining":
			continue
		if str(obj.get("status", "pending")) != "pending":
			continue

		var min_ratio := float(_get_param(obj, "min_fuel_ratio", 0.0))
		if min_ratio <= 0.0:
			continue

		if fuel_ratio >= min_ratio:
			_mark_completed(obj)
		else:
			_mark_failed(obj)


func _evaluate_damage_based_final() -> void:
	var max_damage_ratio := float(_metrics.get("max_hull_damage_ratio", 0.0))

	for obj in _objectives:
		if str(obj.get("type", "")) != "no_damage":
			continue
		if str(obj.get("status", "pending")) != "pending":
			continue

		var allowed_max := float(_get_param(obj, "max_damage_ratio", 0.0))
		if max_damage_ratio < allowed_max: # default means "no damage allowed"
			_mark_completed(obj)
		else:
			_mark_failed(obj)

func get_return_to_orbit_min_altitude() -> float:
	var min_altitude: float = 2500.0
	
	for obj in _objectives:
		if (obj.get("id", "")) == "return_to_orbit_after_ground_ops":
			var params:Dictionary = obj.get("params", {})
			var min_alt := float(params.get("min_altitude", 0.0))
			if min_alt > 0.0:
				min_altitude = min_alt/3.0 - 500.0
	
	#min_altitude = mission_config.get("min_altitude", 2500.0)
	return min_altitude

func _validate_objective_type(obj: Dictionary) -> void:
	var supported := [
		"landing",
		"return_to_orbit",
		"time_under",
		"fuel_remaining",
		"no_damage",
		"reach_zone",
		"reach_poi",
		"rescue_interact"
	]

	var t := str(obj.get("type", ""))
	if not supported.has(t):
		push_warning("[MissionObjectives] Unknown objective type '"
			+ t + "' for id='" + str(obj.get("id", "")) + "'")


func _evaluate_reach_zone(payload: Dictionary) -> void:
	var reached_zone_id := str(payload.get("zone_id", ""))

	if debug:
		print("[MissionObjectives] zone_reached: zone_id=", reached_zone_id)

	for obj in _objectives:
		if str(obj.get("type", "")) != "reach_zone":
			continue
		if str(obj.get("status", "pending")) != "pending":
			continue

		var oid := str(obj.get("id", ""))
		var target_zone_id := str(_get_param(obj, "target_zone_id", ""))
		if target_zone_id == "":
			if debug:
				print("[MissionObjectives] reach_zone id=", oid, " has no target_zone_id; skipping")
			continue

		if debug:
			print("[MissionObjectives] eval reach_zone id=", oid,
				" target_zone_id=", target_zone_id,
				" reached_zone_id=", reached_zone_id)

		if reached_zone_id != target_zone_id:
			continue

		_mark_completed(obj)

func _evaluate_reach_poi(payload: Dictionary) -> void:
	var reached_poi_id := str(payload.get("poi_id", ""))

	if debug:
		print("[MissionObjectives] poi_reached: poi_id=", reached_poi_id)

	for obj in _objectives:
		if str(obj.get("type", "")) != "reach_poi":
			continue
		if str(obj.get("status", "pending")) != "pending":
			continue

		var oid := str(obj.get("id", ""))
		var target_poi_id := str(_get_param(obj, "poi_id", ""))

		if target_poi_id == "":
			if debug:
				print("[MissionObjectives] reach_poi id=", oid, " has no poi_id; skipping")
			continue

		if debug:
			print("[MissionObjectives] eval reach_poi id=", oid,
				" target_poi_id=", target_poi_id,
				" reached_poi_id=", reached_poi_id)

		if reached_poi_id != target_poi_id:
			continue

		_mark_completed(obj)
	
func _evaluate_rescue_interact(payload: Dictionary) -> void:
	var completed_target_id := str(payload.get("target_id", ""))

	if debug:
		print("[MissionObjectives] rescue_interaction_completed: target_id=", completed_target_id)

	for obj in _objectives:
		if str(obj.get("type", "")) != "rescue_interact":
			continue
		if str(obj.get("status", "pending")) != "pending":
			continue

		var oid := str(obj.get("id", ""))
		var target_id := str(_get_param(obj, "target_id", ""))

		if target_id == "":
			if debug:
				print("[MissionObjectives] rescue_interact id=", oid, " has no target_id; skipping")
			continue

		if debug:
			print("[MissionObjectives] eval rescue_interact id=", oid,
				" target_id=", target_id,
				" completed_target_id=", completed_target_id)

		if completed_target_id != target_id:
			continue

		_mark_completed(obj)
