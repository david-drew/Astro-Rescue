extends Control
class_name LanderHUD

##
# LanderHUD - IMPROVED EventBus Version
#
# Changes from original:
# - Removed direct lander reference (uses EventBus only)
# - No polling - only updates on signal
# - More efficient
# - Cleaner architecture
##

@export_category("Visibility")
@export var is_hud_enabled: bool = true
@export var requires_equipment: bool = false
@export var equipment_online: bool = true

@export_category("Debug")
@export var debug_logging: bool = false

# Internal state (updated via EventBus)
var _current_wind: Vector2 = Vector2.ZERO
var _current_gravity: Vector2 = Vector2.ZERO
var _current_velo: Vector2 = Vector2.ZERO
var _current_altitude: float = 0.0
var _current_fuel_ratio: float = 1.0
var _time_remaining: float = -1.0

# UI References
var _title_label: Label = null
var _wind_label: Label = null
var _velo_label: Label = null
var _gravity_label: Label = null
var _altitude_label: Label = null
var _timer_label: Label = null
var _fuel_label: Label = null
var _fuel_bar: ProgressBar = null

# Visibility flags
var _show_altitude: bool = true
var _show_fuel: bool = true
var _show_velo: bool = true
var _show_wind: bool = true
var _show_gravity: bool = true
var _show_timer: bool = true

# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------

func _ready() -> void:
	_cache_ui_references()
	_connect_eventbus_signals()
	_update_instrument_visibility()
	_refresh_all_displays()
	
	if debug_logging:
		print("[LanderHUD] Ready - listening to EventBus")

func _cache_ui_references() -> void:
	"""Cache references to UI elements"""
	var container := $MarginContainer/VBoxContainer
	
	_title_label = container.get_node_or_null("TitleLabel") as Label
	_wind_label = container.get_node_or_null("WindLabel") as Label
	_velo_label = container.get_node_or_null("VeloLabel") as Label
	_gravity_label = container.get_node_or_null("GravityLabel") as Label
	_altitude_label = container.get_node_or_null("AltitudeLabel") as Label
	_timer_label = container.get_node_or_null("TimerLabel") as Label
	
	var fuel_container: HBoxContainer = container.get_node_or_null("FuelContainer") as HBoxContainer
	if fuel_container != null:
		_fuel_label = fuel_container.get_node_or_null("FuelLabel") as Label
		_fuel_bar = fuel_container.get_node_or_null("FuelBar") as ProgressBar
	
	if _title_label != null:
		_title_label.text = "LANDER HUD"

func _connect_eventbus_signals() -> void:
	"""Connect to all relevant EventBus signals"""
	
	# Connect to existing signals
	if not EventBus.is_connected("gravity_changed", Callable(self, "_on_gravity_changed")):
		EventBus.connect("gravity_changed", Callable(self, "_on_gravity_changed"))
	
	if EventBus.has_signal("wind_vector_changed"):
		if not EventBus.is_connected("wind_vector_changed", Callable(self, "_on_wind_vector_changed")):
			EventBus.connect("wind_vector_changed", Callable(self, "_on_wind_vector_changed"))

	if EventBus.has_signal("lander_velocity_changed"):
		if not EventBus.is_connected("lander_velocity_changed", Callable(self, "_on_velocity_changed")):
			EventBus.connect("lander_velocity_changed", Callable(self, "_on_velocity_changed"))	

	if EventBus.has_signal("lander_altitude_changed"):
		if not EventBus.is_connected("lander_altitude_changed", Callable(self, "_on_altitude_changed")):
			EventBus.connect("lander_altitude_changed", Callable(self, "_on_altitude_changed"))
	
	if EventBus.has_signal("fuel_changed"):
		if not EventBus.is_connected("fuel_changed", Callable(self, "_on_fuel_changed")):
			EventBus.connect("fuel_changed", Callable(self, "_on_fuel_changed"))
	
	# Optional: batch stats update
	if EventBus.has_signal("lander_stats_updated"):
		if not EventBus.is_connected("lander_stats_updated", Callable(self, "_on_lander_stats_updated")):
			EventBus.connect("lander_stats_updated", Callable(self, "_on_lander_stats_updated"))

# -------------------------------------------------------------------
# EventBus Signal Handlers
# -------------------------------------------------------------------

func _on_gravity_changed(gravity_vector: Vector2) -> void:
	_current_gravity = gravity_vector
	_update_gravity_display()
	
	if debug_logging:
		print("[LanderHUD] Gravity: ", gravity_vector)

func _on_wind_vector_changed(wind_vector: Vector2) -> void:
	_current_wind = wind_vector
	_update_wind_display()
	
	if debug_logging:
		print("[LanderHUD] Wind: ", wind_vector)

func _on_velocity_changed(velo_vector: Vector2) -> void:
	_current_velo = velo_vector
	_update_velocity_display()
	
	if debug_logging:
		print("[LanderHUD] Velocity: ", velo_vector)

func _on_altitude_changed(altitude_meters: float) -> void:
	_current_altitude = altitude_meters
	_update_altitude_display()
	
	if debug_logging:
		print("[LanderHUD] Altitude: ", altitude_meters)

func _on_fuel_changed(fuel_ratio: float) -> void:
	_current_fuel_ratio = fuel_ratio
	_update_fuel_display()
	
	if debug_logging:
		print("[LanderHUD] Fuel: ", fuel_ratio * 100.0, "%")

func _on_lander_stats_updated(stats: Dictionary) -> void:
	# Batch update from lander - all stats at once
	if stats.has("altitude"):
		_current_altitude = float(stats["altitude"])
	
	if stats.has("velocity"):
		_current_velo = Vector2(stats["velocity"])
	
	if stats.has("fuel_ratio"):
		_current_fuel_ratio = float(stats["fuel_ratio"])
	
	# Refresh displays
	_update_altitude_display()
	_update_fuel_display()
	_update_velocity_display()
	
	if debug_logging:
		print("[LanderHUD] Stats batch: ", stats)


# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func apply_instruments_config(config: Dictionary) -> void:
	"""Configure which instruments are visible"""
	_show_altitude = bool(config.get("show_altitude", true))
	_show_fuel = bool(config.get("show_fuel", true))
	_show_velo = bool(config.get("show_velo", true))
	_show_wind = bool(config.get("show_wind", true))
	_show_gravity = bool(config.get("show_gravity", true))
	_show_timer = bool(config.get("show_timer", true))
	_update_instrument_visibility()

func set_time_remaining(seconds: float) -> void:
	"""Update mission timer (called by MissionController)"""
	_time_remaining = seconds
	_update_timer_display()

# -------------------------------------------------------------------
# Input Handling
# -------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_lander_hud"):
		is_hud_enabled = not is_hud_enabled
		if debug_logging:
			print("[LanderHUD] Toggled: ", is_hud_enabled)

# -------------------------------------------------------------------
# Display Updates
# -------------------------------------------------------------------

#func _process(_delta: float) -> void:
#	visible = _should_be_visible()

func _should_be_visible() -> bool:
	if not is_hud_enabled:
		return false
	if requires_equipment and not equipment_online:
		return false
	return true

func _refresh_all_displays() -> void:
	"""Refresh all display elements (called on ready or config change)"""
	_update_wind_display()
	_update_gravity_display()
	_update_velocity_display()
	_update_altitude_display()
	_update_fuel_display()
	_update_timer_display()

func _update_instrument_visibility() -> void:
	"""Show/hide instruments based on configuration"""
	if _wind_label != null:
		_wind_label.visible = _show_wind
	
	if _velo_label != null:
		_velo_label.visible = _show_velo
	
	if _gravity_label != null:
		_gravity_label.visible = _show_gravity
	
	if _altitude_label != null:
		_altitude_label.visible = _show_altitude
	
	if _timer_label != null:
		_timer_label.visible = _show_timer
	
	if _fuel_label != null:
		_fuel_label.visible = _show_fuel
	
	if _fuel_bar != null:
		_fuel_bar.visible = _show_fuel

func _update_wind_display() -> void:
	if _wind_label == null or not _show_wind:
		return
	
	if _current_wind == Vector2.ZERO:
		_wind_label.text = "Wind: calm"
		return
	
	var mag: float = _current_wind.length()
	var angle_deg: float = rad_to_deg(_current_wind.angle())
	var norm_angle: float = fmod(angle_deg + 360.0, 360.0)
	
	_wind_label.text = "Wind: %0.1f m/s @ %0.0f°" % [mag, norm_angle]

func _update_gravity_display() -> void:
	if _gravity_label == null or not _show_gravity:
		return
	
	# Show magnitude regardless of zero vector
	# (Your altitude-based gravity is always non-zero)
	var mag: float = _current_gravity.length()
	
	# Show as actual force value
	if mag < 0.01:
		_gravity_label.text = "Gravity: 0.00 m/s²"
	else:
		# Show both absolute value and percentage of standard
		var standard_gravity: float = 30.0  # Your lunar surface gravity
		var percent: float = (mag / standard_gravity) * 100.0
		
		# Color code by strength
		var color := Color.WHITE
		if percent < 30.0:
			color = Color.CYAN  # Low gravity (orbital)
		elif percent > 80.0:
			color = Color.ORANGE  # Strong gravity (near surface)
		
		_gravity_label.modulate = color
		_gravity_label.text = "Gravity: %0.2f m/s² (%0.0f%%)" % [mag, percent]

func _update_velocity_display() -> void:
	if _velo_label == null or not _show_velo:
		return
	
	var mag: float = _current_velo.length()
	
	# Show as actual force value
	if mag < 0.01:
		_velo_label.text = "Velocity: 0.00 m/s²"
	else:
		# Show both absolute value and percentage of standard
		var direction: float = _current_velo.x
		_velo_label.text = "Velocity: %0.2f m/s² (%0.0f%%)" % [mag, direction]

func _vector_to_cardinal(dir: Vector2) -> String:
	# No direction if we're basically stopped
	if dir.length() < 0.01:
		return "--"
	
	# Flip Y so screen-up feels like "N"
	var adjusted := Vector2(dir.x, -dir.y)
	var angle_deg: float = rad_to_deg(adjusted.angle())
	var norm: float = fmod(angle_deg + 360.0, 360.0)
	
	if norm < 22.5 or norm >= 337.5: 	return "E"
	elif norm < 67.5:		return "NE"
	elif norm < 112.5:		return "N"
	elif norm < 157.5:		return "NW"
	elif norm < 202.5:		return "W"
	elif norm < 247.5:		return "SW"
	elif norm < 292.5:		return "S"
	else:					return "SE"


func _update_altitude_display() -> void:
	if _altitude_label == null or not _show_altitude:
		return
	
	# Color code by altitude
	var color := Color.WHITE
	if _current_altitude < 50.0:
		color = Color.RED
	elif _current_altitude < 200.0:
		color = Color.ORANGE
	elif _current_altitude < 500.0:
		color = Color.YELLOW
	
	_altitude_label.modulate = color
	_altitude_label.text = "Altitude: %0.1f m" % _current_altitude

func _update_fuel_display() -> void:
	# Update progress bar
	if _fuel_bar != null:
		_fuel_bar.min_value = 0.0
		_fuel_bar.max_value = 1.0
		_fuel_bar.value = clamp(_current_fuel_ratio, 0.0, 1.0)
		
		# Color code fuel bar
		if _current_fuel_ratio < 0.2:
			_fuel_bar.modulate = Color.RED
		elif _current_fuel_ratio < 0.4:
			_fuel_bar.modulate = Color.ORANGE
		else:
			_fuel_bar.modulate = Color.WHITE
	
	# Update label
	if _fuel_label != null and _show_fuel:
		var percent: int = int(_current_fuel_ratio * 100.0)
		_fuel_label.text = "Fuel: %3d%%" % percent

func _update_timer_display() -> void:
	if _timer_label == null or not _show_timer:
		return
	
	if _time_remaining < 0.0:
		_timer_label.text = "Timer: --:--"
		return
	
	var seconds_int: int = int(round(_time_remaining))
	if seconds_int < 0:
		seconds_int = 0
	
	var minutes: int = seconds_int / 60
	var seconds: int = seconds_int % 60
	
	# Color code timer
	var color := Color.WHITE
	if seconds_int < 30:
		color = Color.RED
	elif seconds_int < 60:
		color = Color.ORANGE
	
	_timer_label.modulate = color
	_timer_label.text = "Timer: %02d:%02d" % [minutes, seconds]
