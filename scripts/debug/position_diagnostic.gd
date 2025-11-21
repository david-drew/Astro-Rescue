## res://scripts/debug/position_diagnostic.gd
extends Node2D

##
# Position Diagnostic
# 
# Add this to your scene to understand what's really happening
# with terrain and lander positions.
##

@export var lander: Node2D
@export var terrain_generator: TerrainGenerator
@export var camera: Camera2D

func _ready():
	await get_tree().physics_frame
	await get_tree().physics_frame
	diagnose()

func _input(event):
	if event.is_action_pressed("ui_page_down"):
		diagnose()

func diagnose():
	print("\n" + "=======================================================================================================")
	print("POSITION DIAGNOSTIC")
	print("=======================================================================================================")
	
	# Viewport info
	var viewport_rect = get_viewport_rect()
	print("\n--- VIEWPORT ---")
	print("Size: ", viewport_rect.size)
	print("Center: ", viewport_rect.size / 2)
	
	# Camera info
	if camera:
		print("\n--- CAMERA ---")
		print("Position: ", camera.global_position)
		print("Zoom: ", camera.zoom)
		
		# Calculate what Y range camera can see
		var viewport_height = viewport_rect.size.y
		var zoom_factor = camera.zoom.y
		var visible_height = viewport_height / zoom_factor
		
		var cam_top = camera.global_position.y - (visible_height / 2)
		var cam_bottom = camera.global_position.y + (visible_height / 2)
		
		print("Camera sees Y from: ", cam_top, " to ", cam_bottom)
		print("Visible height: ", visible_height, " pixels")
	
	# Terrain info
	if terrain_generator:
		print("\n--- TERRAIN ---")
		
		var terrain_root = terrain_generator.get_node_or_null(terrain_generator.terrain_root_path)
		if terrain_root:
			var terrain_visual = terrain_root.get_node_or_null("TerrainVisual") as Polygon2D
			if terrain_visual and terrain_visual.polygon.size() > 0:
				# Find actual min/max Y in terrain
				var min_y = terrain_visual.polygon[0].y
				var max_y = terrain_visual.polygon[0].y
				var min_x = terrain_visual.polygon[0].x
				var max_x = terrain_visual.polygon[0].x
				
				for point in terrain_visual.polygon:
					if point.y < min_y: min_y = point.y
					if point.y > max_y: max_y = point.y
					if point.x < min_x: min_x = point.x
					if point.x > max_x: max_x = point.x
				
				print("Actual terrain Y range: ", min_y, " to ", max_y)
				print("Actual terrain X range: ", min_x, " to ", max_x)
				print("Terrain highest point: ", min_y, " (remember: lower Y = higher up)")
				print("Terrain lowest point: ", max_y)
				
				print("\nFrom terrain_generator methods:")
				print("get_highest_point_y(): ", terrain_generator.get_highest_point_y())
				print("get_center_x(): ", terrain_generator.get_center_x())
				print("get_bounds(): ", terrain_generator.get_bounds())
				
				# Check if camera can see terrain
				if camera:
					var cam_top = camera.global_position.y - (viewport_rect.size.y / camera.zoom.y / 2)
					var cam_bottom = camera.global_position.y + (viewport_rect.size.y / camera.zoom.y / 2)
					
					if cam_bottom > min_y and cam_top < max_y:
						print("✅ Camera CAN see terrain")
					else:
						print("❌ Camera CANNOT see terrain")
						print("   Terrain is from Y=", min_y, " to Y=", max_y)
						print("   Camera sees Y=", cam_top, " to Y=", cam_bottom)
			else:
				print("❌ Terrain visual not found or empty!")
		else:
			print("❌ Terrain root not found!")
	
	# Lander info
	if lander:
		print("\n--- LANDER ---")
		print("Position: ", lander.global_position)
		
		if terrain_generator:
			var surface_y = terrain_generator.get_highest_point_y()
			var altitude = surface_y - lander.global_position.y
			print("Surface Y: ", surface_y)
			print("Altitude above surface: ", altitude, " pixels")
			
			if lander is LanderController:
				print("Altitude reference Y: ", lander.altitude_reference_y)
				print("get_altitude_estimate_meters(): ", lander.get_altitude_estimate_meters())
		
		# Check if camera can see lander
		if camera:
			var cam_top = camera.global_position.y - (viewport_rect.size.y / camera.zoom.y / 2)
			var cam_bottom = camera.global_position.y + (viewport_rect.size.y / camera.zoom.y / 2)
			var cam_left = camera.global_position.x - (viewport_rect.size.x / camera.zoom.x / 2)
			var cam_right = camera.global_position.x + (viewport_rect.size.x / camera.zoom.x / 2)
			
			var lander_visible = (
				lander.global_position.y > cam_top and
				lander.global_position.y < cam_bottom and
				lander.global_position.x > cam_left and
				lander.global_position.x < cam_right
			)
			
			if lander_visible:
				print("✅ Camera CAN see lander")
			else:
				print("❌ Camera CANNOT see lander")
				print("   Lander at: ", lander.global_position)
				print("   Camera sees X: ", cam_left, " to ", cam_right)
				print("   Camera sees Y: ", cam_top, " to ", cam_bottom)
	
	# Mission config check
	print("\n--- MISSION CONFIG ---")
	if Engine.has_singleton("GameState"):
		var mission_config = GameState.current_mission_config
		if not mission_config.is_empty():
			var spawn_config = mission_config.get("spawn", {})
			if not spawn_config.is_empty():
				print("Spawn config from mission:")
				print("  start_above_zone_id: ", spawn_config.get("start_above_zone_id"))
				print("  height_above_surface: ", spawn_config.get("height_above_surface"))
				print("  offset_x: ", spawn_config.get("offset_x"))
				
				# Check terrain config
				var terrain_config = mission_config.get("terrain", {})
				print("\nTerrain config from mission:")
				print("  baseline_y: ", terrain_config.get("baseline_y"))
				print("  height_variation: ", terrain_config.get("height_variation"))
				
				var landing_zones = terrain_config.get("landing_zones", [])
				print("  landing_zones count: ", landing_zones.size())
				for zone in landing_zones:
					if typeof(zone) == TYPE_DICTIONARY:
						print("    - id: ", zone.get("id"), " center_x: ", zone.get("center_x"))
	
	# Summary
	print("\n--- SUMMARY ---")
	if camera and lander and terrain_generator:
		var surface_y = terrain_generator.get_highest_point_y()
		var altitude = surface_y - lander.global_position.y
		
		print("Distance from lander to terrain: ", altitude, " pixels")
		
		if altitude < 0:
			print("⚠️  LANDER IS BELOW TERRAIN! (negative altitude)")
		elif altitude < 100:
			print("⚠️  LANDER IS VERY CLOSE TO TERRAIN!")
		elif altitude < 1000:
			print("✅ Lander at reasonable low altitude")
		elif altitude < 10000:
			print("✅ Lander at good altitude")
		elif altitude > 50000:
			print("⚠️  LANDER IS EXTREMELY HIGH!")
		else:
			print("✅ Lander at high but reasonable altitude")
	
	print("\n" + "=======================================================================================================" + "\n")

func _process(_delta):
	# Show live positions (toggle with F key)
	if Input.is_action_just_pressed("ui_text_completion_replace"):
		var show_live = get_meta("show_live_debug", false)
		set_meta("show_live_debug", not show_live)
		
		if not show_live:
			print("\n[Live debug ON - press F to toggle off]")
		else:
			print("\n[Live debug OFF]")
	
	if get_meta("show_live_debug", false):
		if lander and terrain_generator:
			var surface_y = terrain_generator.get_highest_point_y()
			var altitude = surface_y - lander.global_position.y
			print("Lander: ", lander.global_position, " | Altitude: ", altitude)
