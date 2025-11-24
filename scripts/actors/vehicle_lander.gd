extends RigidBody2D
class_name VehicleLander

signal touchdown(touchdown_data: Dictionary)
signal destroyed(cause: String, context: Dictionary)
signal fuel_changed(fuel_ratio: float)
signal altitude_changed(altitude_m: float)

@export_category("Thrust")
@export var base_thrust_force: float = 200.0
@export var turbo_thrust_multiplier: float = 1.8
@export var allow_turbo: bool = true

@export_category("Fuel")
@export var fuel_capacity: float = 100.0
@export var base_fuel_burn_rate: float = 12.0
@export var turbo_fuel_multiplier: float = 2.5

@export_category("Rotation")
@export var rotation_accel: float = 6.0
@export var max_angular_speed: float = 4.5
@export var rotation_drag: float = 6.0

@export_category("Landing Safety")
@export var safe_vertical_speed: float = 30.0
@export var safe_horizontal_speed: float = 25.0
@export var safe_tilt_deg: float = 20.0
@export var safe_upright_check_duration: float = 1.5

@export_category("Destruction Thresholds")
@export var destroy_vertical_speed: float = 40.0
@export var destroy_horizontal_speed: float = 40.0
@export var destroy_velocity_magnitude: float = 40.0
@export var hard_crash_always_fatal: bool = true

@export_category("Landing Zone / Debug")
@export var upright_angle_limit_for_check: float = 25.0
@export var debug_logging: bool = false

@export_category("Environment")
@export var weather_controller_path: NodePath
@export var wind_force_scale: float = 1.0

@export_category("Altitude")
@export var altitude_reference_y: float = 0.0
@export var pixels_per_meter: float = 16.0

@export_category("Gravity")
@export var use_altitude_gravity: bool = true
@export var gravity_field_manager_path: NodePath = NodePath("/root/GravityFieldManager")

@export_category("HUD Updates")
@export var hud_update_enabled: bool = true
@export var hud_update_interval_frames: int = 20
@export var altitude_change_threshold: float = 5.0

# Internal state
var _current_fuel: float = 0.0
var _last_fuel_ratio: float = 1.0

var _has_sent_touchdown: bool = false
var _has_sent_destruction: bool = false

var _weather_controller: Node = null
var _current_wind: Vector2 = Vector2.ZERO
var _current_gravity_vector: Vector2 = Vector2.ZERO
var _gravity_field_manager: Node = null

var _hud_frame_counter: int = 0
var _last_emitted_altitude: float = 0.0
var _last_emitted_fuel: float = 1.0

var _touchdown_settle_timer: float = 0.0
var _touchdown_pending: bool = false
var _pending_touchdown_body: Node = null


var _active: bool = true


func set_active(active: bool) -> void:
	_active = active
	visible = active
	set_physics_process(active)
	process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
	if not active:
		return
	# When becoming active, reset touchdown flags for a new descent phase.
	_has_sent_touchdown = false


func _ready() -> void:
	_current_fuel = fuel_capacity
	if fuel_capacity <= 0.0:
		_current_fuel = 0.0

	_last_fuel_ratio = _get_fuel_ratio()

	gravity_scale = 0.0
	var default_gravity: float = float(ProjectSettings.get_setting("physics/2d/default_gravity", 30.0))
	_current_gravity_vector = Vector2.DOWN * default_gravity

	collision_layer = 2
	collision_mask = 1
	add_to_group("lander")

	if weather_controller_path != NodePath(""):
		_weather_controller = get_node_or_null(weather_controller_path)

	if use_altitude_gravity and gravity_field_manager_path != NodePath(""):
		_gravity_field_manager = get_node_or_null(gravity_field_manager_path)
		if _gravity_field_manager == null:
			push_warning("VehicleLander: GravityFieldManager not found at path: " + str(gravity_field_manager_path))

	$Sprite2D.rotation_degrees = -90

	call_deferred("_setup_collision")


func _setup_collision() -> void:
	collision_layer = 2
	collision_mask = 1
	add_to_group("lander")


func _physics_process(delta: float) -> void:
	if not _active:
		return

	if _weather_controller != null and _weather_controller.has_method("get_current_wind_vector"):
		_current_wind = _weather_controller.get_current_wind_vector()
	else:
		_current_wind = Vector2.ZERO

	if use_altitude_gravity and _gravity_field_manager != null and _gravity_field_manager.has_method("get_gravity_at_position"):
		_current_gravity_vector = _gravity_field_manager.get_gravity_at_position(global_position)

	# NOTE: controls are called by Player.apply_controls(delta)
	# We don't call them here to avoid double-input.

	if hud_update_enabled:
		_hud_frame_counter += 1
		if _hud_frame_counter >= hud_update_interval_frames:
			_hud_frame_counter = 0
			_emit_hud_updates()

	if _touchdown_pending:
		_touchdown_settle_timer += delta
		if _touchdown_settle_timer >= safe_upright_check_duration:
			_finalize_touchdown()



func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if not _active:
		return

	# Apply wind as lateral force
	if _current_wind != Vector2.ZERO:
		state.apply_central_force(_current_wind * wind_force_scale * mass)

	if _current_gravity_vector != Vector2.ZERO:
		state.apply_central_force(_current_gravity_vector * mass)


# Called by Player
func apply_controls(delta: float) -> void:
	if not _active:
		return

	var thrust_input: float = Input.get_action_strength("lander_thrust")
	var turbo_pressed: bool = Input.is_action_pressed("lander_turbo")

	var rotate_right: float = Input.get_action_strength("lander_rotate_right")
	var rotate_left: float = Input.get_action_strength("lander_rotate_left")
	var rotate_input: float = rotate_right - rotate_left

	if rotate_input != 0.0:
		var new_ang_vel: float = angular_velocity + rotate_input * rotation_accel * delta
		angular_velocity = clampf(new_ang_vel, -max_angular_speed, max_angular_speed)
	elif rotation_drag > 0.0:
		var drag_step: float = rotation_drag * delta
		if angular_velocity > 0.0:
			angular_velocity = max(0.0, angular_velocity - drag_step)
		elif angular_velocity < 0.0:
			angular_velocity = min(0.0, angular_velocity + drag_step)

	if allow_turbo and turbo_pressed:
		thrust_input = max(thrust_input, 1.0)

	if thrust_input > 0.0 and _current_fuel > 0.0:
		var thrust_multiplier: float = 1.0
		var fuel_mult: float = 1.0

		if allow_turbo and turbo_pressed:
			thrust_multiplier += turbo_thrust_multiplier
			fuel_mult = turbo_fuel_multiplier

		var thrust_force: float = base_thrust_force * thrust_input * thrust_multiplier
		var thrust_vector: Vector2 = Vector2(0.0, -1.0).rotated(rotation) * thrust_force

		apply_central_impulse(thrust_vector * delta)

		var fuel_consumed: float = base_fuel_burn_rate * thrust_input * fuel_mult * delta
		_current_fuel = max(0.0, _current_fuel - fuel_consumed)
		_last_fuel_ratio = _get_fuel_ratio()
		_update_fuel_ratio()


# -------------------------------------------------------------------
# Landing / destruction (from your snippet)
# -------------------------------------------------------------------

func _on_body_entered(body: Node) -> void:
	if not _active:
		return

	if body.is_in_group("terrain") or body.is_in_group("ground"):
		var v: Vector2 = linear_velocity
		var speed: float = v.length()

		var v_vert: float = abs(v.y)
		var v_horiz: float = abs(v.x)

		if v_vert > destroy_vertical_speed or v_horiz > destroy_horizontal_speed or speed > destroy_velocity_magnitude:
			_handle_destruction("high_speed_impact", {
				"speed": speed,
				"vertical_speed": v_vert,
				"horizontal_speed": v_horiz
			})
		elif v_vert <= safe_vertical_speed * 1.5 and v_horiz <= safe_horizontal_speed * 1.5:
			# Potential landing; start settle check rather than deciding instantly
			_touchdown_pending = true
			_touchdown_settle_timer = 0.0
			_pending_touchdown_body = body

		else:
			_handle_destruction("hard_landing", {
				"speed": speed,
				"vertical_speed": v_vert,
				"horizontal_speed": v_horiz
			})


func _finalize_touchdown() -> void:
	_touchdown_pending = false

	# Recompute with current velocities after settle
	var touchdown_data := get_landing_state()
	if touchdown_data.get("successful", false):
		_handle_safe_landing()
	else:
		# For now keep your behavior: fatal on bad landing
		_handle_destruction("hard_landing", touchdown_data)


func _handle_safe_landing() -> void:
	if _has_sent_touchdown:
		return

	_has_sent_touchdown = true

	if debug_logging:
		print("[VehicleLander] Safe touchdown!")

	var touchdown_data: Dictionary = get_landing_state()

	EventBus.emit_signal("lander_touchdown", touchdown_data)
	EventBus.emit_signal("lander_landed_safely", {})
	emit_signal("touchdown", touchdown_data)


func get_landing_state(_terrain_generator: Node = null, zone_id: String = "", zone_info: Dictionary = {}) -> Dictionary:
	var v: Vector2 = linear_velocity
	var v_vert: float = abs(v.y)
	var v_horiz: float = abs(v.x)
	var speed: float = v.length()
	var tilt_deg: float = abs(rad_to_deg(rotation))

	# FIX: successful uses safe thresholds (not destroy thresholds)
	var successful: bool = v_vert <= safe_vertical_speed and v_horiz <= safe_horizontal_speed and tilt_deg <= safe_tilt_deg

	var hull_damage_ratio: float = 0.0
	if not successful:
		var over_speed: float = max(max(v_vert - safe_vertical_speed, v_horiz - safe_horizontal_speed), 0.0)
		hull_damage_ratio = clamp(over_speed / max(destroy_vertical_speed, 1.0), 0.0, 1.0)

	return {
		"successful": successful,
		"impact_speed": speed,
		"vertical_speed": v_vert,
		"horizontal_speed": v_horiz,
		"tilt_deg": tilt_deg,
		"landing_zone_id": zone_id,
		"landing_zone_info": zone_info,
		"hull_damage_ratio": hull_damage_ratio
	}


func _handle_destruction(cause: String, context: Dictionary) -> void:
	if _has_sent_destruction:
		return

	_has_sent_destruction = true

	if debug_logging:
		print("[VehicleLander] Destruction: cause=", cause, " context=", context)

	EventBus.emit_signal("lander_destroyed", cause, context)
	emit_signal("destroyed", cause, context)

	if hard_crash_always_fatal:
		EventBus.emit_signal("player_died", "lander_crash_" + cause, context)

	set_physics_process(false)

	PhysicsServer2D.body_set_state(get_rid(), PhysicsServer2D.BODY_STATE_LINEAR_VELOCITY, Vector2.ZERO)
	PhysicsServer2D.body_set_state(get_rid(), PhysicsServer2D.BODY_STATE_ANGULAR_VELOCITY, 0.0)

	for i in range(3):
		await get_tree().physics_frame
		PhysicsServer2D.body_set_state(get_rid(), PhysicsServer2D.BODY_STATE_LINEAR_VELOCITY, Vector2.ZERO)
		PhysicsServer2D.body_set_state(get_rid(), PhysicsServer2D.BODY_STATE_ANGULAR_VELOCITY, 0.0)

		if not freeze:
			linear_velocity = Vector2.ZERO
			angular_velocity = 0.0
			break

	freeze = true
	lock_rotation = true
	linear_velocity = Vector2.ZERO
	angular_velocity = 0.0


# -------------------------------------------------------------------
# TODO: paste these from your lander_controller.gd
# -------------------------------------------------------------------

func _get_fuel_ratio() -> float:
	if fuel_capacity <= 0.0:
		return 0.0
	return _current_fuel / fuel_capacity

func _update_fuel_ratio() -> void:
	var ratio := _get_fuel_ratio()

	# Emit on meaningful change to avoid spam
	if abs(ratio - _last_emitted_fuel) < 0.001:
		return

	_last_emitted_fuel = ratio

	EventBus.emit_signal("fuel_changed", ratio)
	emit_signal("fuel_changed", ratio)

	# Thresholds for critical/depleted. Tune if needed.
	if ratio <= 0.1 and ratio > 0.0:
		EventBus.emit_signal("fuel_critical", ratio)
	if ratio <= 0.0:
		EventBus.emit_signal("fuel_depleted")

func _emit_hud_updates() -> void:
	var altitude := _get_altitude_meters()
	var fuel := _get_fuel_ratio()

	# Altitude signal only if changed enough
	if abs(altitude - _last_emitted_altitude) >= altitude_change_threshold:
		_last_emitted_altitude = altitude
		EventBus.emit_signal("lander_altitude_changed", altitude)
		emit_signal("altitude_changed", altitude)

	# Stats packet every HUD tick
	var stats := {
		"altitude": altitude,
		"fuel_ratio": fuel,
		"velocity": linear_velocity,
		"angular_velocity": angular_velocity,
		"position": global_position
	}
	EventBus.emit_signal("lander_stats_updated", stats)


func _get_altitude_meters() -> float:
	# altitude_reference_y should be terrain baseline in pixels
	var dy_pixels: float = altitude_reference_y - global_position.y
	return dy_pixels / pixels_per_meter
