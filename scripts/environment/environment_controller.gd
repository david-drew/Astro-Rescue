## res://scripts/modes/mode1/environment_controller.gd
extends Node
class_name EnvironmentController

##
# EnvironmentController (Mode 1)
#
# Responsibilities:
#  - Read environment config from GameState.current_mission_config.environment
#  - Apply gravity scaling (optionally update global 2D gravity)
#  - Configure wind (via EventBus and optional WindController)
#  - Broadcast visibility state (fog, precipitation, etc.) for VFX/UI to respond to
#
# It does NOT:
#  - Generate environment (MissionGenerator + biomes do that)
#  - Render specific fog/precipitation effects (you can hook separate nodes/scripts)
#
# Expected environment config shape (from MissionGenerator):
# {
#   "gravity_scale": float,
#   "atmosphere": String,               # "none", "thin", "standard", etc.
#   "wind_profile_id": String,
#   "visibility": {
#     "fog_type": String,
#     "fog_density": float,
#     "precipitation_type": String,
#     "precipitation_intensity": float,
#     "allow_reveal_tool": bool
#   },
#   "physics_profile_id": String,
#   "wind_strength_multiplier": float
# }
##

# -------------------------------------------------------------------
# Config
# -------------------------------------------------------------------

@export_category("Gravity")
@export var use_global_gravity: bool = true
@export var base_default_gravity: float = 49.0  # matches your project default (adjust if needed)

@export_category("Scene References")
@export var wind_controller_path: NodePath
@export var fog_node_path: NodePath          # optional: node that handles fog visuals
@export var precipitation_node_path: NodePath # optional: node that handles rain/snow/etc.

@export_category("Debug")
@export var debug_logging: bool = false

# -------------------------------------------------------------------
# Internal
# -------------------------------------------------------------------

var _environment_state: Dictionary = {}
var _wind_controller: Node = null
var _fog_node: Node = null
var _precipitation_node: Node = null


# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------

func _ready() -> void:
	_wind_controller = get_node_or_null(wind_controller_path)
	_fog_node = get_node_or_null(fog_node_path)
	_precipitation_node = get_node_or_null(precipitation_node_path)

	if GameState.current_mission_config.is_empty():
		# Mission not started yet; wait for MissionController.
		if EventBus.has_signal("mission_started"):
			EventBus.mission_started.connect(_refresh_from_mission_config)
		return

	_refresh_from_mission_config()


# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func refresh_from_mission_config() -> void:
	##
	# Exposed in case you want to refresh after changing GameState.current_mission_config.
	##
	_refresh_from_mission_config()


func get_environment_state() -> Dictionary:
	return _environment_state.duplicate(true)

# -------------------------------------------------------------------
# Core logic
# -------------------------------------------------------------------

func _refresh_from_mission_config(mission_id:String="") -> void:
	var mission_config: Dictionary = GameState.current_mission_config
	if mission_config.is_empty():
		push_warning("EnvironmentController: current_mission_config is empty.")
		return

	_environment_state = mission_config.get("environment", {}).duplicate(true)
	if _environment_state.is_empty():
		push_warning("EnvironmentController: environment config missing in MissionConfig.")
		return

	if debug_logging:
		print("[EnvironmentController] Applying environment: ", _environment_state)

	_apply_gravity()
	_apply_wind()
	_apply_visibility()


func _apply_gravity() -> void:
	# New-style gravity block takes precedence if present.
	var gravity_state: Dictionary = _environment_state.get("gravity", {})
	var gravity_enabled: bool = true
	var gravity_vector: Vector2 = Vector2.ZERO

	if not gravity_state.is_empty():
		gravity_enabled = bool(gravity_state.get("enabled", true))
		if gravity_enabled:
			var strength: float = float(gravity_state.get("strength", base_default_gravity))
			var direction_deg: float = float(gravity_state.get("direction_deg", 90.0))
			var dir_vec: Vector2 = Vector2.RIGHT.rotated(deg_to_rad(direction_deg))
			gravity_vector = dir_vec * strength
		else:
			gravity_vector = Vector2.ZERO
	else:
		# Legacy fallback: gravity_scale is a scalar multiplier on base_default_gravity,
		# always pointing downward (90 degrees).
		var gravity_scale: float = float(_environment_state.get("gravity_scale", 1.0))
		var effective_strength: float = base_default_gravity * gravity_scale
		var dir_vec_legacy: Vector2 = Vector2.DOWN
		gravity_vector = dir_vec_legacy * effective_strength

	# Optionally update global gravity magnitude for bodies that still use engine gravity.
	if use_global_gravity:
		var new_gravity_mag: float = gravity_vector.length()
		ProjectSettings.set_setting("physics/2d/default_gravity", new_gravity_mag)

		if debug_logging:
			print("[EnvironmentController] Set global 2D gravity magnitude to ",
				new_gravity_mag, " (vector=", gravity_vector, ")")

	# Broadcast custom gravity vector via EventBus so controllers can apply it manually.
	if debug_logging:
		print("[EnvironmentController] Emitting gravity_changed: ", gravity_vector)
	EventBus.emit_signal("gravity_changed", gravity_vector)


func _apply_wind() -> void:
	var wind_profile_id: String = _environment_state.get("wind_profile_id", "none")
	var wind_strength_multiplier: float = float(_environment_state.get("wind_strength_multiplier", 1.0))

	if debug_logging:
		print("[EnvironmentController] Wind profile: ", wind_profile_id, " strength_mult=", wind_strength_multiplier)

	# Notify a dedicated WindController if present.
	if _wind_controller != null:
		if _wind_controller.has_method("set_wind_profile"):
			_wind_controller.call("set_wind_profile", wind_profile_id, wind_strength_multiplier)
		elif _wind_controller.has_method("apply_environment_wind"):
			_wind_controller.call("apply_environment_wind", _environment_state)
		# If none of these methods exist, we silently ignore.

	# Broadcast via EventBus so any system (e.g., particles, camera shake) can listen.
	EventBus.emit_signal("wind_profile_changed", wind_profile_id)


func _apply_visibility() -> void:
	var visibility: Dictionary = _environment_state.get("visibility", {})
	var fog_type: String = visibility.get("fog_type", "none")
	var fog_density: float = float(visibility.get("fog_density", 0.0))
	var precip_type: String = visibility.get("precipitation_type", "none")
	var precip_intensity: float = float(visibility.get("precipitation_intensity", 0.0))
	var allow_reveal_tool: bool = bool(visibility.get("allow_reveal_tool", false))

	if debug_logging:
		print("[EnvironmentController] Visibility: fog_type=", fog_type, " fog_density=", fog_density,
			" precip_type=", precip_type, " precip_intensity=", precip_intensity,
			" allow_reveal_tool=", allow_reveal_tool)

	# Try to update any attached fog node.
	if _fog_node != null:
		if _fog_node.has_method("apply_fog_state"):
			_fog_node.call("apply_fog_state", visibility)
		else:
			# Simple fallback: if it's a CanvasItem, we can toggle visibility as a crude effect.
			var ci := _fog_node as CanvasItem
			if ci != null:
				ci.visible = fog_type != "none" and fog_density > 0.0

	# Try to update any attached precipitation node.
	if _precipitation_node != null:
		if _precipitation_node.has_method("apply_precipitation_state"):
			_precipitation_node.call("apply_precipitation_state", visibility)
		else:
			var ci2 := _precipitation_node as CanvasItem
			if ci2 != null:
				ci2.visible = precip_type != "none" and precip_intensity > 0.0

	# Broadcast via EventBus so HUD or other systems can react (icons, warnings, etc.).
	var visibility_state: Dictionary = {
		"fog_type": fog_type,
		"fog_density": fog_density,
		"precipitation_type": precip_type,
		"precipitation_intensity": precip_intensity,
		"allow_reveal_tool": allow_reveal_tool
	}
	EventBus.emit_signal("visibility_changed", visibility_state)
