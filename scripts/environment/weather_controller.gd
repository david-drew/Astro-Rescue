## res://scripts/modes/mode1/weather_controller.gd
extends Node
class_name WeatherController

##
# WeatherController (Mode 1)
#
# Responsibilities:
#  - Manage dynamic wind based on wind_profiles.json via DataManager
#  - Provide a time-varying wind vector for physics (lander, debris later)
#  - Emit wind telemetry and gust warnings (local + via EventBus)
#  - Optionally orchestrate meteor showers as time-based hazards
#
# It does NOT:
#  - Read mission config directly (EnvironmentController passes environment)
#  - Render fog/precipitation or visual effects directly
##

# -------------------------------------------------------------------
# Signals
# -------------------------------------------------------------------

signal wind_vector_changed(wind_vector: Vector2)
signal wind_gust_warning(direction_deg: float, strength_factor: float)
signal meteor_shower_started(params: Dictionary)
signal meteor_shower_ended()

# -------------------------------------------------------------------
# Exports
# -------------------------------------------------------------------

@export_category("References")
@export var data_manager_path: NodePath
@export var meteor_spawner_path: NodePath

@export_category("Wind")
@export var auto_apply_default_profile: bool = true
@export var default_wind_profile_id: String = "none"
@export var default_wind_strength_multiplier: float = 1.0
@export var wind_signal_hz: float = 10.0
@export var gust_warning_lead_time: float = 0.4
@export var gust_min_duration: float = 0.4
@export var gust_max_duration: float = 1.5

@export_category("Meteor Showers")
@export var enable_meteor_showers: bool = false
@export var meteor_shower_auto_start: bool = false
@export var meteor_shower_min_interval: float = 20.0
@export var meteor_shower_max_interval: float = 40.0
@export var meteor_shower_min_duration: float = 5.0
@export var meteor_shower_max_duration: float = 12.0
@export var meteor_shower_default_params: Dictionary = {}

@export_category("Debug")
@export var debug_logging: bool = false

# -------------------------------------------------------------------
# Internal state
# -------------------------------------------------------------------

var _data_manager: Node = null
var _meteor_spawner: Node = null

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# Wind profile data
var _current_profile_id: String = "none"
var _current_profile: Dictionary = {}
var _strength_multiplier: float = 1.0

var _base_wind_vector: Vector2 = Vector2.ZERO
var _current_wind_vector: Vector2 = Vector2.ZERO

# Gust simulation
var _gust_timer: float = 0.0
var _next_gust_interval: float = 0.0
var _gust_active: bool = false
var _gust_remaining_time: float = 0.0
var _gust_factor: float = 1.0
var _gust_warning_sent: bool = false

# Wind telemetry timing
var _wind_signal_interval: float = 0.1
var _wind_signal_accumulator: float = 0.0

# Meteor shower simulation
var _meteor_shower_active: bool = false
var _meteor_shower_time_remaining: float = 0.0
var _time_until_next_shower: float = -1.0
var _current_meteor_params: Dictionary = {}

# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------

func _ready() -> void:
	_rng.randomize()

	if data_manager_path != NodePath(""):
		_data_manager = get_node_or_null(data_manager_path)

	if meteor_spawner_path != NodePath(""):
		_meteor_spawner = get_node_or_null(meteor_spawner_path)

	if wind_signal_hz <= 0.0:
		_wind_signal_interval = 0.0
	else:
		_wind_signal_interval = 1.0 / wind_signal_hz

	if auto_apply_default_profile:
		set_wind_profile(default_wind_profile_id, default_wind_strength_multiplier)

	if enable_meteor_showers and meteor_shower_auto_start:
		_schedule_next_meteor_shower()


func _process(delta: float) -> void:
	_update_wind(delta)
	_update_wind_signals(delta)
	_update_meteor_showers(delta)

# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func set_wind_profile(profile_id: String, strength_multiplier: float = 1.0) -> void:
	_current_profile_id = profile_id
	_strength_multiplier = strength_multiplier

	_current_profile = _fetch_wind_profile(profile_id)
	_compute_base_wind_vector()
	_reset_gust_state()

	if debug_logging:
		print("[WeatherController] set_wind_profile id=", profile_id,
			" strength_multiplier=", strength_multiplier,
			" base_vector=", _base_wind_vector)

	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("wind_profile_changed", profile_id)


func apply_environment_wind(environment_state: Dictionary) -> void:
	# Compatibility with EnvironmentController calling apply_environment_wind(...)
	var profile_id: String = environment_state.get("wind_profile_id", default_wind_profile_id)
	var strength_multiplier: float = environment_state.get("wind_strength_multiplier", default_wind_strength_multiplier)
	set_wind_profile(profile_id, strength_multiplier)


func set_wind_from_environment(environment_state: Dictionary) -> void:
	# Convenience alias if you want to be explicit
	apply_environment_wind(environment_state)


func get_current_wind_vector() -> Vector2:
	return _current_wind_vector


func start_meteor_shower(duration: float, params: Dictionary = {}) -> void:
	if duration <= 0.0:
		return

	_meteor_shower_active = true
	_meteor_shower_time_remaining = duration
	_current_meteor_params = params.duplicate(true)

	if debug_logging:
		print("[WeatherController] start_meteor_shower duration=", duration,
			" params=", _current_meteor_params)

	emit_signal("meteor_shower_started", _current_meteor_params)
	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("meteor_shower_started", _current_meteor_params)

	if _meteor_spawner != null and _meteor_spawner.has_method("start_meteor_shower"):
		_meteor_spawner.call("start_meteor_shower", _current_meteor_params)


func stop_meteor_shower() -> void:
	if not _meteor_shower_active:
		return

	if debug_logging:
		print("[WeatherController] stop_meteor_shower (manual)")

	_end_meteor_shower_internal()
	_schedule_next_meteor_shower()

# -------------------------------------------------------------------
# Wind internals
# -------------------------------------------------------------------

func _fetch_wind_profile(profile_id: String) -> Dictionary:
	# Prefer explicit node if set
	if _data_manager != null and _data_manager.has_method("get_wind_profile"):
		var profile: Dictionary = _data_manager.call("get_wind_profile", profile_id)
		if profile.size() > 0:
			return profile

	# Fallback: use DataManager autoload if present
	if Engine.has_singleton("DataManager"):
		var dm_profile: Dictionary = DataManager.get_wind_profile(profile_id)
		if dm_profile.size() > 0:
			return dm_profile

	if debug_logging:
		print("[WeatherController] Warning: wind profile '", profile_id,
			"' not found; using none.")

	return {
		"base_speed": 0.0,
		"gust_frequency": 0.0,
		"direction_deg": 0.0
	}


func _compute_base_wind_vector() -> void:
	var base_speed: float = float(_current_profile.get("base_speed", 0.0))
	var direction_deg: float = float(_current_profile.get("direction_deg", 0.0))
	var direction_rad: float = deg_to_rad(direction_deg)

	var base_vec: Vector2 = Vector2(base_speed, 0.0)
	base_vec = base_vec.rotated(direction_rad)

	_base_wind_vector = base_vec


func _reset_gust_state() -> void:
	_gust_timer = 0.0
	_gust_active = false
	_gust_remaining_time = 0.0
	_gust_factor = 1.0
	_gust_warning_sent = false

	var gust_frequency: float = float(_current_profile.get("gust_frequency", 0.0))
	if gust_frequency <= 0.0:
		_next_gust_interval = 0.0
	else:
		var safe_freq: float = max(gust_frequency, 0.001)
		var mean_interval: float = 1.0 / safe_freq
		_next_gust_interval = _rng.randf_range(mean_interval * 0.5, mean_interval * 1.5)


func _update_wind(delta: float) -> void:
	# No profile or explicit zero-speed → zero wind
	if _base_wind_vector == Vector2.ZERO and _strength_multiplier == 0.0:
		_current_wind_vector = Vector2.ZERO
		return

	var gust_frequency: float = float(_current_profile.get("gust_frequency", 0.0))
	if gust_frequency <= 0.0:
		# Steady wind
		_gust_active = false
		_gust_factor = 1.0
		_current_wind_vector = _base_wind_vector * _strength_multiplier
		return

	# Gust-capable profile
	_gust_timer += delta

	if not _gust_active:
		if _next_gust_interval > 0.0:
			var time_until_gust: float = _next_gust_interval - _gust_timer

			if time_until_gust <= gust_warning_lead_time and time_until_gust > 0.0:
				if not _gust_warning_sent:
					_emit_gust_warning()
					_gust_warning_sent = true

		if _next_gust_interval > 0.0 and _gust_timer >= _next_gust_interval:
			_start_gust()
	else:
		_gust_remaining_time -= delta
		if _gust_remaining_time <= 0.0:
			_end_gust()

	var magnitude_factor: float = 1.0
	if _gust_active:
		magnitude_factor = _gust_factor

	_current_wind_vector = _base_wind_vector * _strength_multiplier * magnitude_factor


func _start_gust() -> void:
	var gust_range: Array = _current_profile.get("gust_strength_range", [])
	var min_factor: float = 1.0
	var max_factor: float = 1.0

	if gust_range.size() >= 2:
		min_factor = float(gust_range[0])
		max_factor = float(gust_range[1])

	_gust_factor = _rng.randf_range(min_factor, max_factor)

	var min_duration: float = max(gust_min_duration, 0.1)
	var max_duration: float = max(gust_max_duration, min_duration)
	_gust_remaining_time = _rng.randf_range(min_duration, max_duration)

	_gust_active = true
	_gust_timer = 0.0
	_gust_warning_sent = false

	if debug_logging:
		print("[WeatherController] Gust started factor=", _gust_factor,
			" duration=", _gust_remaining_time)


func _end_gust() -> void:
	_gust_active = false
	_gust_factor = 1.0
	_gust_warning_sent = false

	var gust_frequency: float = float(_current_profile.get("gust_frequency", 0.0))
	if gust_frequency <= 0.0:
		_next_gust_interval = 0.0
	else:
		var safe_freq: float = max(gust_frequency, 0.001)
		var mean_interval: float = 1.0 / safe_freq
		_next_gust_interval = _rng.randf_range(mean_interval * 0.5, mean_interval * 1.5)

	if debug_logging:
		print("[WeatherController] Gust ended. Next gust in ", _next_gust_interval, " seconds.")


func _emit_gust_warning() -> void:
	var direction_deg: float = float(_current_profile.get("direction_deg", 0.0))
	var gust_range: Array = _current_profile.get("gust_strength_range", [])
	var approx_factor: float = 1.0

	if gust_range.size() >= 2:
		approx_factor = (float(gust_range[0]) + float(gust_range[1])) * 0.5

	if debug_logging:
		print("[WeatherController] Gust warning direction_deg=", direction_deg,
			" approx_factor=", approx_factor)

	emit_signal("wind_gust_warning", direction_deg, approx_factor)
	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("wind_gust_warning", direction_deg, approx_factor)


func _update_wind_signals(delta: float) -> void:
	if _wind_signal_interval <= 0.0:
		return

	_wind_signal_accumulator += delta
	while _wind_signal_accumulator >= _wind_signal_interval:
		_wind_signal_accumulator -= _wind_signal_interval

		emit_signal("wind_vector_changed", _current_wind_vector)
		if Engine.has_singleton("EventBus"):
			EventBus.emit_signal("wind_vector_changed", _current_wind_vector)

# -------------------------------------------------------------------
# Meteor showers internals
# -------------------------------------------------------------------

func _schedule_next_meteor_shower() -> void:
	if not enable_meteor_showers:
		_time_until_next_shower = -1.0
		return

	var min_interval: float = max(meteor_shower_min_interval, 0.0)
	var max_interval: float = max(meteor_shower_max_interval, min_interval)

	_time_until_next_shower = _rng.randf_range(min_interval, max_interval)

	if debug_logging:
		print("[WeatherController] Next meteor shower in ", _time_until_next_shower, " seconds.")


func _start_scheduled_meteor_shower() -> void:
	var min_duration: float = max(meteor_shower_min_duration, 0.1)
	var max_duration: float = max(meteor_shower_max_duration, min_duration)
	var duration: float = _rng.randf_range(min_duration, max_duration)

	start_meteor_shower(duration, meteor_shower_default_params)
	_time_until_next_shower = -1.0


func _end_meteor_shower_internal() -> void:
	_meteor_shower_active = false
	_meteor_shower_time_remaining = 0.0

	emit_signal("meteor_shower_ended")
	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("meteor_shower_ended")

	if _meteor_spawner != null and _meteor_spawner.has_method("end_meteor_shower"):
		_meteor_spawner.call("end_meteor_shower")


func _update_meteor_showers(delta: float) -> void:
	if not enable_meteor_showers:
		return

	if _meteor_shower_active:
		_meteor_shower_time_remaining -= delta
		if _meteor_shower_time_remaining <= 0.0:
			if debug_logging:
				print("[WeatherController] Meteor shower finished.")
			_end_meteor_shower_internal()
			_schedule_next_meteor_shower()
	else:
		if meteor_shower_auto_start and _time_until_next_shower >= 0.0:
			_time_until_next_shower -= delta
			if _time_until_next_shower <= 0.0:
				if debug_logging:
					print("[WeatherController] Starting scheduled meteor shower.")
				_start_scheduled_meteor_shower()
