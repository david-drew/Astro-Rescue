extends Node
class_name SurfaceOpsData

## SurfaceOpsData
##
## Responsibilities:
##  - Load and cache Surface Ops data (terrain profiles + spawn profiles).
##  - Provide helper accessors by profile ID.
##
## Notes:
##  - Safe to use as an autoload singleton.
##  - Fails gracefully: unknown IDs return {} but do not crash.

# Paths to JSON data
const TERRAIN_PROFILES_PATH: String = "res://data/surface_ops/terrain_profiles.json"
const SPAWN_PROFILES_PATH: String = "res://data/surface_ops/spawn_profiles.json"

# Internal caches
var _terrain_profiles: Dictionary = {}
var _spawn_profiles: Dictionary = {}
var _terrain_loaded: bool = false
var _spawn_loaded: bool = false


func _ready() -> void:
	# Optional: eager load. Or you can lazily load on first access.
	# Here we leave it lazy to avoid IO during startup if unused.
	pass


# -------------------------------------------------------------------
# Public API - Terrain Profiles
# -------------------------------------------------------------------

func get_terrain_profile(profile_id: String) -> Dictionary:
	"""
	Returns the terrain profile dict for the given ID.
	Returns {} if not found or data not available.
	"""
	if profile_id == "":
		return {}

	if not _terrain_loaded:
		_load_terrain_profiles()

	if _terrain_profiles.is_empty():
		return {}

	if not _terrain_profiles.has(profile_id):
		push_warning("SurfaceOpsData: terrain profile not found: %s" % profile_id)
		return {}

	var raw: Variant = _terrain_profiles.get(profile_id, {})
	if typeof(raw) == TYPE_DICTIONARY:
		# Defensive deep copy so callers can't accidentally mutate the cache.
		return (raw as Dictionary).duplicate(true)

	return {}


# -------------------------------------------------------------------
# Public API - Spawn Profiles
# -------------------------------------------------------------------

func get_spawn_profile(profile_id: String) -> Dictionary:
	"""
	Returns the spawn profile dict for the given ID.
	Returns {} if not found or data not available.
	"""
	if profile_id == "":
		return {}

	if not _spawn_loaded:
		_load_spawn_profiles()

	if _spawn_profiles.is_empty():
		return {}

	if not _spawn_profiles.has(profile_id):
		push_warning("SurfaceOpsData: spawn profile not found: %s" % profile_id)
		return {}

	var raw: Variant = _spawn_profiles.get(profile_id, {})
	if typeof(raw) == TYPE_DICTIONARY:
		return (raw as Dictionary).duplicate(true)

	return {}


# -------------------------------------------------------------------
# Internal loading helpers
# -------------------------------------------------------------------

func _load_terrain_profiles() -> void:
	_terrain_loaded = true
	_terrain_profiles.clear()

	var file := FileAccess.open(TERRAIN_PROFILES_PATH, FileAccess.READ)
	if file == null:
		push_warning("SurfaceOpsData: could not open terrain_profiles.json at path: %s" % TERRAIN_PROFILES_PATH)
		return

	var text := file.get_as_text()
	file.close()

	var parsed:Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("SurfaceOpsData: terrain_profiles.json is not a Dictionary at root.")
		return

	_terrain_profiles = parsed as Dictionary


func _load_spawn_profiles() -> void:
	_spawn_loaded = true
	_spawn_profiles.clear()

	var file := FileAccess.open(SPAWN_PROFILES_PATH, FileAccess.READ)
	if file == null:
		push_warning("SurfaceOpsData: could not open spawn_profiles.json at path: %s" % SPAWN_PROFILES_PATH)
		return

	var text := file.get_as_text()
	file.close()

	var parsed:Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("SurfaceOpsData: spawn_profiles.json is not a Dictionary at root.")
		return

	_spawn_profiles = parsed as Dictionary
