# res://scripts/modes/mode1/missionphases.gd
class_name MissionPhases
extends RefCounted

var debug:bool = true

var mission_controller:Node = null
#var mc_goal = MissionObjectives.new()

var uses_v1_4phases: bool = false
var phases: Array = []
var current_phase_index: int = -1
var current_phase: Dictionary = {}

var uses_v1_4_phases: bool = false
var touchdown_armed: bool = false
var touchdown_consumed_for_phase: bool = false

func init(controller: Node) -> void:
	mission_controller = controller

func build_runtimephases_from_config(mission_config: Dictionary) -> void:
	phases.clear()
	uses_v1_4phases = false

	var rawphases: Array = mission_config.get("phases", [])
	if rawphases.size() > 0:
		# v1.4 mission
		uses_v1_4phases = true

		for p in rawphases:
			if typeof(p) != TYPE_DICTIONARY:
				continue
			phases.append(p.duplicate(true))

		return

func set_current_phase(index: int) -> void:
	if phases.is_empty():
		push_warning("MissionController: No phases available after build.")
		current_phase_index = -1
		current_phase = {}
		#mc_goal.active_objectives.clear()
		#mc_goal.active_bonus_objectives.clear()
		return

	if index < 0 or index >= phases.size():
		push_warning("[MC:Phases] Phase index out of range: " + str(index))
		return

	current_phase_index = index
	current_phase = phases[index]

	# Delegation in step 1: MC still owns objective runtime.
	mission_controller.mc_goal.init_for_phase(current_phase, mission_controller.mission_config)
	mission_controller.mc_landing.arm_for_phase(current_phase)
	arm_touchdown_for_current_phase()


func check_phase_completion_from_touchdown(success: bool, impact_data: Dictionary) -> void:
	
	if not uses_v1_4phases:
		return

	if current_phase.is_empty():
		return

	var mode: String = str(current_phase.get("mode", ""))
	if mode != "lander":
		return

	var comp: Dictionary = current_phase.get("completion", {})
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

	# Add more touchdown-driven completion types later if needed.

	if ok:
		if debug:
			print("[MC:Phases] Phase complete on touchdown. Advancing from phase ", current_phase_index)
		
		advance_phase()

func check_phase_completion_from_poi(poi_id: String) -> void:
	if not uses_v1_4phases:
		return
	if current_phase.is_empty():
		return

	var comp: Dictionary = current_phase.get("completion", {})
	var ctype: String = str(comp.get("type", ""))

	if ctype != "reached_poi":
		return

	var target_id: String = str(comp.get("poi_id", ""))
	if target_id == "" or target_id != poi_id:
		return

	if debug:
		print("[MC:Phases] Phase complete on POI arrival. Advancing from phase ", current_phase_index)

	advance_phase()

func check_phase_completion_from_rescue(target_id: String) -> void:
	var comp: Dictionary = current_phase.get("completion", {})
	var ctype: String = str(comp.get("type", ""))

	if ctype != "rescued_target":
		return

	var t: String = str(comp.get("target_id", ""))
	if t == "" or t != target_id:
		return

	if debug:
		print("[MC:Phases] Phase complete on rescue target.")

	advance_phase()


func check_phase_completion_from_previous_landing_site() -> void:
	var comp: Dictionary = current_phase.get("completion", {})
	var ctype: String = str(comp.get("type", ""))

	if ctype != "reached_previous_landing_site":
		return

	if debug:
		print("[MC:Phases] Phase complete on return to previous landing site.")

	advance_phase()


func advance_phase() -> void:
	if current_phase_index < 0:
		return

	var next_index: int = current_phase_index + 1
	if next_index >= phases.size():
		# No more phases; rely on existing mission completion path.
		mission_controller.check_for_mission_completion()
		return

	set_current_phase(next_index)
	enter_current_phase()

func enter_current_phase() -> void:
	if current_phase.is_empty():
		return

	var mode: String = str(current_phase.get("mode", ""))

	if debug:
		print("[MC:Phases] Entering phase ", current_phase_index, " mode=", mode, " id=", current_phase.get("id", ""))

	# Lander phases after touchdown (e.g., ascent) don't need a scene swap.
	# Player is already in lander gameplay; objectives now guide takeoff.
	if mode == "lander":
		return

	# Buggy / EVA will be wired later.
	# We avoid calling missing methods to keep this patch safe.
	if mode == "buggy":
		print("\t................We want buggy phase.................")     # TODO DELETE
		EventBus.emit_signal("phase_mode_requested", "buggy", current_phase)
		return

	if mode == "rescue":
		print("\t................We want EVA phase.................")       # TODO DELETE
		EventBus.emit_signal("phase_mode_requested", "rescue", current_phase)
		return

func build_runtime_phases_from_config(mission_config: Dictionary) -> void:
	phases.clear()
	uses_v1_4_phases = false

	# -------------------------
	# v1.4 phases from mission_config["phases"]
	# -------------------------
	var raw_phases: Array = mission_config.get("phases", [])
	if raw_phases.size() > 0:
		uses_v1_4_phases = true

		for p in raw_phases:
			if typeof(p) != TYPE_DICTIONARY:
				continue
			phases.append(p.duplicate(true))

		return

	# -------------------------
	# Legacy fallback (pre-1.4):
	# Wrap top-level spawn/objectives into a single lander phase.
	# -------------------------
	var legacy_spawn: Dictionary = mission_config.get("spawn", {})
	var legacy_objectives: Dictionary = mission_config.get("objectives", {})
	var legacy_primary: Array = legacy_objectives.get("primary", [])

	var legacy_phase: Dictionary = {
		"id": "legacy_descent",
		"mode": "lander",
		"spawn": legacy_spawn,
		"objectives": legacy_primary,
		"completion": {
			# Legacy missions end their only phase on landing.
			"type": "legacy"
		}
	}

	phases.append(legacy_phase)

func arm_touchdown_for_current_phase() -> void:
	touchdown_armed = false
	touchdown_consumed_for_phase = false

	if current_phase.is_empty():
		return

	var mode: String = str(current_phase.get("mode", ""))
	if mode != "lander":
		return

	# We only want touchdown processing on descent-like lander phases.
	var pid: String = str(current_phase.get("id", ""))
	if pid.find("descent") != -1 or pid.find("landing") != -1 or pid.find("legacy") != -1:
		touchdown_armed = true
