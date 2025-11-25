# res://scripts/modes/mode1/mission_setup.gd
class_name MissionSetup
extends RefCounted

var debug:bool = false

# Cached scene refs
var terrain_generator: Node = null
var terrain_tiles_controller: Node = null
var lander: Node2D = null
var hud: Node = null
var orbital_view: Node = null
var player: Node = null
var world_node: Node = null

# NodePaths injected from MC
var terrain_generator_path: NodePath = NodePath("")
var terrain_tiles_controller_path: NodePath = NodePath("")
var lander_path: NodePath = NodePath("")
var hud_path: NodePath = NodePath("")
var orbital_view_path: NodePath = NodePath("")
var mission_data_dir: String = "res://data/missions"

# Basic config/stats needed for HUD/timer
var mission_time_limit: float = -1.0
var mission_elapsed_time: float = 0.0

var mission_id:String = ""
var mission_config:Dictionary = {}

var WSM:WorldSimManager = WorldSimManager.new()

func refresh_scene_refs(scene: Node) -> void:
	terrain_generator = null
	terrain_tiles_controller = null
	lander = null
	hud = null
	orbital_view = null
	player = null
	world_node = null

	if scene == null:
		return

	# World root
	world_node = scene.get_node_or_null("World")

	# Terrain generator
	if terrain_generator_path != NodePath(""):
		var tg := scene.get_node_or_null(terrain_generator_path)
		if tg != null:
			terrain_generator = tg

	# Terrain tiles controller
	if terrain_tiles_controller_path != NodePath(""):
		var ttc := scene.get_node_or_null(terrain_tiles_controller_path)
		if ttc != null:
			terrain_tiles_controller = ttc

	# HUD
	if hud_path != NodePath(""):
		var h := scene.get_node_or_null(hud_path)
		if h != null:
			hud = h

	# Orbital view
	if orbital_view_path != NodePath(""):
		var ov := scene.get_node_or_null(orbital_view_path)
		if ov != null:
			orbital_view = ov

	# Lander
	if lander_path != NodePath(""):
		var ln := scene.get_node_or_null(lander_path)
		if ln != null:
			lander = ln as Node2D

	if lander == null and world_node != null:
		var ln2 := world_node.get_node_or_null("Player/VehicleLander")
		if ln2 != null:
			lander = ln2 as Node2D
		elif world_node.has_node("Lander"):
			var ln3 := world_node.get_node_or_null("Lander")
			if ln3 != null:
				lander = ln3 as Node2D

	# Player
	if world_node != null:
		var p := world_node.get_node_or_null("Player")
		if p != null:
			player = p

func _load_mission_config() -> void:
	mission_config.clear()

	# 1) Decide which mission we’re playing
	if mission_id == "":
		# Training path / new game: ask WorldSim which training mission is next
		if ! GameState.training_complete:
			mission_id = WSM.get_next_training_mission_id()
		else:
			push_warning("[MissionController] _mission_id is empty and mission is not marked training.")
			return

	# 2) Fetch config from WorldSim / MissionRegistry
	mission_config = WSM.get_mission_config(mission_id)

	if mission_config.is_empty():
		push_warning("[MC-Setup] Failed to load mission config for mission_id=" + mission_id)
		return

	# 3) If your JSON also contains an 'id' field, ensure consistency
	var json_id: String = str(mission_config.get("id", mission_id))
	mission_id = json_id

func apply_mission_terrain(mission_config: Dictionary, debug_logging: bool) -> void:
	# Terrain generator must be bound via refresh_scene_refs()
	if terrain_generator == null:
		return

	var terrain_config: Dictionary = mission_config.get("terrain", {})
	if terrain_config.is_empty():
		return

	if debug_logging:
		print("[MissionSetup] Applying terrain config: ", terrain_config)

	# Generate the terrain if the generator supports it
	if terrain_generator.has_method("generate_terrain"):
		terrain_generator.generate_terrain(terrain_config)

	# Notify gravity/physics systems that terrain is ready.
	# We walk from the terrain_generator's parent instead of using get_tree().
	var parent := terrain_generator.get_parent()
	if parent != null:
		# Adjust this name if your actual Gravity manager node differs
		var gravity_mgr := parent.get_node_or_null("GravityFieldManager")
		if gravity_mgr != null and gravity_mgr.has_method("update_from_terrain"):
			gravity_mgr.update_from_terrain(terrain_generator)

	# Optional global signal if other systems listen.
	EventBus.emit_signal("terrain_generated", terrain_generator)

	# DEBUG: landing zones info if available
	if terrain_generator.has_method("get_landing_zone_ids"):
		var ids: Array = terrain_generator.get_landing_zone_ids()
		print("[MC-Setup] Terrain zones now: ", ids)
	elif "landing_zones" in terrain_generator:
		var zones = terrain_generator.landing_zones
		if typeof(zones) == TYPE_DICTIONARY:
			print("[MC-Setup] Terrain zones dict keys: ", zones.keys())


func apply_mission_tiles(mission_config: Dictionary, debug_logging: bool) -> void:
	if terrain_tiles_controller == null:
		return
	if mission_config.is_empty():
		return

	if terrain_tiles_controller.has_method("build_tiles_from_mission"):
		terrain_tiles_controller.build_tiles_from_mission(mission_config)
		if debug_logging:
			print("[MC-Setup] Built tiles from mission config")

func position_lander_from_spawn(mission_config: Dictionary, chosen_zone_id: String, debug_logging: bool) -> void:
	if lander == null:
		lander = GameState.vehicle.lander
		if lander == null:
			if debug_logging:
				print("[MC-Setup] Cannot position lander: no lander reference")
			return

	# -------------------------
	# 1) If a landing zone was selected from OrbitalView, try that first
	# -------------------------
	if chosen_zone_id != "":
		if terrain_generator != null and terrain_generator.has_method("get_landing_zone_world_info"):
			var zone_info: Dictionary = terrain_generator.get_landing_zone_world_info(chosen_zone_id)
			if not zone_info.is_empty():
				var spawn_pos: Vector2 = _compute_spawn_from_zone(zone_info, mission_config)

				_teleport_lander_to(spawn_pos, debug_logging, "zone '%s'" % chosen_zone_id)
				return
			else:
				if debug_logging:
					print("[MC-Setup] Zone '%s' not found; falling back to mission default spawn." % chosen_zone_id)
		else:
			if debug_logging:
				print("[MC-Setup] No terrain_generator or get_landing_zone_world_info; falling back to mission default spawn.")

	# -------------------------
	# 2) Fallback: use mission spawn config
	# -------------------------
	var spawn_cfg: Dictionary = mission_config.get("spawn", {})
	if spawn_cfg.is_empty():
		if debug_logging:
			print("[MC-Setup] WARN: Mission has no 'spawn' block; using current lander position.")
		return

	var spawn_pos: Vector2 = spawn_cfg.get("position", lander.global_position)

	# NOTE: You previously hard-coded backup spawn pos; keep that if still desired:
	# spawn_pos = Vector2(500.0, -10000.0)
	# print("\tUsing backup spawn POS")

	_teleport_lander_to(spawn_pos, debug_logging, "fixed mission spawn")



func apply_lander_loadout(mission_config: Dictionary, debug: bool) -> void:
	if lander == null and lander_path != NodePath(""):
		lander = GameState.vehicle.lander
		if lander == null:
			return

	var loadout_config: Dictionary = mission_config.get("lander_loadout", {})
	if loadout_config.is_empty():
		return

	if lander.has_method("apply_mission_loadout"):
		lander.call("apply_mission_loadout", loadout_config)
	else:
		if debug:
			print("[MC-Setup] Lander does not implement apply_mission_loadout")

func apply_mission_modifiers(mission_config: Dictionary, debug: bool) -> void:
	print("apply_mission_modifiers: Deprectated? Delete?")
	pass
	
func _apply_mission_modifiers() -> void:
	##
	# Apply mission modifiers to the lander (fuel, thrust, rotation, etc.)
	##
	if lander == null:
		if debug:
			print("[MC-Setup] Cannot apply modifiers: no lander reference")
		return

	var modifiers: Dictionary = {}
	if GameState.current_mission_config:
		modifiers = GameState.mission_config.get("mission_modifiers", {})
		
	if modifiers.is_empty():
		if debug:
			print("[MC-Setup] No mission modifiers to apply")
		return
	
	if debug:
		print("[MC-Setup] Applying mission modifiers: ", modifiers)
	
	# Fuel capacity multiplier
	
	if "fuel_capacity_multiplier" in modifiers:
		var multiplier := float(modifiers.get("fuel_capacity_multiplier", 1.0))
		if "fuel_capacity" in lander:
			var base_fuel: float = lander.get("fuel_capacity")
			lander.set("fuel_capacity", base_fuel * multiplier)
			if debug:
				print("[MC-Setup] Fuel capacity: ", base_fuel, " -> ", base_fuel * multiplier)
	
	# Thrust multiplier
	if "thrust_multiplier" in modifiers:
		var multiplier := float(modifiers.get("thrust_multiplier", 1.0))
		if "base_thrust_force" in lander:
			var base_thrust: float = lander.get("base_thrust_force")
			lander.set("base_thrust_force", base_thrust * multiplier)
			if debug:
				print("[MC-Setup] Thrust: ", base_thrust, " -> ", base_thrust * multiplier)
	
	# Rotation acceleration multiplier
	if "rotation_accel_multiplier" in modifiers:
		var multiplier := float(modifiers.get("rotation_accel_multiplier", 1.0))
		if "rotation_accel" in lander:
			var base_rotation: float = lander.get("rotation_accel")
			lander.set("rotation_accel", base_rotation * multiplier)
			if debug:
				print("[MC-Setup] Rotation accel: ", base_rotation, " -> ", base_rotation * multiplier)
	
	# Max angular speed multiplier
	if "max_angular_speed_multiplier" in modifiers:
		var multiplier := float(modifiers.get("max_angular_speed_multiplier", 1.0))
		if "max_angular_speed" in lander:
			var base_speed: float = lander.get("max_angular_speed")
			lander.set("max_angular_speed", base_speed * multiplier)
			if debug:
				print("[MC-Setup] Max angular speed: ", base_speed, " -> ", base_speed * multiplier)
	
	# Starting fuel ratio
	if "start_fuel_ratio" in modifiers:
		var ratio := float(modifiers.get("start_fuel_ratio", 1.0))
		if lander.has_method("set_fuel_ratio"):
			lander.call("set_fuel_ratio", ratio)
			if debug:
				print("[MC-Setup] Starting fuel ratio: ", ratio)
				
		elif "_current_fuel" in lander and "fuel_capacity" in lander:
			var capacity: float = lander.get("fuel_capacity")
			lander.set("_current_fuel", capacity * ratio)
			if debug:
				print("[MC-Setup] Starting fuel: ", capacity * ratio)


func apply_mission_hud_config(mission_config: Dictionary, debug: bool) -> void:
	##
	# Configure HUD visibility based on mission settings
	##
	if hud == null:
		if debug:
			print("[MC-Setup] Cannot apply HUD config: no HUD reference")
		return
	
	var hud_config: Dictionary = mission_config.get("hud_instruments", {})
	if hud_config.is_empty():
		if debug:
			print("[MC-Setup] No HUD config to apply")
		return
	
	if debug:
		print("[MC-Setup] Applying HUD config: ", hud_config)
	
	# Check if player can override HUD settings
	var allow_override := bool(hud_config.get("allow_player_override", true))
	
	# Apply each HUD setting if the HUD has the corresponding method/property
	if hud_config.has("show_altitude"):
		var show := bool(hud_config.get("show_altitude", true))
		if hud.has_method("set_altitude_visible"):
			hud.call("set_altitude_visible", show)
		elif "show_altitude" in hud:
			hud.set("show_altitude", show)
		if debug:
			print("[MC-Setup] HUD altitude: ", show)
	
	if hud_config.has("show_fuel"):
		var show := bool(hud_config.get("show_fuel", true))
		if hud.has_method("set_fuel_visible"):
			hud.call("set_fuel_visible", show)
		elif "show_fuel" in hud:
			hud.set("show_fuel", show)
		if debug:
			print("[MC-Setup] HUD fuel: ", show)
	
	if hud_config.has("show_wind"):
		var show := bool(hud_config.get("show_wind", false))
		if hud.has_method("set_wind_visible"):
			hud.call("set_wind_visible", show)
		elif "show_wind" in hud:
			hud.set("show_wind", show)
		if debug:
			print("[MC-Setup] HUD wind: ", show)
	
	if hud_config.has("show_gravity"):
		var show := bool(hud_config.get("show_gravity", true))
		if hud.has_method("set_gravity_visible"):
			hud.call("set_gravity_visible", show)
		elif "show_gravity" in hud:
			hud.set("show_gravity", show)
		if debug:
			print("[MC-Setup] HUD gravity: ", show)
	
	if hud_config.has("show_timer"):
		var show := bool(hud_config.get("show_timer", true))
		if hud.has_method("set_timer_visible"):
			hud.call("set_timer_visible", show)
		elif "show_timer" in hud:
			hud.set("show_timer", show)
		if debug:
			print("[MC-Setup] HUD timer: ", show)
	
	# Store override permission if HUD supports it
	if "allow_player_override" in hud:
		hud.set("allow_player_override", allow_override)


func update_hud_timer(elapsed_time: float, time_limit: float) -> void:
	if hud == null:
		return
	if not hud.has_method("update_mission_timer"):
		return

	var remaining: float = time_limit
	if time_limit > 0.0:
		remaining = max(0.0, time_limit - elapsed_time)

	hud.call("update_mission_timer", elapsed_time, remaining)

func hide_landing_gameplay(debug_logging: bool) -> void:
	# Switch player back to HQ mode
	set_player_vehicle_mode("hq")

	# Deactivate lander
	if lander != null and lander.has_method("set_active"):
		lander.set_active(false)

	# Hide world
	if world_node != null:
		world_node.visible = false
		if debug_logging:
			print("[MissionSetup] World node hidden")

	# Hide and freeze lander
	if lander != null:
		lander.visible = false
		if lander is RigidBody2D:
			lander.freeze = true
			if debug_logging:
				print("[MissionSetup] Lander frozen (physics disabled)")
		if debug_logging:
			print("[MissionSetup] Lander hidden")

	# Hide terrain
	if terrain_generator != null and terrain_generator.has_method("get_terrain_body"):
		var terrain_body: StaticBody2D = terrain_generator.get_terrain_body()
		if terrain_body != null:
			terrain_body.visible = false

	# Hide terrain tiles
	if terrain_tiles_controller != null and terrain_tiles_controller.has_method("hide_tiles"):
		terrain_tiles_controller.hide_tiles()

	if debug_logging:
		print("[MissionSetup] Landing gameplay hidden")

func show_landing_gameplay(mission_config: Dictionary, chosen_zone_id: String, debug_logging: bool) -> void:
	if world_node != null:
		world_node.visible = true
		if debug_logging:
			print("[MissionSetup] World node shown")

	# Show terrain
	if terrain_generator != null and terrain_generator.has_method("get_terrain_body"):
		var terrain_body: StaticBody2D = terrain_generator.get_terrain_body()
		if terrain_body != null:
			terrain_body.visible = true

	# Show terrain tiles
	if terrain_tiles_controller != null and terrain_tiles_controller.has_method("show_tiles"):
		terrain_tiles_controller.show_tiles()

	# Position lander (still frozen, if RigidBody2D)
	if GameState.current_mission_config:
		position_lander_from_spawn(GameState.current_mission_config, chosen_zone_id, debug )

	# Switch to lander mode
	set_player_vehicle_mode("lander")

	# Show and unfreeze lander
	if lander != null:
		lander.visible = true

		if lander.has_method("set_active"):
			lander.set_active(true)

		if lander is RigidBody2D:
			lander.freeze = false

		# Reset velocities (defensive)
		if "linear_velocity" in lander:
			lander.linear_velocity = Vector2.ZERO
		if "angular_velocity" in lander:
			lander.angular_velocity = 0.0

		if debug_logging:
			print("[MissionSetup] Lander unfrozen and shown at position: ", lander.global_position)

	if debug_logging:
		print("[MC-Setup] Landing gameplay shown")


func enable_gameplay_camera(debug: bool) -> void:
	# Enable the gameplay camera (usually attached to lander or separate)

	# Camera on lander
	if lander != null and lander.has_node("Camera2D"):
		var cam := lander.get_node("Camera2D") as Camera2D
		if cam != null:
			cam.enabled = true
			if debug:
				print("[MC-Setup] Lander camera enabled")


func set_player_vehicle_mode(mode: String, phase: Dictionary = {}) -> void:
	var p:Node2D = GameState.player
	if p == null:
		EventBus.emit_signal("set_vehicle_mode", mode)
		return

		match mode:
			"lander":           p.enterlander()
			"buggy", "atv":     p.enter_buggy(phase)
			"eva":              p.enter_eva()
			_:                  p.enter_hq()

func _compute_spawn_from_zone(zone_info: Dictionary, mission_config: Dictionary) -> Vector2:
	# Try to build a spawn position from zone info + mission spawn settings.
	var center_x: float = float(zone_info.get("center_x", 500.0))
	var surface_y: float = float(zone_info.get("surface_y", -9000.0))

	# Use mission spawn.height_above_surface if present, otherwise a sensible default.
	var spawn_block: Dictionary = mission_config.get("spawn", {})
	var default_spawn_height: float = float(spawn_block.get("height_above_surface", 10000.0))

	var spawn_pos: Vector2 = Vector2(center_x, surface_y - default_spawn_height)

	# Optional extra offset if terrain generator encodes it
	if zone_info.has("spawn_offset"):
		spawn_pos.y -= float(zone_info.get("spawn_offset", 0.0))

	return spawn_pos

func _teleport_lander_to(spawn_pos: Vector2, debug_logging: bool, context: String) -> void:
	if lander is RigidBody2D:
		var rb := lander as RigidBody2D
		PhysicsServer2D.body_set_state(
			rb.get_rid(),
			PhysicsServer2D.BODY_STATE_TRANSFORM,
			Transform2D.IDENTITY.translated(spawn_pos)
		)
	else:
		lander.global_position = spawn_pos

	if debug_logging:
		print("[MissionSetup] Positioned lander at %s : %s" % [context, str(spawn_pos)])
