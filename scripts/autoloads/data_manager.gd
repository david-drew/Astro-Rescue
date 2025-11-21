## res://scripts/core/data_manager.gd
extends Node
#class_name DataManager

##
# DataManager
#
# Centralized loader and accessor for all game data:
# - Biomes
# - Landers
# - Crew
# - Mission Archetypes
# - Reward Profiles
# - Crash Profiles
# - Physics Presets
# - Wind Profiles
# - Objective Templates
#
# Intended usage:
#   - Autoload as "DataManager"
#   - Call DataManager.get_*() from game systems
#
# This script assumes the following default JSON files:
#   res://data/biomes/biomes.json
#   res://data/landers/landers.json
#   res://data/crew/crew.json
#   res://data/missions/mission_archetypes.json
#   res://data/missions/reward_profiles.json
#   res://data/missions/crash_profiles.json
#   res://data/physics/physics_presets.json
#   res://data/physics/wind_profiles.json
#   res://data/objectives/objective_templates.json
##

# -------------------------------------------------------------------
# File paths (adjust if your project uses different locations)
# -------------------------------------------------------------------

const PATH_BIOMES := "res://data/biomes/biomes.json"
const PATH_LANDERS := "res://data/landers/landers.json"
const PATH_CREW := "res://data/crew/crew.json"
const PATH_MISSION_ARCHETYPES := "res://data/missions/mission_archetypes.json"
const PATH_REWARD_PROFILES := "res://data/missions/reward_profiles.json"
const PATH_CRASH_PROFILES := "res://data/missions/crash_profiles.json"
const PATH_PHYSICS_PRESETS := "res://data/physics/physics_presets.json"
const PATH_WIND_PROFILES := "res://data/physics/wind_profiles.json"
const PATH_OBJECTIVE_TEMPLATES := "res://data/objectives/objective_templates.json"

# -------------------------------------------------------------------
# Internal storage
# -------------------------------------------------------------------

var _biomes: Array = []
var _biomes_by_id: Dictionary = {}

var _landers: Array = []
var _landers_by_id: Dictionary = {}

var _crew: Array = []
var _crew_by_id: Dictionary = {}

var _mission_archetypes: Array = []
var _mission_archetypes_by_id: Dictionary = {}

var _reward_profiles_by_id: Dictionary = {}
var _crash_profiles_by_id: Dictionary = {}

var _physics_presets_by_id: Dictionary = {}
var _wind_profiles_by_id: Dictionary = {}

# Objective templates are split by category ("primary", "bonus")
var _objective_templates_primary_by_id: Dictionary = {}
var _objective_templates_bonus_by_id: Dictionary = {}


# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------

func _ready() -> void:
	# Load all data on startup
	reload_all()


func reload_all() -> void:
	##
	# Reloads all known JSON data files.
	##
	_load_biomes()
	_load_landers()
	_load_crew()
	_load_mission_archetypes()
	_load_reward_profiles()
	_load_crash_profiles()
	_load_physics_presets()
	_load_wind_profiles()
	_load_objective_templates()


# -------------------------------------------------------------------
# Biomes
# -------------------------------------------------------------------

func _load_biomes() -> void:
	_biomes.clear()
	_biomes_by_id.clear()

	var root:Variant = _load_json_file(PATH_BIOMES)
	if typeof(root) != TYPE_DICTIONARY:
		push_warning("DataManager: Biomes JSON root is not a Dictionary.")
		return

	var biomes_array: Array = root.get("biomes", [])
	for biome in biomes_array:
		if typeof(biome) != TYPE_DICTIONARY:
			continue
		var id: String = biome.get("id", "")
		if id == "":
			continue
		_biomes.append(biome)
		_biomes_by_id[id] = biome


func get_biomes() -> Array:
	return _biomes


func get_biome(id: String) -> Dictionary:
	if _biomes_by_id.has(id):
		return _biomes_by_id[id]
	return {}


# -------------------------------------------------------------------
# Landers
# -------------------------------------------------------------------

func _load_landers() -> void:
	_landers.clear()
	_landers_by_id.clear()

	var root:Variant = _load_json_file(PATH_LANDERS)
	if typeof(root) != TYPE_DICTIONARY:
		push_warning("DataManager: Landers JSON root is not a Dictionary.")
		return

	var landers_array: Array = root.get("landers", [])
	for lander in landers_array:
		if typeof(lander) != TYPE_DICTIONARY:
			continue
		var id: String = lander.get("id", "")
		if id == "":
			continue
		_landers.append(lander)
		_landers_by_id[id] = lander


func get_landers() -> Array:
	return _landers


func get_lander(id: String) -> Dictionary:
	if _landers_by_id.has(id):
		return _landers_by_id[id]
	return {}


# -------------------------------------------------------------------
# Crew
# -------------------------------------------------------------------

func _load_crew() -> void:
	_crew.clear()
	_crew_by_id.clear()

	var root:Variant = _load_json_file(PATH_CREW)
	if typeof(root) != TYPE_DICTIONARY:
		push_warning("DataManager: Crew JSON root is not a Dictionary.")
		return

	var crew_array: Array = root.get("crew", [])
	for c in crew_array:
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var id: String = c.get("id", "")
		if id == "":
			continue
		_crew.append(c)
		_crew_by_id[id] = c


func get_crew_list() -> Array:
	return _crew


func get_crew(id: String) -> Dictionary:
	if _crew_by_id.has(id):
		return _crew_by_id[id]
	return {}


# -------------------------------------------------------------------
# Mission Archetypes
# -------------------------------------------------------------------

func _load_mission_archetypes() -> void:
	_mission_archetypes.clear()
	_mission_archetypes_by_id.clear()

	var root:Variant = _load_json_file(PATH_MISSION_ARCHETYPES)
	if typeof(root) != TYPE_DICTIONARY:
		push_warning("DataManager: Mission archetypes JSON root is not a Dictionary.")
		return

	var arcs: Array = root.get("archetypes", [])
	for a in arcs:
		if typeof(a) != TYPE_DICTIONARY:
			continue
		var id: String = a.get("id", "")
		if id == "":
			continue
		_mission_archetypes.append(a)
		_mission_archetypes_by_id[id] = a


func get_mission_archetypes() -> Array:
	return _mission_archetypes


func get_mission_archetype(id: String) -> Dictionary:
	if _mission_archetypes_by_id.has(id):
		return _mission_archetypes_by_id[id]
	return {}


# -------------------------------------------------------------------
# Reward Profiles
# -------------------------------------------------------------------

func _load_reward_profiles() -> void:
	_reward_profiles_by_id.clear()

	var root:Variant = _load_json_file(PATH_REWARD_PROFILES)
	if typeof(root) != TYPE_DICTIONARY:
		push_warning("DataManager: Reward profiles JSON root is not a Dictionary.")
		return

	# Allow either:
	#   { "reward_profiles": { "id": {...} } }
	# or:
	#   { "reward_profiles": [ { "id": "...", ... }, ... ] }
	var raw_profiles:Variant = root.get("reward_profiles", {})

	if typeof(raw_profiles) == TYPE_DICTIONARY:
		for id in raw_profiles.keys():
			var prof = raw_profiles[id]
			if typeof(prof) == TYPE_DICTIONARY:
				_reward_profiles_by_id[id] = prof
	elif typeof(raw_profiles) == TYPE_ARRAY:
		for p in raw_profiles:
			if typeof(p) != TYPE_DICTIONARY:
				continue
			var pid: String = p.get("id", "")
			if pid == "":
				continue
			_reward_profiles_by_id[pid] = p
	else:
		push_warning("DataManager: reward_profiles field is neither Dictionary nor Array.")


func get_reward_profile(id: String) -> Dictionary:
	if _reward_profiles_by_id.has(id):
		return _reward_profiles_by_id[id]
	return {}


# -------------------------------------------------------------------
# Crash Profiles
# -------------------------------------------------------------------

func _load_crash_profiles() -> void:
	_crash_profiles_by_id.clear()

	var root:Variant = _load_json_file(PATH_CRASH_PROFILES)
	if typeof(root) != TYPE_DICTIONARY:
		push_warning("DataManager: Crash profiles JSON root is not a Dictionary.")
		return

	var raw_profiles:Variant = root.get("crash_profiles", {})

	if typeof(raw_profiles) == TYPE_DICTIONARY:
		for id in raw_profiles.keys():
			var prof = raw_profiles[id]
			if typeof(prof) == TYPE_DICTIONARY:
				_crash_profiles_by_id[id] = prof
	elif typeof(raw_profiles) == TYPE_ARRAY:
		for p in raw_profiles:
			if typeof(p) != TYPE_DICTIONARY:
				continue
			var pid: String = p.get("id", "")
			if pid == "":
				continue
			_crash_profiles_by_id[pid] = p
	else:
		push_warning("DataManager: crash_profiles field is neither Dictionary nor Array.")


func get_crash_profile(id: String) -> Dictionary:
	if _crash_profiles_by_id.has(id):
		return _crash_profiles_by_id[id]
	return {}


# -------------------------------------------------------------------
# Physics Presets
# -------------------------------------------------------------------

func _load_physics_presets() -> void:
	_physics_presets_by_id.clear()

	var root:Variant = _load_json_file(PATH_PHYSICS_PRESETS)
	if typeof(root) != TYPE_DICTIONARY:
		push_warning("DataManager: Physics presets JSON root is not a Dictionary.")
		return

	var raw:Variant = root.get("physics_presets", {})

	if typeof(raw) == TYPE_DICTIONARY:
		for id in raw.keys():
			var p = raw[id]
			if typeof(p) == TYPE_DICTIONARY:
				_physics_presets_by_id[id] = p
	elif typeof(raw) == TYPE_ARRAY:
		for p in raw:
			if typeof(p) != TYPE_DICTIONARY:
				continue
			var pid: String = p.get("id", "")
			if pid == "":
				continue
			_physics_presets_by_id[pid] = p
	else:
		push_warning("DataManager: physics_presets field is neither Dictionary nor Array.")


func get_physics_preset(id: String) -> Dictionary:
	if _physics_presets_by_id.has(id):
		return _physics_presets_by_id[id]
	return {}


# -------------------------------------------------------------------
# Wind Profiles
# -------------------------------------------------------------------

func _load_wind_profiles() -> void:
	_wind_profiles_by_id.clear()

	var root:Variant = _load_json_file(PATH_WIND_PROFILES)
	if typeof(root) != TYPE_DICTIONARY:
		push_warning("DataManager: Wind profiles JSON root is not a Dictionary.")
		return

	var raw:Variant = root.get("wind_profiles", {})

	if typeof(raw) == TYPE_DICTIONARY:
		for id in raw.keys():
			var wp = raw[id]
			if typeof(wp) == TYPE_DICTIONARY:
				_wind_profiles_by_id[id] = wp
	elif typeof(raw) == TYPE_ARRAY:
		for wp in raw:
			if typeof(wp) != TYPE_DICTIONARY:
				continue
			var pid: String = wp.get("id", "")
			if pid == "":
				continue
			_wind_profiles_by_id[pid] = wp
	else:
		push_warning("DataManager: wind_profiles field is neither Dictionary nor Array.")


func get_wind_profile(id: String) -> Dictionary:
	if _wind_profiles_by_id.has(id):
		return _wind_profiles_by_id[id]
	return {}


# -------------------------------------------------------------------
# Objective Templates
# -------------------------------------------------------------------

func _load_objective_templates() -> void:
	_objective_templates_primary_by_id.clear()
	_objective_templates_bonus_by_id.clear()

	var root:Variant = _load_json_file(PATH_OBJECTIVE_TEMPLATES)
	if typeof(root) != TYPE_DICTIONARY:
		push_warning("DataManager: Objective templates JSON root is not a Dictionary.")
		return

	# Expected shape (from design doc):
	# {
	#   "primary": { "<id>": { ... }, ... },
	#   "bonus":   { "<id>": { ... }, ... }
	# }
	#
	# Also tolerates:
	#   "primary": [ { "id": "...", ... }, ... ]
	var prim:Variant = root.get("primary", {})
	var bonus:Variant = root.get("bonus", {})

	# Primary
	if typeof(prim) == TYPE_DICTIONARY:
		for id in prim.keys():
			var tmpl = prim[id]
			if typeof(tmpl) == TYPE_DICTIONARY:
				_objective_templates_primary_by_id[id] = tmpl
	elif typeof(prim) == TYPE_ARRAY:
		for t in prim:
			if typeof(t) != TYPE_DICTIONARY:
				continue
			var tid: String = t.get("id", "")
			if tid == "":
				continue
			_objective_templates_primary_by_id[tid] = t
	else:
		push_warning("DataManager: objective_templates.primary is neither Dictionary nor Array.")

	# Bonus
	if typeof(bonus) == TYPE_DICTIONARY:
		for id2 in bonus.keys():
			var tmpl2 = bonus[id2]
			if typeof(tmpl2) == TYPE_DICTIONARY:
				_objective_templates_bonus_by_id[id2] = tmpl2
	elif typeof(bonus) == TYPE_ARRAY:
		for t2 in bonus:
			if typeof(t2) != TYPE_DICTIONARY:
				continue
			var tid2: String = t2.get("id", "")
			if tid2 == "":
				continue
			_objective_templates_bonus_by_id[tid2] = t2
	else:
		push_warning("DataManager: objective_templates.bonus is neither Dictionary nor Array.")


func get_objective_template(id: String) -> Dictionary:
	##
	# Returns an objective template by id, searching both primary and bonus sets.
	##
	if _objective_templates_primary_by_id.has(id):
		return _objective_templates_primary_by_id[id]
	if _objective_templates_bonus_by_id.has(id):
		return _objective_templates_bonus_by_id[id]
	return {}


func get_primary_objective_templates() -> Dictionary:
	return _objective_templates_primary_by_id


func get_bonus_objective_templates() -> Dictionary:
	return _objective_templates_bonus_by_id


# -------------------------------------------------------------------
# JSON Helper
# -------------------------------------------------------------------

func _load_json_file(path: String) -> Variant:
	##
	# Loads and parses a JSON file.
	# Returns the parsed root (Dictionary/Array) or {} on failure.
	##
	var text: String
	if not FileAccess.file_exists(path):
		push_warning("DataManager: File does not exist: %s" % path)
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("DataManager: Failed to open file: %s" % path)
		return {}

	text = file.get_as_text()
	file.close()

	if text == "":
		push_warning("DataManager: File is empty: %s" % path)
		return {}

	var parsed:Variant = JSON.parse_string(text)
	if typeof(parsed) == TYPE_NIL:
		push_warning("DataManager: Failed to parse JSON file: %s" % path)
		return {}

	return parsed
