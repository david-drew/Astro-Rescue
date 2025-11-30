extends Camera2D

signal screenshot

# -------------------------------------------------------------------
# Follow behavior
# -------------------------------------------------------------------

@export var follow_lerp_speed: float = 5.0

# Default offset used when:
# - Lander is moving and altitude > near_surface_threshold_m, or
# - Non-lander vehicles (buggy/EVA).
#
# For a roughly centered camera, set this to (0, 0) or a small offset.
@export var follow_offset: Vector2 = Vector2.ZERO

# Surface offset used ONLY for the lander when:
# - It is moving, AND
# - Altitude <= near_surface_threshold_m, AND
# - It is NOT considered "landed".
#
# Remember: in Godot 2D, positive Y is down.
# So to move the camera UP (see more ground below), use a NEGATIVE Y value.
@export var lander_surface_offset: Vector2 = Vector2(0.0, 300.0)

# Altitude threshold (meters) between "high flight" and "near surface".
# All altitudes <= this (including negatives) count as "near surface" for offset.
@export var near_surface_threshold_m: float = 100.0

# Altitude below which we treat the lander as "landed".
# Because your pad can be -20 to -50m, this should be a NEGATIVE value,
# e.g. -20 or -30.
@export var lander_landed_altitude_m: float = -20.0

# Optional velocity check to avoid calling it "landed" while still sliding.
# Used only if the target is a RigidBody2D.
@export var landed_speed_threshold: float = 5.0

var _target: Node2D = null
var _vehicle_type: String = ""  # "lander", "buggy", "eva", or ""
var _use_dynamic_zoom: bool = false

var _current_altitude: float = 0.0   # raw altitude, can be negative
var _current_alt_band: int = -1      # used for zoom bands

# -------------------------------------------------------------------
# Lander altitude + zoom bands
# -------------------------------------------------------------------

# Altitude thresholds in meters for bands. Higher band = higher altitude.
# These are based on your original numbers (600, 500, 220, 110).
@export var band_4_threshold_m: float = 600.0
@export var band_3_threshold_m: float = 500.0
@export var band_2_threshold_m: float = 220.0
@export var band_1_threshold_m: float = 110.0

# Lander dynamic zoom configuration.
# Example if far=0.8, step=0.2:
#   band 4 -> 0.8
#   band 3 -> 1.0
#   band 2 -> 1.2
#   band 1 -> 1.4
#   band 0 -> 1.6
@export var lander_zoom_far: float = 0.8
@export var lander_zoom_step: float = 0.2

# -------------------------------------------------------------------
# Zoom limits and tweening
# -------------------------------------------------------------------

@export var ZOOM_MAX: float = 2.5
@export var ZOOM_MIN: float = 0.2

@export var tween_duration: float = 0.6  # seconds

var _zoom_tween: Tween = null
var new_zoom: float = 0.0

# Fixed zooms for surface vehicles
@export var buggy_fixed_zoom: float = 1.6
@export var eva_fixed_zoom: float = 1.6

# Manual zoom step
@export var zoom_scale: float = 0.1

# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------

func _ready() -> void:
	# Connect lander altitude signal once.
	if not EventBus.is_connected("lander_altitude_changed", Callable(self, "_on_altitude_changed")):
		EventBus.connect("lander_altitude_changed", Callable(self, "_on_altitude_changed"))


# Called from Player.gd when active vehicle changes.
# vehicle_type is one of "lander", "buggy", "eva".
func set_target(target: Node2D, vehicle_type: String) -> void:
	_target = target
	_vehicle_type = vehicle_type
	_use_dynamic_zoom = (_vehicle_type == "lander")

	if _use_dynamic_zoom:
		# Recalculate band and zoom from current altitude (clamped for bands).
		var effective_alt: float = max(_current_altitude, 0.0)
		_current_alt_band = _get_altitude_band(effective_alt)
		_update_lander_zoom()
	else:
		# For buggy and EVA, use fixed zoom.
		if _vehicle_type == "buggy":
			_set_fixed_zoom(buggy_fixed_zoom)
		elif _vehicle_type == "eva":
			_set_fixed_zoom(eva_fixed_zoom)


func clear_target() -> void:
	_target = null
	_vehicle_type = ""
	_use_dynamic_zoom = false


# -------------------------------------------------------------------
# Follow logic (physics tick to avoid jitter with RigidBody2D)
# -------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _target == null:
		return

	var offset: Vector2 = Vector2.ZERO

	if _vehicle_type == "lander" and _use_dynamic_zoom:
		var is_landed: bool = _target.can_exit_to_surface()

		if is_landed:
			# Landed: always centered camera.
			offset = Vector2.ZERO
		else:
			# Moving lander:
			# - If altitude > 100m → use follow_offset (normal / centered-ish).
			# - If altitude <= 100m → use surface offset.
			if _current_altitude > near_surface_threshold_m:
				offset = follow_offset
			else:
				offset = lander_surface_offset
	else:
		# Non-lander vehicles use follow_offset as their general framing.
		offset = follow_offset

	var target_pos: Vector2 = _target.global_position + offset
	global_position = global_position.lerp(target_pos, follow_lerp_speed * delta)


func _is_lander_considered_landed() -> bool:
	# Simple rule: "landed" if altitude is at or below this threshold.
	# Since your pad is often between -20m and -50m, pick something safely below
	# the surface, e.g. -10, -20, or -30, and tune in the inspector.
	return _current_altitude <= lander_landed_altitude_m


# -------------------------------------------------------------------
# Altitude handling + dynamic lander zoom
# -------------------------------------------------------------------

func _on_altitude_changed(altitude_meters: float) -> void:
	# Store raw altitude (can be negative).
	_current_altitude = altitude_meters

	if not _use_dynamic_zoom:
		return

	# For bands/zoom, treat negative altitude as 0 (still "at surface").
	var effective_altitude: float = max(altitude_meters, 0.0)

	var new_band: int = _get_altitude_band(effective_altitude)
	if new_band != _current_alt_band:
		_current_alt_band = new_band

	_update_lander_zoom()


func _get_altitude_band(altitude_meters: float) -> int:
	# Higher band number = higher altitude.
	if altitude_meters > band_4_threshold_m:
		return 4
	elif altitude_meters > band_3_threshold_m:
		return 3
	elif altitude_meters > band_2_threshold_m:
		return 2
	elif altitude_meters > band_1_threshold_m:
		return 1
	else:
		return 0


func _update_lander_zoom() -> void:
	if not _use_dynamic_zoom:
		return

	var target_zoom: float

	match _current_alt_band:
		4:	target_zoom = lander_zoom_far
		3:	target_zoom = lander_zoom_far + lander_zoom_step
		2:	target_zoom = lander_zoom_far + lander_zoom_step * 2.0
		1:	target_zoom = lander_zoom_far + lander_zoom_step * 3.0
		0:	target_zoom = lander_zoom_far + lander_zoom_step * 4.0
		_:	target_zoom = lander_zoom_far + lander_zoom_step * 4.0

	target_zoom = clamp(target_zoom, ZOOM_MIN, ZOOM_MAX)

	# Avoid pointless tweens for tiny changes.
	if abs(target_zoom - zoom.x) < 0.01:
		return

	_tween_to_zoom(target_zoom)


func _set_fixed_zoom(target_zoom: float) -> void:
	target_zoom = clamp(target_zoom, ZOOM_MIN, ZOOM_MAX)
	if abs(target_zoom - zoom.x) < 0.01:
		return
	_tween_to_zoom(target_zoom)


func _tween_to_zoom(target_zoom: float) -> void:
	new_zoom = target_zoom

	if _zoom_tween != null and _zoom_tween.is_running():
		_zoom_tween.kill()

	_zoom_tween = create_tween()
	_zoom_tween.set_trans(Tween.TRANS_SINE)
	_zoom_tween.set_ease(Tween.EASE_IN_OUT)
	_zoom_tween.tween_property(self, "zoom", Vector2(new_zoom, new_zoom), tween_duration)


# -------------------------------------------------------------------
# Manual zoom & screenshot (from your original behavior)
# -------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	new_zoom = 0.0

	if event.is_action_pressed("zoom_in"):
		new_zoom = zoom.x + zoom_scale
	elif event.is_action_pressed("zoom_out"):
		new_zoom = zoom.x - zoom_scale
	elif event.is_action_pressed("reset_camera"):
		zoom = Vector2(1.0, 1.0)
		return
	elif event.is_action_pressed("print_screen"):
		print_screen()
		return

	if new_zoom > ZOOM_MIN and new_zoom < ZOOM_MAX:
		camera_zoom()


func camera_zoom() -> void:
	zoom = Vector2(new_zoom, new_zoom)


func print_screen() -> void:
	var datime := Time.get_datetime_dict_from_system()
	var img: Image = get_viewport().get_texture().get_image()

	var err := img.save_png(
		"user://sl_{year}-{month}-{day}_{hour}.{minute}.{second}.png"
		.format(datime)
	)

	if err == OK:
		screenshot.emit()
	else:
		print("Error: Couldn't save screenshot.")
