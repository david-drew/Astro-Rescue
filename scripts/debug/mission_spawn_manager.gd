## res://scripts/modes/mode1/mission_spawn_manager.gd
extends Node
class_name MissionSpawnManager

##
# MissionSpawnHandler
#
# Correctly handles lander spawning from mission configuration.
# 
# FIXES:
# 1. Properly interprets "height_above_surface" as ABOVE (negative Y)
# 2. Correctly uses landing zone center_x vs terrain center
# 3. Handles offset_x properly
##

static func spawn_lander_from_mission_config(
	lander: LanderController,
	mission_config: Dictionary,
	terrain_generator: TerrainGenerator
) -> void:
	"""
	Spawn lander based on mission configuration.
	This is a static helper so it can be called from anywhere.
	"""
	
	var spawn_config: Dictionary = mission_config.get("spawn", {})
	
	if spawn_config.is_empty():
		push_warning("[MissionSpawnHandler] No spawn config, using defaults")
		_spawn_with_defaults(lander, terrain_generator)
		return
	
	# Parse spawn configuration
	var zone_id: String = spawn_config.get("start_above_zone_id", "")
	var height_above: float = float(spawn_config.get("height_above_surface", 3000.0))
	var offset_x: float = float(spawn_config.get("offset_x", 0.0))
	var initial_velocity: Array = spawn_config.get("initial_velocity", [0.0, 0.0])
	
	# Determine spawn position
	var spawn_pos: Vector2 = _calculate_spawn_position(
		zone_id,
		height_above,
		offset_x,
		terrain_generator
	)
	
	# Position lander
	lander.global_position = spawn_pos
	
	# Set altitude reference
	var surface_y: float = terrain_generator.get_highest_point_y()
	lander.altitude_reference_y = surface_y
	
	# Set initial velocity if specified
	if initial_velocity.size() >= 2:
		lander.linear_velocity = Vector2(
			float(initial_velocity[0]),
			float(initial_velocity[1])
		)
	
	print("[MissionSpawnHandler] Lander spawned:")
	print("  Position: ", spawn_pos)
	print("  Surface Y: ", surface_y)
	print("  Altitude: ", surface_y - spawn_pos.y, " pixels")
	print("  Height config: ", height_above)


static func _calculate_spawn_position(
	zone_id: String,
	height_above: float,
	offset_x: float,
	terrain_generator: TerrainGenerator
) -> Vector2:
	"""
	Calculate the spawn position based on configuration.
	
	IMPORTANT: In Godot, +Y is DOWN, so:
	- To go ABOVE something, we SUBTRACT from Y
	- surface_y - height_above = position above surface
	"""
	
	var spawn_x: float = 0.0
	var spawn_y: float = 0.0
	
	# Get surface Y (highest point of terrain)
	var surface_y: float = terrain_generator.get_highest_point_y()
	
	# Determine X position
	if zone_id != "" and zone_id != "any":
		# Spawn above a specific landing zone
		var zone_info: Dictionary = terrain_generator.get_landing_zone_world_info(zone_id)
		
		if zone_info.is_empty():
			push_warning("[MissionSpawnHandler] Landing zone '", zone_id, "' not found, using terrain center")
			spawn_x = terrain_generator.get_center_x()
		else:
			spawn_x = float(zone_info.get("center_x", terrain_generator.get_center_x()))
			# Update surface_y to the landing zone's surface if available
			if zone_info.has("surface_y"):
				surface_y = float(zone_info["surface_y"])
	else:
		# No specific zone, use terrain center
		spawn_x = terrain_generator.get_center_x()
	
	# Apply X offset
	spawn_x += offset_x
	
	# Calculate Y position
	# CRITICAL FIX: height_above is a POSITIVE number meaning "above"
	# In Godot, to go UP (above), we SUBTRACT from Y
	spawn_y = surface_y - height_above
	
	print("[MissionSpawnHandler] Spawn calculation:")
	print("  Zone ID: ", zone_id)
	print("  Surface Y: ", surface_y)
	print("  Height above config: ", height_above)
	print("  Calculated spawn Y: ", spawn_y, " (should be ", surface_y, " - ", height_above, ")")
	print("  Spawn X: ", spawn_x, " (offset: ", offset_x, ")")
	
	return Vector2(spawn_x, spawn_y)


static func _spawn_with_defaults(
	lander: LanderController,
	terrain_generator: TerrainGenerator
) -> void:
	"""Fallback spawn using default values"""
	
	var center_x: float = terrain_generator.get_center_x()
	var surface_y: float = terrain_generator.get_highest_point_y()
	var default_height: float = 3000.0
	
	lander.global_position = Vector2(center_x, surface_y - default_height)
	lander.altitude_reference_y = surface_y
	
	print("[MissionSpawnHandler] Using default spawn:")
	print("  Position: ", lander.global_position)


static func validate_spawn_config(mission_config: Dictionary) -> Dictionary:
	"""
	Validate spawn configuration and return any issues.
	Returns empty dict if valid, otherwise dict with error messages.
	"""
	
	var errors: Dictionary = {}
	var spawn_config: Dictionary = mission_config.get("spawn", {})
	
	if spawn_config.is_empty():
		errors["missing"] = "No spawn configuration found"
		return errors
	
	# Check required fields
	if not spawn_config.has("height_above_surface"):
		errors["height"] = "Missing height_above_surface"
	else:
		var height = float(spawn_config["height_above_surface"])
		if height < 0:
			errors["height_negative"] = "height_above_surface is negative (should be positive)"
		if height > 100000:
			errors["height_excessive"] = "height_above_surface very large (>100000), might be off-screen"
	
	# Check zone ID if specified
	if spawn_config.has("start_above_zone_id"):
		var zone_id = spawn_config["start_above_zone_id"]
		if zone_id == "":
			errors["zone_empty"] = "start_above_zone_id is empty string"
	
	return errors


static func debug_print_spawn_info(
	mission_config: Dictionary,
	terrain_generator: TerrainGenerator
) -> void:
	"""Print detailed spawn information for debugging"""
	
	print("\n========== SPAWN DEBUG INFO ==========")
	
	var spawn_config: Dictionary = mission_config.get("spawn", {})
	var terrain_config: Dictionary = mission_config.get("terrain", {})
	
	print("\n--- Mission Spawn Config ---")
	print(JSON.stringify(spawn_config, "  "))
	
	print("\n--- Terrain Info ---")
	print("Bounds: ", terrain_generator.get_bounds())
	print("Highest Y: ", terrain_generator.get_highest_point_y())
	print("Center X: ", terrain_generator.get_center_x())
	
	print("\n--- Landing Zones ---")
	var landing_zones: Array = terrain_config.get("landing_zones", [])
	for zone_cfg in landing_zones:
		if typeof(zone_cfg) == TYPE_DICTIONARY:
			var zone_id = zone_cfg.get("id", "unknown")
			var zone_info = terrain_generator.get_landing_zone_world_info(zone_id)
			print("Zone '", zone_id, "': ", zone_info)
	
	print("\n--- Calculated Spawn Position ---")
	var zone_id: String = spawn_config.get("start_above_zone_id", "")
	var height_above: float = float(spawn_config.get("height_above_surface", 3000.0))
	var offset_x: float = float(spawn_config.get("offset_x", 0.0))
	
	var calculated_pos = _calculate_spawn_position(
		zone_id,
		height_above,
		offset_x,
		terrain_generator
	)
	
	print("Final spawn position: ", calculated_pos)
	print("Altitude above surface: ", terrain_generator.get_highest_point_y() - calculated_pos.y)
	
	print("\n--- Validation ---")
	var errors = validate_spawn_config(mission_config)
	if errors.is_empty():
		print("✅ Spawn config is valid")
	else:
		print("⚠️  Spawn config has issues:")
		for key in errors:
			print("  - ", errors[key])
	
	print("======================================\n")
