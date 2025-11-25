# res://scripts/modes/mode1/mission_orbital_flow.gd
extends RefCounted
class_name MissionOrbitalFlow

signal orbital_ready_to_land(chosen_zone_id: String)

var debug:bool = false

var orbital_view: Node = null
var terrain_generator: Node = null
var mission_config: Dictionary = {}
var chosen_zone_id: String = ""
var transition_target_position: Vector2 = Vector2.ZERO

func start_orbital_flow(
	ov: Node,
	tg: Node,
	config: Dictionary,
	debug: bool
) -> void:
	orbital_view = ov
	terrain_generator = tg
	mission_config = config
	chosen_zone_id = ""
	debug = debug
	transition_target_position = Vector2.ZERO

	connect_orbital_view_signals()

	var orbital_cfg: Dictionary = mission_config.get("orbital_view", {})
	orbital_view.initialize(orbital_cfg)
	orbital_view.show_orbital_view()

	if debug:
		print("[MissionOrbitalFlow] Orbital view active, waiting for zone selection")


func _connectorbital_view_signals(debug: bool) -> void:
	if orbital_view == null:
		return

	if not orbital_view.is_connected("zone_selected", Callable(self, "_on_orbital_zone_selected")):
		orbital_view.connect("zone_selected", Callable(self, "_on_orbital_zone_selected"))

	if not orbital_view.is_connected("transition_started", Callable(self, "_on_orbital_transition_started")):
		orbital_view.connect("transition_started", Callable(self, "_on_orbital_transition_started"))

	if not orbital_view.is_connected("transition_completed", Callable(self, "_on_orbital_transition_completed")):
		orbital_view.connect("transition_completed", Callable(self, "_on_orbital_transition_completed"))

	if debug:
		print("[MC-OrbitalFlow] Signals connected")


func _compute_transition_target(zone_id:String) -> Vector2:
	if terrain_generator == null:
		return Vector2.ZERO

	var zone_info: Dictionary = terrain_generator.get_landing_zone_world_info(zone_id)
	if not zone_info.is_empty():
		var center_x: float = float(zone_info.get("center_x", 0.0))
		var surface_y: float = float(zone_info.get("surface_y", 600.0))
		var spawn_altitude: float = float(
			terrain_generator.get_meta("spawn_altitude_fallback", 12000.0)
		)
		return Vector2(center_x, surface_y - spawn_altitude)

	# Fallback to terrain center
	var cx := float(terrain_generator.get_center_x())
	var sy := float(terrain_generator.get_highest_point_y())
	return Vector2(cx, sy - 12000.0)



# ==================================================================
# STEP 5: Add Signal Handlers for OrbitalView
# ==================================================================

func connect_orbital_view_signals() -> void:
	if orbital_view == null:
		return
	
	if not orbital_view.is_connected("zone_selected", Callable(self, "_on_orbital_zone_selected")):
		orbital_view.connect("zone_selected", Callable(self, "_on_orbital_zone_selected"))
	
	if not orbital_view.is_connected("transition_started", Callable(self, "_on_orbital_transition_started")):
		orbital_view.connect("transition_started", Callable(self, "_on_orbital_transition_started"))
	
	if not orbital_view.is_connected("transition_completed", Callable(self, "_on_orbital_transition_completed")):
		orbital_view.connect("transition_completed", Callable(self, "_on_orbital_transition_completed"))
	
	if debug:
		print("[MC-OrbitalFlow] OrbitalView signals connected")

func _on_orbital_transition_started() -> void:
	if debug:
		print("[MissionOrbitalFlow] Orbital transition started")

	var target_pos: Vector2 = transition_target_position

	# Fallback if, for some reason, we never set it on zone selection
	if target_pos == Vector2.ZERO and terrain_generator != null:
		var center_x: float = float(terrain_generator.get_center_x())
		var surface_y: float = float(terrain_generator.get_highest_point_y())
		target_pos = Vector2(center_x, surface_y - 12000.0)
		if debug:
			print("[MissionOrbitalFlow] No target position stored, using fallback: ", target_pos)

	if orbital_view != null and orbital_view.has_method("begin_zoom_to_position"):
		orbital_view.begin_zoom_to_position(target_pos)
		if debug:
			print("[MissionOrbitalFlow] Camera zooming to: ", target_pos)


func _on_orbital_zone_selected(zone_id: String) -> void:
	if debug:
		print("[MissionOrbitalFlow] Orbital zone selected: ", zone_id)

	# Store selected zone
	chosen_zone_id = zone_id

	# Ensure spawn block exists and record zone for spawn positioning
	if not mission_config.has("spawn"):
		mission_config["spawn"] = {}
	mission_config["spawn"]["start_above_zone_id"] = zone_id

	# Compute target camera position for transition
	transition_target_position = _compute_transition_target(zone_id)

	if debug:
		print("[MissionOrbitalFlow] Computed transition target: ", transition_target_position)

func _on_orbital_transition_completed() -> void:
	if orbital_view != null and orbital_view.has_method("hideorbital_view"):
		orbital_view.hideorbital_view()

	emit_signal("orbital_ready_to_land", chosen_zone_id)
