## res://scripts/systems/world_sim_manager.gd
extends Node
class_name WorldSimManager

##
# WorldSimManager
#
# Responsibilities:
#  - Maintain long-term "campaign" state across missions (Mode 1).
#  - Advance world state on TimeManager's "world_sim" tick channel.
#  - React to mission outcomes (mission_completed / mission_failed).
#  - Provide helper APIs for mission selection and mission modifiers.
#
# Integration:
#  - Listens to EventBus.time_tick(channel_id, dt_game, dt_real)
#    -> uses "world_sim" ticks to advance state.
#  - Listens to EventBus.mission_completed / mission_failed
#    -> updates intensity, rank, unlocks, etc.
#  - Syncs _world_state into GameState.world_sim_state.
#
# Expected config file (JSON) roughly matches:
#   res://data/config/world_sim_config.json
# as discussed in the design conversation.
##

@export_category("Config")
@export var world_sim_config_path: String = "res://data/physics/world_sim.json"

@export_category("Debug")
@export var debug_logging: bool = false

# Internal config and state
var _config: Dictionary = {}
var _world_state: Dictionary = {}

# Cached config sub-blocks for convenience
var _rescue_intensity_cfg: Dictionary = {}
var _training_rank_cfg: Dictionary = {}
var _mission_pool_cfg: Dictionary = {}
var _mission_modifiers_rules: Dictionary = {}

# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------

func _ready() -> void:
	_load_config()
	_load_world_state_from_gamestate_or_initial()
	_connect_eventbus()
	
	if EventBus:
		var eb = EventBus
		if not eb.is_connected("mission_completed", Callable(self, "_on_mission_completed")):
			eb.connect("mission_completed", Callable(self, "_on_mission_completed"))

		if not eb.is_connected("mission_failed", Callable(self, "_on_mission_failed")):
			eb.connect("mission_failed", Callable(self, "_on_mission_failed"))

	if debug_logging:
		print("[WorldSimManager] Ready. Rank=", _world_state.get("training_rank", 0),
			" intensity=", _world_state.get("rescue_intensity", 0.0))



# -------------------------------------------------------------------
# EventBus integration
# -------------------------------------------------------------------

func _connect_eventbus() -> void:
	if not EventBus:
		push_warning("WorldSimManager: EventBus singleton not found; world sim will be inert.")
		return

	var eb := EventBus

	if not eb.is_connected("time_tick", Callable(self, "_on_time_tick")):
		eb.connect("time_tick", Callable(self, "_on_time_tick"))

	if not eb.is_connected("mission_completed", Callable(self, "_on_mission_completed")):
		eb.connect("mission_completed", Callable(self, "_on_mission_completed"))

	if not eb.is_connected("mission_failed", Callable(self, "_on_mission_failed")):
		eb.connect("mission_failed", Callable(self, "_on_mission_failed"))

	# NEW: react to GameState.apply_mission_result() finishing.
	if not eb.is_connected("mission_result_applied", Callable(self, "_on_mission_result_applied")):
		eb.connect("mission_result_applied", Callable(self, "_on_mission_result_applied"))

func _on_mission_result_applied(mission_id: String, success_state: String, result: Dictionary) -> void:
	if debug_logging:
		print("[WorldSimManager] mission_result_applied: ", mission_id, " success_state=", success_state)

	# High-level outcome handling (training progression vs regular missions).
	handle_mission_outcome(mission_id, result)

func _on_time_tick(channel_id: String, dt_game: float, _dt_real: float) -> void:
	# Only respond to the world-sim tick channel from TimeManager.
	if channel_id != "world_sim":
		return

	_advance_world(dt_game)

func _on_mission_completed(mission_id: String, mission_result: Dictionary) -> void:
	if debug_logging:
		print("[WorldSimManager] mission_completed: ", mission_id, " result=", mission_result)

	_apply_mission_result_effects(mission_result, true, "")


func _on_mission_failed(mission_id: String, reason: String, mission_result: Dictionary) -> void:
	if debug_logging:
		print("[WorldSimManager] mission_failed: ", mission_id, " reason=", reason, " result=", mission_result)

	_apply_mission_result_effects(mission_result, false, reason)


# -------------------------------------------------------------------
# Config loading
# -------------------------------------------------------------------

func _load_config() -> void:
	var file := FileAccess.open(world_sim_config_path, FileAccess.READ)
	if file == null:
		push_warning("[WorldSimManager] Could not open config at: " + world_sim_config_path + ". Using minimal defaults.")
		_apply_default_config()
		return

	var text: String = file.get_as_text()
	var json := JSON.new()
	var err: int = json.parse(text)
	if err != OK:
		push_warning("[WorldSimManager] JSON parse error in world sim config: " + json.get_error_message() + ". Using minimal defaults.")
		_apply_default_config()
		return

	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("[WorldSimManager] World sim config root is not a Dictionary. Using minimal defaults.")
		_apply_default_config()
		return

	_configure_from_dict(data)


func _apply_default_config() -> void:
	var default_config: Dictionary = {
		"initial_state": {
			"campaign_time_seconds": 0.0,
			"rescue_intensity": 0.0,
			"training_rank": 0,
			"unlocked_mission_ids": [],
			"cooldowns": {},
			"active_world_events": [],
			"total_training_successes": 0
		},
		"rescue_intensity_config": {
			"base_drift_per_minute": -0.01,
			"min_intensity": 0.0,
			"max_intensity": 1.0,
			"on_mission_completed": { "training": -0.05, "standard": -0.03, "hard": -0.02 },
			"on_mission_failed": { "training": 0.08, "standard": 0.10, "hard": 0.12 }
		},
		"training_rank_config": {
			"max_rank": 0,
			"ranks": []
		},
		"mission_pool": {
			"training": [],
			"standard": [],
			"special": []
		},
		"mission_modifiers_rules": {}
	}
	_configure_from_dict(default_config)


func _configure_from_dict(config: Dictionary) -> void:
	_config = config.duplicate(true)

	_rescue_intensity_cfg = _config.get("rescue_intensity_config", {})
	_training_rank_cfg = _config.get("training_rank_config", {})
	_mission_pool_cfg = _config.get("mission_pool", {})
	_mission_modifiers_rules = _config.get("mission_modifiers_rules", {})

	if debug_logging:
		print("[WorldSimManager] Configured. Keys=",
			_config.keys())


# -------------------------------------------------------------------
# World state load/save
# -------------------------------------------------------------------

func _load_world_state_from_gamestate_or_initial() -> void:
	# Try to load existing state from GameState.
	if Engine.has_singleton("GameState"):
		var gs_state = GameState.world_sim_state
		if typeof(gs_state) == TYPE_DICTIONARY and not gs_state.is_empty():
			_world_state = gs_state.duplicate(true)
		else:
			_world_state = _config.get("initial_state", {}).duplicate(true)
	else:
		_world_state = _config.get("initial_state", {}).duplicate(true)

	# Ensure required fields exist.
	if not _world_state.has("campaign_time_seconds"):
		_world_state["campaign_time_seconds"] = 0.0
	if not _world_state.has("rescue_intensity"):
		_world_state["rescue_intensity"] = 0.0
	if not _world_state.has("training_rank"):
		_world_state["training_rank"] = 0
	if not _world_state.has("unlocked_mission_ids"):
		_world_state["unlocked_mission_ids"] = []
	if not _world_state.has("cooldowns"):
		_world_state["cooldowns"] = {}
	if not _world_state.has("active_world_events"):
		_world_state["active_world_events"] = []
	if not _world_state.has("total_training_successes"):
		_world_state["total_training_successes"] = 0

	_sync_world_state_to_gamestate(false)


func _sync_world_state_to_gamestate(emit_signal: bool) -> void:
	if Engine.has_singleton("GameState"):
		GameState.world_sim_state = _world_state.duplicate(true)

	if emit_signal and Engine.has_singleton("EventBus"):
		# Only emit if the signal exists to avoid warnings.
		var eb := EventBus
		if eb.has_signal("world_state_changed"):
			eb.emit_signal("world_state_changed", _world_state.duplicate(true))

	if debug_logging and emit_signal:
		print("[WorldSimManager] World state synced: ", _world_state)


# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func get_world_state() -> Dictionary:
	return _world_state.duplicate(true)

func get_available_training_missions() -> Array:
	# Returns Array[Dictionary] of tutorial mission configs.
	# Primary source: MissionRegistry (category == "tutorial").
	# Secondary filters: unlocked/rank/unique if training pool rules exist.
	var result: Array = []

	# ---- 0) Pull all tutorial missions from registry ----
	var all_missions: Array = MissionRegistry.get_all()
	if all_missions.is_empty():
		return result

	var tutorial_catalog: Array = []
	for m in all_missions:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var category: String = String(m.get("category", "uncategorized"))
		if category == "tutorial":
			tutorial_catalog.append(m)

	if tutorial_catalog.is_empty():
		return result

	# If there are no training rules in config, just return catalog
	var training_pool: Array = _mission_pool_cfg.get("training", [])
	if training_pool.is_empty():
		# Optional: sort by difficulty so the early ones come first
		tutorial_catalog.sort_custom(func(a, b):
			return int(a.get("difficulty", 0)) < int(b.get("difficulty", 0))
		)
		return tutorial_catalog

	# ---- 1) Apply unlocked/rank/unique rules if present ----
	_auto_unlock_training_for_rank()

	var unlocked: Array = _world_state.get("unlocked_mission_ids", [])
	var completed: Array = _world_state.get("completed_mission_ids", [])
	var training_rank: int = int(_world_state.get("training_rank", 0))

	# Build a map id -> mission cfg from the registry
	var by_id: Dictionary = {}
	for m in tutorial_catalog:
		var mid: String = String(m.get("id", ""))
		if mid != "":
			by_id[mid] = m

	for entry in training_pool:
		if typeof(entry) != TYPE_DICTIONARY:
			continue

		var mission_id: String = entry.get("mission_id", "")
		if mission_id == "":
			continue

		# Must exist in registry tutorial catalog
		if not by_id.has(mission_id):
			continue

		# Must be unlocked
		if not unlocked.has(mission_id):
			continue

		# Rank window
		var min_rank: int = int(entry.get("min_rank", 0))
		var max_rank: int = int(entry.get("max_rank", 9999))
		if training_rank < min_rank:
			continue
		if training_rank > max_rank:
			continue

		# Unique filter
		var unique: bool = entry.get("unique", true)
		if unique and completed.has(mission_id):
			continue

		result.append(by_id[mission_id])

	return result


## ------------------------------------------------------------------
## Mission Board / Available Missions
## ------------------------------------------------------------------

func ensure_minimum_board_missions(min_missions: int) -> void:
	##
	# Guarantees that, AFTER TRAINING, the mission board (GameState.available_missions)
	# has at least `min_missions` missions.
	#
	# NEW BEHAVIOR:
	# - Primary source is MissionRegistry (authored missions on disk).
	# - MissionGenerator becomes fallback only if registry can't supply enough.
	# - Respects FIFO capacity as before.
	##
	var missions: Array = GameState.available_missions
	var current_count: int = missions.size()
	if current_count >= min_missions:
		return

	var to_add: int = min_missions - current_count

	# ---- 1) Try to add authored missions from MissionRegistry ----
	var authored_to_add: Array = _pick_regular_missions_from_registry(to_add)
	for m in authored_to_add:
		missions.append(m)

	# Recompute how many we still need
	current_count = missions.size()
	if current_count < min_missions:
		to_add = min_missions - current_count
	else:
		to_add = 0

	# ---- 2) Fallback to generator only if still short ----
	if to_add > 0:
		var gen: Node = MissionGenerator.new()
		if gen == null:
			push_warning("WorldSimManager.ensure_minimum_board_missions: MissionGenerator not available; cannot add fallback missions.")
		else:
			for i in range(to_add):
				var mission_cfg: Dictionary = _generate_regular_mission_for_board(gen)
				if mission_cfg.is_empty():
					break
				missions.append(mission_cfg)

	# ---- FIFO capacity stays the same ----
	var max_missions: int = GameState.max_missions
	while missions.size() > max_missions:
		missions.pop_front()

	# TODO
	print("[WorldSim] ensure_minimum_board_missions: training_complete=", GameState.training_complete,
		" before=", current_count, " after=", missions.size(), " max=", GameState.max_missions)

	GameState.available_missions = missions

func refresh_board_missions_for_hq() -> void:
	##
	# Populates GameState.available_missions appropriately for the HQ MissionBoard.
	# - During tutorials: shows eligible tutorial missions.
	# - After tutorials: ensures minimum regular missions exist.
	##

	if not GameState.training_complete:
		print("TRAINING INCOMPLETE (CORRECT)")
		var tutorials: Array = get_available_training_missions() # returns Array[Dictionary]
		print("Num Tutorials: ", tutorials.size())
		GameState.available_missions = tutorials
		if debug_logging:
			print("[WorldSimManager] HQ refresh: tutorial missions=", tutorials.size())
		return

	# Post-training normal flow
	ensure_minimum_board_missions(2)
	if debug_logging:
		print("[WorldSimManager] HQ refresh: regular missions=", GameState.available_missions.size())


func _generate_regular_mission_for_board(gen: Node) -> Dictionary:
	##
	# Asks MissionGenerator for a regular (non-training) mission suitable
	# for the board. You can enrich the context later (tags, difficulty, region).
	##
	var context: Dictionary = {
		"is_training": false,
		# Later you can add:
		# "difficulty_hint": "auto",
		# "requested_modes": [1], etc.
	}

	var mission_cfg: Dictionary = gen.generate_mission(context)
	if typeof(mission_cfg) != TYPE_DICTIONARY:
		return {}

	return mission_cfg

func build_mission_modifiers_for(mission_id: String) -> Dictionary:
	# Currently only uses rescue_intensity-based rules; mission_id is included for future use.
	var intensity: float = float(_world_state.get("rescue_intensity", 0.0))

	var modifiers: Dictionary = {}
	var env_overrides: Dictionary = {}
	var reward_mult: float = 1.0

	var from_intensity: Dictionary = _mission_modifiers_rules.get("from_rescue_intensity", {})

	if not from_intensity.is_empty():
		# Wind strength multiplier
		if from_intensity.has("wind_strength_multiplier"):
			var wcfg: Dictionary = from_intensity["wind_strength_multiplier"]
			var w_val: float = _map_intensity_to_range(intensity, wcfg)
			env_overrides["wind_strength_multiplier"] = w_val

		# Reward multiplier
		if from_intensity.has("reward_multiplier"):
			var rcfg: Dictionary = from_intensity["reward_multiplier"]
			reward_mult = _map_intensity_to_range(intensity, rcfg)

	if not env_overrides.is_empty():
		modifiers["environment_overrides"] = env_overrides

	modifiers["reward_multiplier"] = reward_mult
	modifiers["mission_id"] = mission_id

	return modifiers


# -------------------------------------------------------------------
# Core world advancement
# -------------------------------------------------------------------

func _advance_world(dt_game: float) -> void:
	# 1) Campaign time
	var current_time: float = float(_world_state.get("campaign_time_seconds", 0.0))
	current_time += dt_game
	_world_state["campaign_time_seconds"] = current_time

	# 2) Rescue intensity drift
	_update_rescue_intensity_drift(dt_game)

	# 3) Cooldowns and world events
	_update_cooldowns(dt_game)
	_update_world_events(dt_game)

	# 4) Rank + unlocks (in case thresholds depend on cumulative stats)
	_update_training_rank_and_unlocks()

	# 5) Push back to GameState
	_sync_world_state_to_gamestate(true)


func _update_rescue_intensity_drift(dt_game: float) -> void:
	if _rescue_intensity_cfg.is_empty():
		return

	var base_drift_per_minute: float = float(_rescue_intensity_cfg.get("base_drift_per_minute", 0.0))
	var min_intensity: float = float(_rescue_intensity_cfg.get("min_intensity", 0.0))
	var max_intensity: float = float(_rescue_intensity_cfg.get("max_intensity", 1.0))

	var intensity: float = float(_world_state.get("rescue_intensity", 0.0))

	# Convert dt from seconds to minutes.
	var dt_minutes: float = dt_game / 60.0
	var drift: float = base_drift_per_minute * dt_minutes

	intensity += drift

	if intensity < min_intensity:
		intensity = min_intensity
	if intensity > max_intensity:
		intensity = max_intensity

	_world_state["rescue_intensity"] = intensity


func _update_cooldowns(dt_game: float) -> void:
	var cds: Dictionary = _world_state.get("cooldowns", {})
	if cds.is_empty():
		return

	var keys_to_remove: Array = []

	for key in cds.keys():
		var cd: Dictionary = cds.get(key, {})
		if not cd.has("time_remaining"):
			continue

		var t: float = float(cd["time_remaining"])
		t -= dt_game
		cd["time_remaining"] = t
		cds[key] = cd

		if t <= 0.0:
			keys_to_remove.append(key)

	for k in keys_to_remove:
		cds.erase(k)

	_world_state["cooldowns"] = cds


func _update_world_events(dt_game: float) -> void:
	var events: Array = _world_state.get("active_world_events", [])
	if events.is_empty():
		return

	for i in range(events.size()):
		var e = events[i]
		if typeof(e) != TYPE_DICTIONARY:
			continue

		var state: String = e.get("state", "pending")
		if state == "expired":
			continue

		if e.has("time_remaining"):
			var t: float = float(e["time_remaining"])
			t -= dt_game
			e["time_remaining"] = t

			if t <= 0.0:
				e["state"] = "expired"

		events[i] = e

	_world_state["active_world_events"] = events


func _update_training_rank_and_unlocks() -> void:
	if _training_rank_cfg.is_empty():
		return

	var max_rank_cfg: int = int(_training_rank_cfg.get("max_rank", 0))
	var ranks_arr: Array = _training_rank_cfg.get("ranks", [])

	var total_successes: int = int(_world_state.get("total_training_successes", 0))
	var current_rank: int = int(_world_state.get("training_rank", 0))

	var new_rank: int = current_rank

	for r_cfg in ranks_arr:
		if typeof(r_cfg) != TYPE_DICTIONARY:
			continue

		var rank_val: int = int(r_cfg.get("rank", 0))
		var required_successes: int = int(r_cfg.get("required_successes", 0))

		if rank_val > max_rank_cfg:
			continue

		if total_successes >= required_successes and rank_val > new_rank:
			new_rank = rank_val

	if new_rank > max_rank_cfg:
		new_rank = max_rank_cfg

	if new_rank != current_rank:
		_world_state["training_rank"] = new_rank
		_apply_rank_unlocks(new_rank, ranks_arr)

		if debug_logging:
			print("[WorldSimManager] Rank changed: ", current_rank, " -> ", new_rank)


func _apply_rank_unlocks(new_rank: int, ranks_arr: Array) -> void:
	var unlocked: Array = _world_state.get("unlocked_mission_ids", [])

	for r_cfg in ranks_arr:
		if typeof(r_cfg) != TYPE_DICTIONARY:
			continue

		var rank_val: int = int(r_cfg.get("rank", 0))
		if rank_val > new_rank:
			continue

		var unlocks: Array = r_cfg.get("unlocks_mission_ids", [])
		for mission_id in unlocks:
			if typeof(mission_id) != TYPE_STRING:
				continue
			if not unlocked.has(mission_id):
				unlocked.append(mission_id)

	_world_state["unlocked_mission_ids"] = unlocked


# -------------------------------------------------------------------
# Mission outcome handling
# -------------------------------------------------------------------

func _apply_mission_result_effects(result: Dictionary, success: bool, _fail_reason: String) -> void:
	# 1) Intensity adjustment
	_adjust_rescue_intensity_for_result(result, success)

	# 2) Training successes -> rank
	var is_training: bool = bool(result.get("is_training", false))
	if success and is_training:
		var total_successes: int = int(_world_state.get("total_training_successes", 0))
		total_successes += 1
		_world_state["total_training_successes"] = total_successes

	_update_training_rank_and_unlocks()

	# 3) Sync back out
	_sync_world_state_to_gamestate(true)


func _adjust_rescue_intensity_for_result(result: Dictionary, success: bool) -> void:
	if _rescue_intensity_cfg.is_empty():
		return

	var min_intensity: float = float(_rescue_intensity_cfg.get("min_intensity", 0.0))
	var max_intensity: float = float(_rescue_intensity_cfg.get("max_intensity", 1.0))

	var intensity: float = float(_world_state.get("rescue_intensity", 0.0))

	var mission_category: String = _classify_mission_for_intensity(result)

	var deltas_key: String = "on_mission_completed"
	if not success:
		deltas_key = "on_mission_failed"

	var deltas: Dictionary = _rescue_intensity_cfg.get(deltas_key, {})
	var delta_val: float = float(deltas.get(mission_category, 0.0))

	intensity += delta_val

	if intensity < min_intensity:
		intensity = min_intensity
	if intensity > max_intensity:
		intensity = max_intensity

	_world_state["rescue_intensity"] = intensity


func _classify_mission_for_intensity(result: Dictionary) -> String:
	# Very simple classification:
	# - if is_training: "training"
	# - else if tier >= 2: "hard"
	# - else: "standard"
	var is_training: bool = bool(result.get("is_training", false))
	if is_training:
		return "training"

	var tier: int = int(result.get("tier", 0))
	if tier >= 2:
		return "hard"

	return "standard"


# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

func _auto_unlock_training_for_rank() -> void:
	##
	# Ensures tutorial missions marked auto_unlock=true in world_sim.json
	# are added to _world_state.unlocked_mission_ids when the player's
	# training_rank enters their [min_rank, max_rank] window.
	#
	# Depends on:
	#   _world_state["training_rank"]
	#   _world_state["unlocked_mission_ids"]
	#   _mission_pool_cfg["training"]
	##
	if typeof(_world_state) != TYPE_DICTIONARY:
		return

	var training_rank: int = int(_world_state.get("training_rank", 0))
	var unlocked: Array = _world_state.get("unlocked_mission_ids", [])

	var training_pool: Array = _mission_pool_cfg.get("training", [])
	for entry in training_pool:
		if typeof(entry) != TYPE_DICTIONARY:
			continue

		var auto_unlock: bool = entry.get("auto_unlock", false)
		if not auto_unlock:
			continue

		var min_rank: int = int(entry.get("min_rank", 0))
		var max_rank: int = int(entry.get("max_rank", 9999))

		if training_rank < min_rank:
			continue
		if training_rank > max_rank:
			continue

		var mission_id: String = entry.get("mission_id", "")
		if mission_id == "":
			continue

		if not unlocked.has(mission_id):
			unlocked.append(mission_id)

	_world_state["unlocked_mission_ids"] = unlocked


func _map_intensity_to_range(intensity: float, cfg: Dictionary) -> float:
	var min_intensity: float = float(cfg.get("min_intensity", 0.0))
	var max_intensity: float = float(cfg.get("max_intensity", 1.0))
	var min_value: float = float(cfg.get("min_value", 1.0))
	var max_value: float = float(cfg.get("max_value", 1.0))

	# Clamp intensity into [min_intensity, max_intensity]
	var clamped: float = intensity
	if clamped < min_intensity:
		clamped = min_intensity
	if clamped > max_intensity:
		clamped = max_intensity

	var t: float = 0.0
	var range_intensity: float = max_intensity - min_intensity
	if range_intensity > 0.0:
		t = (clamped - min_intensity) / range_intensity

	# Linear interpolation between min_value and max_value.
	var value: float = lerp(min_value, max_value, t)
	return value

func choose_training_mission() -> Dictionary:
	##
	# Returns a single training mission_id chosen from the currently
	# available training missions, as filtered by rank + unlocks.
	# Returns "" if none are available (caller should handle that).
	##
	var pool: Array = get_available_training_missions()
	if pool.is_empty():
		if debug_logging:
			print("[WorldSimManager] No available tutorial missions to choose from.")
		return {}

	var index: int = randi() % pool.size()
	var mission_cfg: Dictionary = pool[index]

	if debug_logging:
		print("[WorldSimManager] Chose tutorial mission: ", mission_cfg.get("id", "UNKNOWN"))

	return mission_cfg


func get_next_training_mission_id() -> String:
	##
	# Returns the correct training mission ID based on GameState.training_progress
	# 0 → mission 1
	# 1 → mission 2
	# 2 → mission 3
	# 3 → training complete
	##
	var tp := GameState.training_progress

	match tp:
		0: return "training_mission_01"
		1: return "training_mission_02"
		2: return "training_mission_03"
		_: 
			# Training is done
			return ""

func handle_mission_outcome(mission_id: String, result: Dictionary) -> void:
	##
	# Handles training progression and regular mission updates
	##
	if not result.has("success_state"):
		return

	var success_state: String = result["success_state"]

	# TRAINING MISSIONS
	if mission_id.begins_with("training_mission_"):
		_process_training_outcome(mission_id, success_state)
		return

	# REGULAR MISSIONS (future — e.g., rep, mission rotation, world events)
	_process_regular_mission_outcome(mission_id, result)

func _process_regular_mission_outcome(mission_id: String, result: Dictionary) -> void:
	# Placeholder for future world-state logic (reputation, arcs, events, etc.).
	# For now, we only enforce the mission-board minimum after each regular mission.
	if debug_logging:
		print("[WorldSimManager] _process_regular_mission_outcome: ", mission_id)

	# After any regular mission, make sure the board has at least 2 missions.
	ensure_minimum_board_missions(2)

func _process_training_outcome(mission_id: String, success_state: String) -> void:
	if success_state != "success":
		return				# Retry required. No progression.

	# Successful completion → advance
	GameState.training_progress += 1

	# If training missions are done:
	if GameState.training_progress >= 3:
		GameState.training_progress = 3
		GameState.training_complete = true

		ensure_minimum_board_missions(2) 		# Ensure the mission board starts with 2+ missions.

func _pick_regular_missions_from_registry(count: int) -> Array:
	##
	# Picks up to `count` NON-tutorial missions from MissionRegistry
	# that meet reputation requirements and are not already on the board.
	# Returns Array[Dictionary].
	##
	var out: Array = []

	if not Engine.has_singleton("MissionRegistry"):
		push_warning("WorldSimManager: MissionRegistry singleton not found; skipping authored mission pick.")
		return out

	var all_missions: Array = MissionRegistry.get_all()
	if all_missions.is_empty():
		return out

	# Already-available ids to avoid duplicates
	var existing_ids: Array = []
	for m in GameState.available_missions:
		if typeof(m) == TYPE_DICTIONARY:
			var mid: String = m.get("id", "")
			if mid != "":
				existing_ids.append(mid)

	# Reputation (robust access)
	var rep: int = 0
	if GameState.has_method("get_reputation"):
		rep = int(GameState.get_reputation())
	elif GameState.has("reputation"):
		rep = int(GameState.reputation)
	else:
		rep = 0

	# Filter candidates
	var candidates: Array = []
	for m in all_missions:
		if typeof(m) != TYPE_DICTIONARY:
			continue

		var mid: String = m.get("id", "")
		if mid == "":
			continue

		if existing_ids.has(mid):
			continue

		# Exclude tutorial missions based on category
		var category: String = String(m.get("category", "uncategorized"))
		if category == "tutorial":
			continue

		# Reputation gate
		var req_rep: int = 0
		if m.has("reputation_required"):
			req_rep = int(m["reputation_required"])

		if rep < req_rep:
			continue

		# Expiration gate (optional)
		if _mission_is_expired(m):
			continue

		candidates.append(m)

	# Randomly sample without replacement
	while candidates.size() > 0 and out.size() < count:
		var idx: int = randi() % candidates.size()
		var picked: Dictionary = candidates[idx]
		candidates.remove_at(idx)

		_stamp_first_seen_if_needed(picked)
		out.append(picked)

	return out



func _mission_is_expired(mission_cfg: Dictionary) -> bool:
	# If you haven't implemented expiration yet, this safely returns false.
	if not mission_cfg.has("expires_in_days"):
		return false

	var expires_in = mission_cfg.get("expires_in_days", null)
	if expires_in == null:
		return false

	var first_seen_day: int = -1
	if mission_cfg.has("first_seen_at_day"):
		first_seen_day = int(mission_cfg["first_seen_at_day"])
	elif GameState.has("mission_first_seen_day_by_id"):
		var map: Dictionary = GameState.mission_first_seen_day_by_id
		var mid: String = mission_cfg.get("id", "")
		if mid != "" and map.has(mid):
			first_seen_day = int(map[mid])

	if first_seen_day < 0:
		return false

	var now_day: int = 0
	if GameState.has("day"):
		now_day = int(GameState.day)

	var deadline: int = first_seen_day + int(expires_in)
	if now_day > deadline:
		return true

	return false


func _stamp_first_seen_if_needed(mission_cfg: Dictionary) -> void:
	# Best-effort stamping for expiration/new-badge later.
	var mid: String = mission_cfg.get("id", "")
	if mid == "":
		return

	# Stamp on mission dict
	if not mission_cfg.has("first_seen_at_day"):
		var now_day: int = 0
		if GameState.has("day"):
			now_day = int(GameState.day)
		mission_cfg["first_seen_at_day"] = now_day

	# Also stamp in GameState map if it exists
	if GameState.has("mission_first_seen_day_by_id"):
		var map: Dictionary = GameState.mission_first_seen_day_by_id
		if not map.has(mid):
			map[mid] = mission_cfg["first_seen_at_day"]
		GameState.mission_first_seen_day_by_id = map
