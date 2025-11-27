# res://scripts/modes/mode1/mission_landing.gd
extends RefCounted
class_name MissionLanding

var debug:bool = true

var mc_phase = MissionPhases.new()

# Touchdown gating
var touchdown_armed: bool = false
var touchdown_consumed_for_phase: bool = false
var last_touchdown_ms: int = 0

# Landing stats
var landing_tolerance_mult: float = 1.0
var max_hull_damage_ratio: float = 0.0
var crashes_count: int = 0
var landing_successful: bool = false

# Previous landing site
var previous_landing_site_pos: Vector2 = Vector2.ZERO
var previous_landing_site_valid: bool = false

func arm_for_phase(phase: Dictionary) -> void:
	print("\tMC-Land arm_for_phase entered")
	touchdown_armed = false
	touchdown_consumed_for_phase = false

	if phase.is_empty():
		return

	var mode: String = str(mc_phase.current_phase.get("mode", ""))
	if mode != "lander":
		return

	# We only want touchdown processing on descent-like lander phases.
	var pid: String = str(mc_phase.current_phase.get("id", ""))
	print("\t[MC-Land] arm_for_phase pid: ", pid)					# TODO Debug DELETE
	
	if pid.find("descent") != -1 or pid.find("landing") != -1 or pid.find("legacy") != -1:
		touchdown_armed = true


func on_touchdown(
	touchdown_data: Dictionary,
	mission_is_running: bool,
	uses_v1_4_phases: bool,
	objectives_mgr: MissionObjectives,
	phases_mgr: MissionPhases,
	debug: bool,
	mission_controller: Node
) -> void:
	#if mission_state != "running":	return

	# Ignore touchdown if we aren't in a descent lander phase
	if not touchdown_armed:
		return

	print("\t.....tdown IS armed.............")	# TODO DELETE
	if touchdown_consumed_for_phase:
		return

	# Debounce rapid repeats (bounce/slide contacts)
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - last_touchdown_ms < 500:
		return
	last_touchdown_ms = now_ms

	var success: bool = bool(touchdown_data.get("successful", touchdown_data.get("success", false)))
	print("\t.....tdown success: ", success)	# TODO DELETE
	var impact_data: Dictionary = touchdown_data.get("impact_data", touchdown_data)
	if impact_data.is_empty():
		return
	
	print("\t.....tdown impact: ", impact_data)	# TODO DELETE

	# Apply forgiveness: relax impact speed / success classification a bit.
	# If your touchdown sender includes an impact/velocity magnitude, scale it down for evaluation.
	# We do NOT lie to physics — only to objective evaluation and crash classification.
	var eval_impact_data: Dictionary = impact_data.duplicate(true)
	if eval_impact_data.has("impact_speed"):
		var spd: float = float(eval_impact_data.get("impact_speed", 0.0))
		eval_impact_data["impact_speed"] = spd / landing_tolerance_mult
	if eval_impact_data.has("vertical_speed"):
		var vsp: float = float(eval_impact_data.get("vertical_speed", 0.0))
		eval_impact_data["vertical_speed"] = vsp / landing_tolerance_mult
	if eval_impact_data.has("horizontal_speed"):
		var hsp: float = float(eval_impact_data.get("horizontal_speed", 0.0))
		eval_impact_data["horizontal_speed"] = hsp / landing_tolerance_mult

	# If the sender gave a boolean success, and we scaled speeds,
	# we can optionally re-derive success if a speed threshold exists.
	# Otherwise leave success as-is.
	if eval_impact_data.has("max_safe_impact_speed"):
		var max_safe: float = float(eval_impact_data.get("max_safe_impact_speed", 30.0))
		var used_speed: float = float(eval_impact_data.get("impact_speed", 0.0))
		if max_safe > 0.0 and used_speed <= max_safe:
			success = true

	if debug:
		print("[MC-Objectives] Touchdown event received: success=", success, " impact_data=", impact_data, " tol_mult=", landing_tolerance_mult)

	# Update crash / hull damage info
	var hull_damage_ratio: float = float(impact_data.get("hull_damage_ratio", 0.0))
	if hull_damage_ratio > max_hull_damage_ratio:
		max_hull_damage_ratio = hull_damage_ratio

	if not success:
		crashes_count += 1
	else:
		landing_successful = true
		store_previous_landing_site(impact_data, mission_controller.get_tree())

	if debug:
		print("[MC-Landing] touchdown success=", success,
			" impact_speed=", eval_impact_data.get("impact_speed", 0.0),
			" v=", eval_impact_data.get("vertical_speed", 0.0),
			" h=", eval_impact_data.get("horizontal_speed", 0.0),
			" zone=", eval_impact_data.get("landing_zone_id", ""))

	# Always evaluate landing-related objectives on touchdown
	objectives_mgr.evaluate_landing_objectives(eval_impact_data, success)
	objectives_mgr.evaluate_precision_landing_objectives(eval_impact_data)
	objectives_mgr.evaluate_landing_accuracy_objectives(eval_impact_data)


	# Always evaluate landing-related objectives on touchdown
	objectives_mgr.evaluate_landing_objectives(eval_impact_data, success)
	objectives_mgr.evaluate_precision_landing_objectives(eval_impact_data)
	objectives_mgr.evaluate_landing_accuracy_objectives(eval_impact_data)


	# v1.4: see if this touchdown completes the current lander phase
	mc_phase.check_phase_completion_from_touchdown(success, eval_impact_data)

	#if uses_v1_4_phases:
		# Consume touchdown for this descent phase so bounces can't re-trigger
	touchdown_consumed_for_phase = true
	#else:
	#	mission_controller.check_for_mission_completion()


func store_previous_landing_site(impact_data: Dictionary, tree: SceneTree) -> void:
	# Try to get a reliable position from impact_data first
	if impact_data.has("position"):
		var p = impact_data.get("position")
		if typeof(p) == TYPE_VECTOR2:
			previous_landing_site_pos = p
			previous_landing_site_valid = true
			return

	if GameState.vehicle.lander != null:
		previous_landing_site_pos = GameState.vehicle.lander.global_position
		previous_landing_site_valid = true
	else:
		print("[MC-Landing] WARN: Unable to store previous_landing pos data (no lander node)")

# Small getters for Results / Objectives
func get_stats() -> Dictionary:
	return {
		"max_hull_damage_ratio": max_hull_damage_ratio,
		"crashes": crashes_count,
		"landing_successful": landing_successful,
		"previous_site_valid": previous_landing_site_valid,
		"previous_site_pos": previous_landing_site_pos
	}
