extends Node

@export var missions_root: String = "res://data/missions/"
@export var debug_logging: bool = true

var _missions: Array = []
var _missions_by_id: Dictionary = {}

func _ready() -> void:
	reload_all()


func reload_all() -> void:
	_missions.clear()
	_missions_by_id.clear()

	var paths: Array = _scan_for_json(missions_root)

	for p in paths:
		var cfg: Dictionary = DataManager._load_json_file(p)
		if cfg.is_empty():
			continue

		var normalized := _normalize(cfg, p)
		if normalized.is_empty():
			continue

		var id: String = normalized["id"]
		if _missions_by_id.has(id):
			push_warning("Duplicate mission id '" + id + "' in " + p)
			continue

		_missions.append(normalized)
		_missions_by_id[id] = normalized

	if debug_logging:
		print("[MissionRegistry] Loaded ", _missions.size(), " missions")


func get_all() -> Array:
	return _missions


func get_by_id(id: String) -> Dictionary:
	if _missions_by_id.has(id):
		return _missions_by_id[id]
	return {}


func get_training() -> Array:
	var out: Array = []
	for m in _missions:
		if m.get("is_training", false):
			out.append(m)
	return out


func get_non_training() -> Array:
	var out: Array = []
	for m in _missions:
		if not m.get("is_training", false):
			out.append(m)
	return out


func get_candidates(filters: Dictionary) -> Array:
	var out: Array = []

	var min_rep: int = filters.get("min_rep", -999999)
	var max_rep: int = filters.get("max_rep", 999999)
	var categories: Array = filters.get("categories", [])
	var exclude_ids: Array = filters.get("exclude_ids", [])
	var include_training: bool = filters.get("include_training", true)
	var now_day: int = filters.get("now_day", -1)

	for m in _missions:
		if not include_training and m.get("is_training", false):
			continue

		var rep_req: int = m.get("reputation_required", 0)
		if rep_req < min_rep or rep_req > max_rep:
			continue

		if categories.size() > 0:
			var cat: String = m.get("category", "uncategorized")
			if not categories.has(cat):
				continue

		var id: String = m.get("id", "")
		if exclude_ids.has(id):
			continue

		if now_day >= 0:
			if _is_expired(m, now_day):
				continue

		out.append(m)

	return out


# ---------- Internals ----------

func _scan_for_json(root: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(root)
	if dir == null:
		push_warning("MissionRegistry: could not open " + root)
		return out

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue

		var full := root + name
		if dir.current_is_dir():
			out.append_array(_scan_for_json(full + "/"))
		else:
			if name.ends_with(".json"):
				out.append(full)

		name = dir.get_next()

	dir.list_dir_end()
	return out


func _normalize(cfg: Dictionary, path: String) -> Dictionary:
	# required fields
	if not cfg.has("id"):
		push_warning("MissionRegistry: missing id in " + path)
		return {}

	if not cfg.has("display_name"):
		cfg["display_name"] = cfg["id"]

	if not cfg.has("tier"):
		cfg["tier"] = 0

	if not cfg.has("is_training"):
		cfg["is_training"] = false

	# category from json or folder
	if not cfg.has("category"):
		cfg["category"] = _infer_category_from_path(path)

	# optional metadata defaults
	if not cfg.has("difficulty"):
		cfg["difficulty"] = 1

	if not cfg.has("recommended_skills"):
		cfg["recommended_skills"] = [] 

	if not cfg.has("expires_in_days"):
		cfg["expires_in_days"] = null

	if not cfg.has("unique"):
		cfg["unique"] = false

	# store source for debugging
	cfg["_source_path"] = path

	return cfg


func _infer_category_from_path(path: String) -> String:
	var parts := path.replace("\\", "/").split("/")
	if parts.size() >= 2:
		var folder := parts[parts.size() - 2]
		if folder != "missions":
			return folder
	return "uncategorized"


func _is_expired(m: Dictionary, now_day: int) -> bool:
	var expires_in = m.get("expires_in_days", null)
	if expires_in == null:
		return false

	var first_seen: int = m.get("first_seen_at_day", -1)
	if first_seen < 0:
		# If you haven't recorded first_seen yet, treat as not expired
		return false

	var deadline: int = first_seen + int(expires_in)
	if now_day > deadline:
		return true

	return false
