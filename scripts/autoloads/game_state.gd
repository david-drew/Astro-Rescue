## res://scripts/core/game_state.gd
extends Node
#class_name GameState

##
# GameState
#
# Runtime store for:
#  - Player career profile (reputation, funds, unlocks, etc.)
#  - Current mission configuration
#  - Current mission result
#
# Expected to be autoloaded as "GameState".
#
# Collaborators:
#  - EventBus (signals: reputation_changed, funds_changed, career_terminated, profile_loaded, profile_reset, mission_result_applied)
#  - SaveSystem (for load/save)
#  - MissionGenerator (reads player_profile when generating missions)
##

# -------------------------------------------------------------------
# Player Profile
# -------------------------------------------------------------------

var player_profile: Dictionary = {}
var world_sim_state: Dictionary = {}
var current_mission_id:String = ""
var landing_zone_id:String = ""

# Current mission (set by CareerHub / MissionBriefing / MissionGenerator)
var current_mission_config: Dictionary = {}
var current_mission_result: Dictionary = {}
var last_mission_result: Dictionary = {}
var _mission_counter: int = 0					# Used to generate simple mission counters if needed
var training_progress: int = 0					# Training mission progression, 0–3
var training_complete: bool = false				# Whether the player has unlocked HQ / Mission Board

# Mission Board (available missions after training)
var available_missions: Array = []   # Array[Dictionary] of mission_config
var max_missions: int = 10           # FIFO capacity

var available_crew_candidates: Array = []
var store_inventory: Array = []

var player:Node2D = null
var vehicles:Dictionary = {}


func _ready() -> void:
	# Initialize with a default profile so we always have a safe baseline.
	player_profile = _create_default_profile()
	
	var player_node:Node2D = get_node_or_null("/root/Game/World/Player")
	var eva:Array = get_tree().get_nodes_in_group("eva")
	var lander:Array = get_tree().get_nodes_in_group("lander")
	var buggies:Array = get_tree().get_nodes_in_group("buggy")
	
	player = player_node
	vehicles.eva = eva[0]
	vehicles.lander = lander[0]
	vehicles.buggy = buggies[0]

# -------------------------------------------------------------------
# Profile lifecycle
# -------------------------------------------------------------------

func _create_default_profile() -> Dictionary:
	##
	# Creates a brand-new career profile.
	# You can adjust starting funds / defaults here.
	##
	return {
		"reputation": 0,
		"funds": 0,
		"unlocked_lander_ids": [],
		"unlocked_crew_ids": [],
		"unlocked_mission_tags": [],
		"total_crashes": 0,
		"completed_missions": 0,
		"failed_missions": 0,
		"career_status": "active"
	}


func reset_profile() -> void:
        ##
        # Resets the current profile to default values (e.g., new career).
        ##
        player_profile = _create_default_profile()
        _mission_counter = 0
        current_mission_id = ""
        landing_zone_id = ""
        current_mission_config.clear()
        current_mission_result.clear()
        last_mission_result.clear()
        available_missions.clear()
        training_progress = 0
        training_complete = false

        if Engine.has_singleton("EventBus"):
                EventBus.emit_signal("profile_reset", player_profile)


func load_profile_from_save(profile_data: Dictionary) -> void:
	##
	# Called by SaveSystem after reading a save file.
	# You can pass the raw profile saved previously by SaveSystem.
	##
	if profile_data.is_empty():
		player_profile = _create_default_profile()
	else:
		player_profile = profile_data.duplicate(true)

	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("profile_loaded", player_profile)


func get_profile_copy() -> Dictionary:
	return player_profile.duplicate(true)


# -------------------------------------------------------------------
# Reputation & Funds helpers
# -------------------------------------------------------------------

func change_reputation(delta: int) -> void:
	var old_rep: int = int(player_profile.get("reputation", 0))
	var new_rep: int = old_rep + delta
	player_profile["reputation"] = new_rep

	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("reputation_changed", new_rep, delta)

	_check_career_termination_for_reputation()


func set_reputation(value: int) -> void:
	var old_rep: int = int(player_profile.get("reputation", 0))
	var delta: int = value - old_rep
	player_profile["reputation"] = value

	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("reputation_changed", value, delta)

	_check_career_termination_for_reputation()


func change_funds(delta: int) -> void:
	var old_funds: int = int(player_profile.get("funds", 0))
	var new_funds: int = old_funds + delta
	player_profile["funds"] = new_funds

	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("funds_changed", new_funds, delta)


func set_funds(value: int) -> void:
	var old_funds: int = int(player_profile.get("funds", 0))
	var delta: int = value - old_funds
	player_profile["funds"] = value

	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("funds_changed", value, delta)


func _check_career_termination_for_reputation() -> void:
	##
	# End career if reputation falls below threshold.
	# Design doc: reputation <= -20 → career termination.
	##
	var rep: int = int(player_profile.get("reputation", 0))
	if rep <= -20:
		_set_career_status("terminated", "reputation_below_threshold")


func _set_career_status(new_status: String, reason: String = "") -> void:
	var old_status: String = str(player_profile.get("career_status", "active"))
	if old_status == new_status:
		return

	player_profile["career_status"] = new_status

	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("career_status_changed", new_status, reason)
		if new_status == "terminated":
			EventBus.emit_signal("career_terminated", reason)


# -------------------------------------------------------------------
# Unlock helpers (landers, crew, mission tags)
# -------------------------------------------------------------------

func unlock_lander(lander_id: String) -> void:
	var arr: Array = player_profile.get("unlocked_lander_ids", [])
	if not arr.has(lander_id):
		arr.append(lander_id)
		player_profile["unlocked_lander_ids"] = arr
		if Engine.has_singleton("EventBus"):
			EventBus.emit_signal("lander_unlocked", lander_id)


func unlock_crew(crew_id: String) -> void:
	var arr: Array = player_profile.get("unlocked_crew_ids", [])
	if not arr.has(crew_id):
		arr.append(crew_id)
		player_profile["unlocked_crew_ids"] = arr
		if Engine.has_singleton("EventBus"):
			EventBus.emit_signal("crew_unlocked", crew_id)


func unlock_mission_tag(tag: String) -> void:
	var arr: Array = player_profile.get("unlocked_mission_tags", [])
	if not arr.has(tag):
		arr.append(tag)
		player_profile["unlocked_mission_tags"] = arr
		if Engine.has_singleton("EventBus"):
			EventBus.emit_signal("mission_tag_unlocked", tag)


# -------------------------------------------------------------------
# Mission tracking
# -------------------------------------------------------------------

func set_current_mission_config(config: Dictionary) -> void:
	current_mission_config = config.duplicate(true)
	_mission_counter += 1

	if Engine.has_singleton("EventBus"):
		var mission_id: String = current_mission_config.get("id", "")
		EventBus.emit_signal("mission_config_set", mission_id, current_mission_config)


func clear_current_mission() -> void:
	current_mission_config.clear()
	current_mission_result.clear()

	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("mission_cleared")


# -------------------------------------------------------------------
# Applying mission results
# -------------------------------------------------------------------

func _on_mission_completed(result:Dictionary):
	last_mission_result = result

# TODO: THIS IS DEPRECATED and a DUPLICATE, CLEAN UP EVERYTHING USING THIS
# MissionController Handles This Now
func apply_mission_result(result: Dictionary) -> void:
	##
	# Applies mission outcome to the player profile, based on the
	# current_mission_config's rewards and the result payload.
	#
	# Expected result keys (you can evolve this when MissionController is written):
	#   - mission_id: String
	#   - success_state: String = "success" / "partial" / "fail"
	#   - crashes: int
	#   - player_died: bool
	#   - (optionally: objective breakdown, etc.)
	##
	if current_mission_config.is_empty():
		push_warning("GameState.apply_mission_result called but current_mission_config is empty.")
		return

	current_mission_result = result.duplicate(true)

	var mission_id: String = result.get("mission_id", current_mission_config.get("id", ""))
	var success_state: String = result.get("success_state", "fail")
	var crashes: int = int(result.get("crashes", 0))
	var player_died: bool = bool(result.get("player_died", false))

	# Update crash counters and mission counts.
	if crashes > 0:
		var total_crashes: int = int(player_profile.get("total_crashes", 0))
		total_crashes += crashes
		player_profile["total_crashes"] = total_crashes

	if success_state == "success":
		var completed: int = int(player_profile.get("completed_missions", 0))
		completed += 1
		player_profile["completed_missions"] = completed
	elif success_state == "partial":
		# Partial still counts as a completed attempt; up to you if it goes in completed or failed.
		var completed_p: int = int(player_profile.get("completed_missions", 0))
		completed_p += 1
		player_profile["completed_missions"] = completed_p
	else:
		var failed: int = int(player_profile.get("failed_missions", 0))
		failed += 1
		player_profile["failed_missions"] = failed

	# Resolve rewards
	_apply_mission_rewards(success_state)

	# Player death → career termination
	if player_died:
		_set_career_status("terminated", "player_died")

	# Save profile via SaveSystem (if present)
	SaveSystem.save_profile(player_profile)

	# Notify listeners
	EventBus.emit_signal("mission_result_applied", mission_id, success_state, current_mission_result)


func _apply_mission_rewards(success_state: String) -> void:
	var rewards: Dictionary = current_mission_config.get("rewards", {})

	var rep_rewards: Dictionary = rewards.get("reputation", {})
	var funds_rewards: Dictionary = rewards.get("funds", {})

	var rep_delta: int = 0
	var funds_delta: int = 0

	match success_state:
		"success":
			rep_delta = int(rep_rewards.get("on_success", 0))
			funds_delta = int(funds_rewards.get("on_success", 0))
		"partial":
			rep_delta = int(rep_rewards.get("on_partial", 0))
			funds_delta = int(funds_rewards.get("on_partial", 0))
		"fail":
			rep_delta = int(rep_rewards.get("on_fail", 0))
			funds_delta = int(funds_rewards.get("on_fail", 0))
		_:
			# Unknown state → treat as failure
			rep_delta = int(rep_rewards.get("on_fail", 0))
			funds_delta = int(funds_rewards.get("on_fail", 0))

	if rep_delta != 0:
		change_reputation(rep_delta)
	if funds_delta != 0:
		change_funds(funds_delta)

	# Unlock tags
	var unlock_tags: Array = current_mission_config.get("rewards", {}).get("unlock_tags", [])
	for tag in unlock_tags:
		unlock_mission_tag(tag)


# -------------------------------------------------------------------
# Convenience: check if career is active
# -------------------------------------------------------------------

func is_career_active() -> bool:
	return player_profile.get("career_status", "active") == "active"


func is_career_terminated() -> bool:
	return player_profile.get("career_status", "active") == "terminated"
