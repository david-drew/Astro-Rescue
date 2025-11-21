## res://scripts/systems/time_manager.gd
extends Node
class_name TimeManager

##
# TimeManager
#
# Responsibilities:
#  - Track real-time and game-time.
#  - Handle pause / resume.
#  - Handle time scale (slow-mo, fast-forward, etc.).
#  - Emit tick events on named channels via EventBus:
#      - time_tick(channel_id: String, dt_game: float, dt_real: float)
#  - Emit time state changes:
#      - time_scale_changed(time_scale_id: String, new_scale: float)
#      - game_paused(reason: String)
#      - game_resumed(reason: String)
#
# NOTE: EventBus must define these signals for emit_signal() to work.
##

@export_category("Config")
@export var time_config_path: String = "res://data/physics/time_config.json"

@export_category("Debug")
@export var debug_logging: bool = false

# Public state
var is_paused: bool = false
var time_scale: float = 1.0
var time_scale_id: String = "normal"

var real_time_seconds: float = 0.0
var game_time_seconds: float = 0.0
var frame_count: int = 0

# Internal config
var _time_scales: Dictionary = {}
var _tick_channels: Dictionary = {}          # channel_id -> { interval_seconds, max_delta_seconds, enabled }
var _channel_accumulators: Dictionary = {}   # channel_id -> accumulated game-time


func _ready() -> void:
	_load_config()

	if debug_logging:
		print("[TimeManager] Ready. time_scale_id=", time_scale_id, " scale=", time_scale)


#func _process(_delta: float) -> void:
	## Mission time is driven by TimeManager via EventBus.time_tick("ui_hud").
	#pass


# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func set_time_scale_id(id: String) -> void:
	if not _time_scales.has(id):
		push_warning("[TimeManager] Unknown time_scale_id: " + id)
		return

	var info: Dictionary = _time_scales.get(id, {})
	var scale: float = float(info.get("scale", 1.0))
	if scale < 0.0:
		scale = 0.0

	time_scale_id = id
	time_scale = scale

	if debug_logging:
		print("[TimeManager] time_scale_id set to ", time_scale_id, " scale=", time_scale)

	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("time_scale_changed", time_scale_id, time_scale)


func set_time_scale_value(scale: float, source: String = "direct") -> void:
	if scale < 0.0:
		scale = 0.0

	time_scale = scale
	time_scale_id = "custom_" + source

	if debug_logging:
		print("[TimeManager] time_scale set directly to ", time_scale, " from ", source)

	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("time_scale_changed", time_scale_id, time_scale)


func pause_game(reason: String = "") -> void:
	if is_paused:
		return

	is_paused = true

	if debug_logging:
		print("[TimeManager] Game paused. Reason=", reason)

	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("game_paused", reason)


func resume_game(reason: String = "") -> void:
	if not is_paused:
		return

	is_paused = false

	if debug_logging:
		print("[TimeManager] Game resumed. Reason=", reason)

	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("game_resumed", reason)


func toggle_pause(reason: String = "") -> void:
	if is_paused:
		resume_game(reason)
	else:
		pause_game(reason)


func enable_tick_channel(channel_id: String, enabled: bool) -> void:
	if not _tick_channels.has(channel_id):
		return

	var cfg: Dictionary = _tick_channels[channel_id]
	cfg["enabled"] = enabled
	_tick_channels[channel_id] = cfg

	if debug_logging:
		print("[TimeManager] Channel ", channel_id, " enabled=", enabled)


# -------------------------------------------------------------------
# Config loading
# -------------------------------------------------------------------

func _load_config() -> void:
	var file := FileAccess.open(time_config_path, FileAccess.READ)
	if file == null:
		push_warning("[TimeManager] Could not open config at: " + time_config_path + ". Using defaults.")
		_apply_default_config()
		return

	var text: String = file.get_as_text()
	var json := JSON.new()
	var err: int = json.parse(text)
	if err != OK:
		push_warning("[TimeManager] JSON parse error: " + json.get_error_message() + ". Using defaults.")
		_apply_default_config()
		return

	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("[TimeManager] Config root is not a Dictionary. Using defaults.")
		_apply_default_config()
		return

	_configure_from_dict(data)


func _apply_default_config() -> void:
	var default_dict: Dictionary = {
		"default_time_scale_id": "normal",
		"time_scales": {
			"normal": { "scale": 1.0 }
		},
		"tick_channels": {
			"frame": {
				"interval_seconds": 0.0,
				"max_delta_seconds": 0.1,
				"enabled": true
			}
		}
	}
	_configure_from_dict(default_dict)


func _configure_from_dict(config: Dictionary) -> void:
	_time_scales.clear()
	_tick_channels.clear()
	_channel_accumulators.clear()

	var scales: Dictionary = config.get("time_scales", {})
	if scales.is_empty():
		scales = {
			"normal": { "scale": 1.0 }
		}
	_time_scales = scales.duplicate(true)

	var default_id: String = config.get("default_time_scale_id", "normal")
	if not _time_scales.has(default_id):
		var keys: Array = _time_scales.keys()
		if keys.size() > 0:
			default_id = String(keys[0])
		else:
			default_id = "normal"

	var default_info: Dictionary = _time_scales.get(default_id, {})
	var scale: float = float(default_info.get("scale", 1.0))
	if scale < 0.0:
		scale = 0.0

	time_scale_id = default_id
	time_scale = scale

	var channels_cfg: Dictionary = config.get("tick_channels", {})
	if channels_cfg.is_empty():
		channels_cfg = {
			"frame": {
				"interval_seconds": 0.0,
				"max_delta_seconds": 0.1,
				"enabled": true
			}
		}

	for channel_id in channels_cfg.keys():
		var cfg: Dictionary = channels_cfg[channel_id]
		var copy: Dictionary = cfg.duplicate(true)
		if not copy.has("enabled"):
			copy["enabled"] = true
		_tick_channels[channel_id] = copy
		_channel_accumulators[channel_id] = 0.0

	if debug_logging:
		print("[TimeManager] Configured. time_scales=", _time_scales.keys(),
			" channels=", _tick_channels.keys())


# -------------------------------------------------------------------
# Internal helpers
# -------------------------------------------------------------------

func _emit_time_tick(channel_id: String, dt_game: float, dt_real: float) -> void:
	if dt_game <= 0.0:
		return

	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("time_tick", channel_id, dt_game, dt_real)

	if debug_logging:
		# Be careful not to spam too aggressively.
		if channel_id == "world_sim":
			print("[TimeManager] Tick world_sim dt_game=", dt_game, " dt_real=", dt_real)
