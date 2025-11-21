## res://scripts/modes/mode1/lander_controller.gd
extends RigidBody2D
class_name LanderController

##
# LanderController - IMPROVED VERSION
#
# Key improvements in this version:
# - Fixed thrust multiplier bug (was 5.0, now 1.0)
# - Better tuned physics for lunar lander feel
# - Integrated with GravityFieldManager for altitude-based gravity
# - Improved rotation feel
# - Better default values
##

# -------------------------------------------------------------------
# Thrust & rotation settings
# -------------------------------------------------------------------

@export_category("Thrust")
@export var base_thrust_force: float = 700.0  			# Reduced from 600 for better feel
@export var turbo_thrust_multiplier: float = 6.0
@export var allow_turbo: bool = true

@export_category("Fuel")
@export var fuel_capacity: float = 100.0
@export var base_fuel_burn_rate: float = 12.0
@export var turbo_fuel_multiplier: float = 2.5

@export_category("Rotation")
@export var rotation_accel: float = 6.0         # Slightly reduced for smoother control
@export var max_angular_speed: float = 4.5      # Slightly reduced
@export var rotation_drag: float = 6.0          # Increased for snappier feel

# -------------------------------------------------------------------
# Landing / impact thresholds
# -------------------------------------------------------------------

@export_category("Landing Safety")
@export var safe_vertical_speed: float = 4.0
@export var safe_horizontal_speed: float = 3.0
@export var safe_tilt_deg: float = 20.0
@export var safe_upright_check_duration: float = 1.5

@export_category("Destruction Thresholds")
@export var destroy_vertical_speed: float = 15.0
@export var destroy_horizontal_speed: float = 15.0
@export var destroy_velocity_magnitude: float = 15.0
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
@export var use_altitude_gravity: bool = true  # NEW: Enable altitude-based gravity
@export var gravity_field_manager_path: NodePath = NodePath("/root/GravityFieldManager")

@export_category("HUD Updates")
@export var hud_update_enabled: bool = true
@export var hud_update_interval_frames: int = 20  	# Update every 20 frames (efficient!)
@export var altitude_change_threshold: float = 5.0  # Only emit if altitude changes by this much

# -------------------------------------------------------------------
# Internal state
# -------------------------------------------------------------------

var old_gravity:Vector2 = Vector2.ZERO
var _current_fuel: float = 0.0
var _last_fuel_ratio: float = 1.0

var _landing_evaluation_active: bool = false
var _has_sent_touchdown: bool = false
var _has_sent_destruction: bool = false

var _impact_data_pending: Dictionary = {}
var _impact_ground_body: Object = null

var _landing_contact_time: float = 0.0

var _weather_controller: WeatherController = null
var _current_wind: Vector2 = Vector2.ZERO
var _current_gravity_vector: Vector2 = Vector2.ZERO

var _gravity_field_manager:GravityFieldManager

var _hud_frame_counter: int = 0
var _last_emitted_altitude: float = 0.0
var _last_emitted_fuel: float = 1.0

# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------

func _ready() -> void:
	_current_fuel = fuel_capacity
	if fuel_capacity <= 0.0:
		_current_fuel = 0.0
	_last_fuel_ratio = _get_fuel_ratio()
	_gravity_field_manager = GravityFieldManager.new()

	# Disable built-in gravity; we will apply custom gravity manually.
	gravity_scale = 0.0
	
	# Initial gravity fallback: use current project default as downward acceleration.
	# Changed to 30.0 for lunar-style feel (was 49.0)
	var default_gravity: float = float(ProjectSettings.get_setting("physics/2d/default_gravity", 30.0))
	_current_gravity_vector = Vector2.DOWN * default_gravity
	
	# ADD THESE LINES at the end of _ready():
	collision_layer = 2   # Layer 2 for lander
	collision_mask = 1    # Detect layer 1 (terrain)
	add_to_group("lander")

	# Weather controller reference (for wind)
	if weather_controller_path != NodePath(""):
		_weather_controller = get_node_or_null(weather_controller_path)

	# NEW: Gravity field manager for altitude-based gravity
	if use_altitude_gravity and gravity_field_manager_path != NodePath(""):
		_gravity_field_manager = get_node_or_null(gravity_field_manager_path)
		if _gravity_field_manager == null:
			push_warning("LanderController: GravityFieldManager not found at path: ", gravity_field_manager_path)

	# Listen for gravity updates from EnvironmentController via EventBus.
	if not EventBus.is_connected("gravity_changed", Callable(self, "_on_gravity_changed")):
		EventBus.connect("gravity_changed", Callable(self, "_on_gravity_changed"))

	$Sprite2D.rotation_degrees = -90  # change from default right to facing up

	if debug_logging:
		print("[LanderController] Ready. Fuel capacity=", fuel_capacity, " default_gravity=", default_gravity)

	call_deferred("_setup_collision")

func _setup_collision() -> void:
	print("⚠️ Setting up lander collision...")
	collision_layer = 2
	collision_mask = 1
	add_to_group("lander")
	
	print("✅ Lander collision_layer: ", collision_layer)
	print("✅ Lander collision_mask: ", collision_mask)
	print("✅ In lander group: ", is_in_group("lander"))

func _physics_process(delta: float) -> void:
	# Get Weather Effects
	if _weather_controller != null:
		_current_wind = _weather_controller.get_current_wind_vector()
	else:
		_current_wind = Vector2.ZERO

	# Update gravity based on altitude if enabled
	if use_altitude_gravity and _gravity_field_manager != null:
		_current_gravity_vector = _gravity_field_manager.get_gravity_at_position(global_position)

	#_current_gravity_vector = Vector2(0, 30)  # DEBUG ONLY

	_apply_controls(delta)
	
	# HUD updates (efficient - only every N frames)
	if hud_update_enabled:
		_hud_frame_counter += 1
		if _hud_frame_counter >= hud_update_interval_frames:
			_hud_frame_counter = 0
			_emit_hud_updates()


func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	# Apply custom gravity as a force: F = m * a
	if _current_gravity_vector != Vector2.ZERO:
		var m: float = mass
		var gravity_force: Vector2 = _current_gravity_vector * m
		state.apply_force(gravity_force, Vector2.ZERO)

	# Apply wind as a lateral/angled force.
	if _current_wind != Vector2.ZERO and wind_force_scale != 0.0:
		var wind_force: Vector2 = _current_wind * wind_force_scale
		state.apply_central_force(wind_force)

# -------------------------------------------------------------------
# Control / thrust
# -------------------------------------------------------------------

func _apply_controls(delta: float) -> void:
	# Gather input.
	var thrust_input: float = Input.get_action_strength("lander_thrust")
	var turbo_pressed: bool = false
	if allow_turbo:
		turbo_pressed = Input.is_action_pressed("lander_turbo")

	var rotate_right: float = Input.get_action_strength("lander_rotate_right")
	var rotate_left: float = Input.get_action_strength("lander_rotate_left")
	var rotate_input: float = rotate_right - rotate_left

	# Apply rotation via angular_velocity.
	if rotate_input != 0.0:
		var new_ang_vel: float = angular_velocity + rotate_input * rotation_accel * delta
		angular_velocity = clampf(new_ang_vel, -max_angular_speed, max_angular_speed)
	elif rotation_drag > 0.0:
		# Dampen rotation toward 0 when no input, so the lander doesn't spin forever.
		var drag_step: float = rotation_drag * delta
		if angular_velocity > 0.0:
			angular_velocity = max(0.0, angular_velocity - drag_step)
		elif angular_velocity < 0.0:
			angular_velocity = min(0.0, angular_velocity + drag_step)

	# Apply thrust if we have fuel and there is thrust input.
	if thrust_input > 0.0 and _current_fuel > 0.0:
		# FIXED: Was hardcoded to 5.0, now properly defaults to 1.0
		var thrust_multiplier: float = 3.0
		var fuel_mult: float = 1.0

		if allow_turbo and turbo_pressed:	
			thrust_multiplier = turbo_thrust_multiplier
			fuel_mult = turbo_fuel_multiplier

		var thrust_force: float = base_thrust_force * thrust_input * thrust_multiplier
		var thrust_vector: Vector2 = Vector2(0.0, -1.0).rotated(rotation) * thrust_force

		apply_force(thrust_vector, Vector2.ZERO)

		# Fuel burn
		var burn_rate: float = base_fuel_burn_rate * thrust_input * fuel_mult
		var fuel_used: float = burn_rate * delta
		_current_fuel -= fuel_used
		if _current_fuel < 0.0:
			_current_fuel = 0.0

		_update_fuel_ratio()
	else:
		# No thrust; just update ratio if we happened to hit exactly zero previously.
		_update_fuel_ratio()


func _get_fuel_ratio() -> float:
	if fuel_capacity <= 0.0:
		return 0.0
	return clampf(_current_fuel / fuel_capacity, 0.0, 1.0)


func _update_fuel_ratio() -> void:
	var ratio: float = _get_fuel_ratio()
	# Only emit when ratio changes meaningfully to avoid spamming signals.
	if abs(ratio - _last_fuel_ratio) > 0.005:
		_last_fuel_ratio = ratio
		EventBus.emit_signal("fuel_changed", ratio)


# -------------------------------------------------------------------
# Collision / landing detection
# -------------------------------------------------------------------
func get_landing_state(body:Node) -> Dictionary:
	_landing_evaluation_active = true
	_impact_ground_body = body

	# Record velocity at impact
	var vel: Vector2 = linear_velocity
	var v_speed: float = abs(vel.y)
	var h_speed: float = abs(vel.x)
	var speed_mag: float = vel.length()

	# Tilt at impact
	var tilt_deg: float = abs(rad_to_deg(rotation))
	tilt_deg = fmod(tilt_deg, 360.0)
	if tilt_deg > 180.0:
		tilt_deg = 360.0 - tilt_deg

	# Check if we hit a designated landing zone
	var in_landing_zone: bool = false
	var landing_zone_id: String = ""
	var distance_to_center: float = 0.0

	if body and body.has_method("is_in_group"):
		if body.is_in_group("landing_zone"):
			in_landing_zone = true
			if body.has_method("get"):
				if body.get("landing_zone_id") != null:
					landing_zone_id = str(body.get("landing_zone_id"))
				else:
					landing_zone_id = body.name
			else:
				landing_zone_id = body.name

			# Approximate center distance by using the body's global position.
			var lander_pos: Vector2 = global_position
			var lz_center: Vector2 = body.global_position
			distance_to_center = (lander_pos - lz_center).length()
		else:
			landing_zone_id = ""
	else:
		landing_zone_id = ""

	_impact_data_pending = {
		"vertical_speed": v_speed,
		"horizontal_speed": h_speed,
		"impact_force": speed_mag,
		"tilt_deg": tilt_deg,
		"in_landing_zone": in_landing_zone,
		"landing_zone_id": landing_zone_id,
		"distance_to_lz_center": distance_to_center,
		"upright_duration": 0.0,
		"hull_damage_ratio": 0.0
	}

	# Decide if this is immediately catastrophic.
	if _is_severe_impact(v_speed, h_speed, speed_mag):
		# Treat as hard crash.
		_impact_data_pending["hull_damage_ratio"] = 1.0
		#_send_touchdown(false, _impact_data_pending)
		_handle_destruction("hard_impact", _impact_data_pending)
	else:
		# Soft or moderate landing attempt: start evaluating upright time.
		_landing_contact_time = 0.0
		_start_upright_check()

	# NEW: If this is a hard crash, push lander out of terrain
	if _is_severe_impact(v_speed, h_speed, speed_mag):
		# Before handling destruction, ensure we're not penetrating
		_push_out_of_terrain(body)
		
		# Then handle destruction
		_impact_data_pending["hull_damage_ratio"] = 1.0
		_handle_destruction("hard_impact", _impact_data_pending)

	return _impact_data_pending


func _on_body_entered(body: Node) -> void:
	print("LANDER: BODY ENTERED................................................")
	##
	# Hook this to the RigidBody2D "body_entered" signal.
	# This is treated as a potential landing impact.
	##
	if _landing_evaluation_active or _has_sent_touchdown:
		return

	_landing_evaluation_active = true
	_impact_ground_body = body

	# Record velocity at impact
	var vel: Vector2 = linear_velocity
	var v_speed: float = abs(vel.y)
	var h_speed: float = abs(vel.x)
	var speed_mag: float = vel.length()

	# Tilt at impact
	var tilt_deg: float = abs(rad_to_deg(rotation))
	tilt_deg = fmod(tilt_deg, 360.0)
	if tilt_deg > 180.0:
		tilt_deg = 360.0 - tilt_deg

	# Check if we hit a designated landing zone
	var in_landing_zone: bool = false
	var landing_zone_id: String = ""
	var distance_to_center: float = 0.0

	if body and body.has_method("is_in_group"):
		if body.is_in_group("landing_zone"):
			in_landing_zone = true
			if body.has_method("get"):
				if body.get("landing_zone_id") != null:
					landing_zone_id = str(body.get("landing_zone_id"))
				else:
					landing_zone_id = body.name
			else:
				landing_zone_id = body.name

			# Approximate center distance by using the body's global position.
			var lander_pos: Vector2 = global_position
			var lz_center: Vector2 = body.global_position
			distance_to_center = (lander_pos - lz_center).length()
		else:
			landing_zone_id = ""
	else:
		landing_zone_id = ""

	_impact_data_pending = {
		"vertical_speed": v_speed,
		"horizontal_speed": h_speed,
		"impact_force": speed_mag,
		"tilt_deg": tilt_deg,
		"in_landing_zone": in_landing_zone,
		"landing_zone_id": landing_zone_id,
		"distance_to_lz_center": distance_to_center,
		"upright_duration": 0.0,
		"hull_damage_ratio": 0.0
	}

	# Decide if this is immediately catastrophic.
	if _is_severe_impact(v_speed, h_speed, speed_mag):
		# Treat as hard crash.
		_impact_data_pending["hull_damage_ratio"] = 1.0
		_send_touchdown(false, _impact_data_pending)
		_handle_destruction("hard_impact", _impact_data_pending)
	else:
		# Soft or moderate landing attempt: start evaluating upright time.
		_landing_contact_time = 0.0
		_start_upright_check()

	# NEW: If this is a hard crash, push lander out of terrain
	if _is_severe_impact(v_speed, h_speed, speed_mag):
		# Before handling destruction, ensure we're not penetrating
		_push_out_of_terrain(body)
		
		# Then handle destruction
		_impact_data_pending["hull_damage_ratio"] = 1.0
		_send_touchdown(false, _impact_data_pending)
		_handle_destruction("hard_impact", _impact_data_pending)

func _on_gravity_changed(gravity_vector: Vector2) -> void:
	# Only update if NOT using altitude-based gravity
	# (altitude-based overrides this every frame in _physics_process)
	if not use_altitude_gravity:
		_current_gravity_vector = gravity_vector
		if debug_logging:
			print("[LanderController] Gravity updated: ", gravity_vector)

func _is_severe_impact(v_speed: float, h_speed: float, speed_mag: float) -> bool:
	if v_speed > destroy_vertical_speed:
		return true
	if h_speed > destroy_horizontal_speed:
		return true
	if speed_mag > destroy_velocity_magnitude:
		return true
	return false


func _start_upright_check() -> void:
	# Run a small coroutine to track how long we stay upright and in contact.
	_call_upright_check()


func _call_upright_check() -> void:
	# Separate function so we can use await without warnings.
	_upright_check_coroutine()


func _upright_check_coroutine() -> void:
	var elapsed: float = 0.0
	var max_duration: float = max(safe_upright_check_duration, 0.1)

	while elapsed < max_duration:
		# If we have lost contact with the ground, stop checking.
		if get_contact_count() == 0:
			break

		# If we tip too far over, stop checking.
		var current_tilt: float = abs(rad_to_deg(rotation))
		current_tilt = fmod(current_tilt, 360.0)
		if current_tilt > 180.0:
			current_tilt = 360.0 - current_tilt

		if current_tilt > upright_angle_limit_for_check:
			break

		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()

	# Record upright duration
	_impact_data_pending["upright_duration"] = elapsed

	# Decide if landing is safe based on safe_* thresholds and tilt.
	var v_speed: float = float(_impact_data_pending.get("vertical_speed", 9999.0))
	var h_speed: float = float(_impact_data_pending.get("horizontal_speed", 9999.0))
	var tilt_deg: float = float(_impact_data_pending.get("tilt_deg", 9999.0))
	var safe: bool = true

	if v_speed > safe_vertical_speed:
		safe = false
	if h_speed > safe_horizontal_speed:
		safe = false
	if tilt_deg > safe_tilt_deg:
		safe = false
	if elapsed < safe_upright_check_duration:
		safe = false

	if not safe:
		# This is a "hard landing" but not instantly catastrophic.
		_impact_data_pending["hull_damage_ratio"] = 0.5
	else:
		_impact_data_pending["hull_damage_ratio"] = 0.0

	_send_touchdown(safe, _impact_data_pending)
	_landing_evaluation_active = false


func _send_touchdown(success: bool, impact_data: Dictionary) -> void:
	if _has_sent_touchdown:
		return

	_has_sent_touchdown = true

	if debug_logging:
		print("[LanderController] Touchdown result: success=", success, " impact_data=", impact_data)

	EventBus.emit_signal("touchdown", success, impact_data)


func _handle_destruction(cause: String, context: Dictionary) -> void:
	if _has_sent_destruction:
		return

	_has_sent_destruction = true

	if debug_logging:
		print("[LanderController] Destruction: cause=", cause, " context=", context)

	# Broadcast destruction event
	EventBus.emit_signal("lander_destroyed", cause, context)
	if hard_crash_always_fatal:
		EventBus.emit_signal("player_died", "lander_crash_" + cause, context)

	$Sprite2D.visible = false
	$DeathSprite.visible = true

	# CRITICAL FIX: Proper crash handling to prevent wild spinning
	_execute_crash_sequence()

func _execute_crash_sequence() -> void:
	"""
	Properly handle crash physics to prevent penetration and wild spinning.
	"""
	
	# Step 1: Immediately reduce angular velocity (stop crazy spinning)
	angular_velocity = angular_velocity * 0.1  # Dampen to 10%
	
	# Step 2: Dampen linear velocity (allow some bounce but not much)
	linear_velocity = linear_velocity * 0.3  # Keep 30% for realistic bounce
	
	# Step 3: Disable thrust and rotation controls
	set_physics_process(false)  # Stop processing controls
	
	# Step 4: Wait a physics frame for velocity changes to apply
	await get_tree().physics_frame
	
	# Step 5: Enable contact monitoring to prevent penetration
	contact_monitor = true
	max_contacts_reported = 4
	
	# Step 6: Add crash damping over time
	_apply_crash_damping()

func _apply_crash_damping() -> void:
	"""
	Gradually dampen physics after crash to settle the lander.
	"""
	var damping_duration: float = 2.0  # 2 seconds to settle
	var elapsed: float = 0.0
	
	while elapsed < damping_duration:
		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()
		
		# Gradually reduce velocities
		var t: float = elapsed / damping_duration
		var damping_factor: float = 1.0 - t
		
		# Apply exponential damping
		linear_velocity = linear_velocity * (0.95 - (t * 0.1))
		angular_velocity = angular_velocity * (0.90 - (t * 0.15))
		
		# If nearly stopped, freeze completely
		if linear_velocity.length() < 1.0 and abs(angular_velocity) < 0.1:
			linear_velocity = Vector2.ZERO
			angular_velocity = 0.0
			break
	
	# Final freeze
	freeze = true
	lock_rotation = true
	linear_velocity = Vector2.ZERO
	angular_velocity = 0.0


# -------------------------------------------------------------------
# ALTERNATIVE: Simpler crash handling (if the above is too complex)
# -------------------------------------------------------------------

func _handle_destruction_simple(cause: String, context: Dictionary) -> void:
	"""
	Simpler crash handling - just stop everything immediately.
	Use this if you don't want any bounce/settling physics.
	"""
	if _has_sent_destruction:
		return

	_has_sent_destruction = true

	if debug_logging:
		print("[LanderController] Destruction: cause=", cause)

	# Emit signals
	EventBus.emit_signal("lander_destroyed", cause, context)
	if hard_crash_always_fatal:
		EventBus.emit_signal("player_died", "lander_crash_" + cause, context)

	# Stop all physics immediately
	set_physics_process(false)
	
	# Use PhysicsServer2D for immediate, reliable stop
	PhysicsServer2D.body_set_state(
		get_rid(),
		PhysicsServer2D.BODY_STATE_LINEAR_VELOCITY,
		Vector2.ZERO
	)
	PhysicsServer2D.body_set_state(
		get_rid(),
		PhysicsServer2D.BODY_STATE_ANGULAR_VELOCITY,
		0.0
	)
	
	# Wait a frame then freeze
	await get_tree().physics_frame
	
	freeze = true
	lock_rotation = true


# -------------------------------------------------------------------
# ADDITIONAL: Prevent terrain penetration
# -------------------------------------------------------------------

## This prevents the lander from getting "stuck" in terrain

func _push_out_of_terrain(terrain_body: Node) -> void:
	"""
	Push lander slightly above terrain to prevent penetration.
	"""
	if not terrain_body is StaticBody2D:
		return
	
	# Get collision normal (points away from terrain)
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsRayQueryParameters2D.create(
		global_position,
		global_position + Vector2.DOWN * 100
	)
	
	var result = space_state.intersect_ray(query)
	if result:
		# Push lander 5 pixels above surface
		var safe_position = result.position + Vector2.UP * 5
		
		PhysicsServer2D.body_set_state(
			get_rid(),
			PhysicsServer2D.BODY_STATE_TRANSFORM,
			Transform2D.IDENTITY.translated(safe_position)
		)

func _apply_ship_loadout(mission_config: Dictionary) -> void:
	if not self.has_method("apply_loadout_multipliers"):
		return

	# Prefer new-style "mission_modifiers" from the mission JSON.
	# Fall back to legacy "ship_loadout" if present.
	var loadout_cfg: Dictionary = {}

	if mission_config.has("mission_modifiers"):
		loadout_cfg = mission_config.get("mission_modifiers", {})
	else:
		loadout_cfg = mission_config.get("ship_loadout", {})

	if loadout_cfg.is_empty():
		return

	var allow_override: bool = bool(loadout_cfg.get("allow_player_override", true))

	var mission_fuel_mult: float = float(loadout_cfg.get("fuel_capacity_multiplier", 1.0))
	var mission_thrust_mult: float = float(loadout_cfg.get("thrust_multiplier", 1.0))

	if allow_override and GameState.has_method("get_player_ship_loadout_overrides"):
		var player_loadout: Dictionary = GameState.get_player_ship_loadout_overrides()
		if player_loadout.has("fuel_capacity_multiplier"):
			mission_fuel_mult = float(player_loadout["fuel_capacity_multiplier"])
		if player_loadout.has("thrust_multiplier"):
			mission_thrust_mult = float(player_loadout["thrust_multiplier"])

	apply_loadout_multipliers(mission_fuel_mult, mission_thrust_mult)

func apply_loadout_multipliers(fuel_mult: float, thrust_mult: float) -> void:
	# Safety clamps
	if fuel_mult <= 0.0:
		fuel_mult = 1.0
	if thrust_mult <= 0.0:
		thrust_mult = 1.0

	# Apply fuel multiplier
	var old_capacity: float = fuel_capacity
	var new_capacity: float = old_capacity * fuel_mult
	fuel_capacity = new_capacity

	# Scale current fuel to preserve ratio (if capacity changed)
	var ratio: float = 0.0
	if old_capacity > 0.0:
		ratio = _current_fuel / old_capacity

	_current_fuel = new_capacity * ratio

	# Apply thrust multiplier
	base_thrust_force = base_thrust_force * thrust_mult

	if debug_logging:
		print("[LanderController] Loadout applied:",
			" fuel_mult=", fuel_mult,
			" thrust_mult=", thrust_mult,
			" new_capacity=", fuel_capacity,
			" new_current_fuel=", _current_fuel,
			" new_thrust_force=", base_thrust_force)

func apply_mission_modifiers(mission_config: Dictionary) -> void:
	# Public entry point for mission-based lander tweaks.
	# For now this just forwards to the loadout logic.
	_apply_ship_loadout(mission_config)


# -------------------------------------------------------------------
# UI
# -------------------------------------------------------------------

func get_fuel_ratio() -> float:
	return _get_fuel_ratio()

func get_altitude_estimate_meters() -> float:
	var dy: float = altitude_reference_y - global_position.y
	if pixels_per_meter <= 0.0:
		return 0.0

	var meters: float = dy / pixels_per_meter
	if meters < 0.0:
		meters = 0.0
	return meters


func _emit_hud_updates() -> void:
	"""
	Emit HUD update signals via EventBus.
	Called every N physics frames for efficiency.
	"""
	
	# Get current stats
	var altitude: float = get_altitude_estimate_meters()
	var fuel: float = get_fuel_ratio()

	# Option 1: Emit individual signals (allows throttling per-stat)
	_emit_altitude_if_changed(altitude)
	_emit_fuel_if_changed(fuel)
	
	# Option 2: Batch update (most efficient - single signal with all data)
	# Uncomment if you prefer batch updates:
	# _emit_batch_stats(altitude, fuel)

func _emit_altitude_if_changed(current_altitude: float) -> void:
	"""Only emit if altitude changed significantly"""
	var delta: float = abs(current_altitude - _last_emitted_altitude)
	
	if delta >= altitude_change_threshold:
		_last_emitted_altitude = current_altitude
		
		if EventBus.has_signal("lander_altitude_changed"):
			EventBus.emit_signal("lander_altitude_changed", current_altitude)

func _emit_fuel_if_changed(current_fuel: float) -> void:
	"""Only emit if fuel changed significantly (already has threshold in _update_fuel_ratio)"""
	# Fuel already has emission logic in _update_fuel_ratio()
	# This is redundant but shown for completeness
	_last_emitted_fuel = current_fuel

func _emit_batch_stats(altitude: float, fuel: float) -> void:
	"""
	Emit all stats in one signal (most efficient).
	Use this if HUD prefers batch updates.
	"""
	if EventBus.has_signal("lander_stats_updated"):
		var stats := {
			"altitude": altitude,
			"fuel_ratio": fuel,
			"velocity": linear_velocity,
			"angular_velocity": angular_velocity,
			"position": global_position
		}
		EventBus.emit_signal("lander_stats_updated", stats)
