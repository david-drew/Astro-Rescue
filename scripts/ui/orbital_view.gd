## res://scripts/modes/mode1/orbital_view.gd
extends Node2D
class_name OrbitalView

##
# OrbitalView - Phase 2 Orbital Selection System
#
# Manages the orbital view screen where players:
# - See a circular planet from orbit
# - Watch their lander orbit around it
# - Select a landing zone
# - View mission dialogue
# - Transition to landing view
#
# Responsibilities:
# - Coordinate PlanetRenderer, landing zone markers, orbiting lander
# - Handle zone selection input
# - Display dialogue
# - Trigger zoom transition to landing gameplay
##

signal zone_selected(zone_id: String)
signal transition_started
signal transition_completed

# -------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------

@export_category("Scene References")
@export var planet_renderer_path: NodePath
@export var orbital_camera_path: NodePath

@export_category("Debug")
@export var debug_logging: bool = true
@export var auto_select_first_zone: bool = false  # For testing

# -------------------------------------------------------------------
# Internal State
# -------------------------------------------------------------------

var _config: Dictionary = {}  # The orbital_view config from mission JSON
var _planet_renderer: Node2D = null
var _orbital_camera: Camera2D = null

var _landing_zones: Array = []  # Array of zone config dictionaries
var _zone_markers: Array = []  # Array of LandingZoneMarker nodes
var _selected_zone_id: String = ""

var rocket_sprite: Sprite2D = null
var rocket_orbit_angle: float = 0.0
var rocket_orbit_radius: float = 450.0
var rocket_orbit_speed: float = 0.8

var _planet_center: Vector2 = Vector2.ZERO
var _planet_radius: float = 320.0

var _prompt_layer: CanvasLayer = null
var _prompt_panel: PanelContainer = null
var _prompt_timer: Timer = null
var _pick_prompt_shown: bool = false			# Blocks popup message when scene transitions


# Orbital view is positioned FAR from gameplay area
#const ORBITAL_VIEW_OFFSET: Vector2 = Vector2(-50000, -50000)

# State machine
enum State {
	HIDDEN,
	INITIALIZING,
	WAITING_FOR_SELECTION,
	TRANSITIONING,
	COMPLETED
}
var _state: State = State.HIDDEN

# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------

func _ready() -> void:
	set_process(false)  # Don't process until initialized
	visible = false
	
	if debug_logging:
		print("[OrbitalView] Ready. Call initialize() to begin.")

func _process(delta: float) -> void:
	match _state:
		State.WAITING_FOR_SELECTION:
			_update_orbit_animation(delta)
		State.TRANSITIONING:
			pass  # Transition handled by camera
			
	# TODO DEBUG DELETE 
	#if Engine.get_physics_frames() % 60 == 0:
	#	var cam := get_viewport().get_camera_2d()
	#	print("Current camera is: ", cam)

func _update_orbit_animation(delta: float) -> void:
	if rocket_sprite == null:
		return
	
	# Rotate lander around planet
	rocket_orbit_angle += rocket_orbit_speed * delta
	if rocket_orbit_angle > TAU:
		rocket_orbit_angle -= TAU
	
	# Calculate position on orbit (relative to planet center)
	var orbit_pos := Vector2(
		cos(rocket_orbit_angle) * rocket_orbit_radius,
		sin(rocket_orbit_angle) * rocket_orbit_radius
	)
	# Position relative to planet (which is at _planet_center)
	rocket_sprite.position = _planet_center + orbit_pos
	
	# Rotate sprite to face tangent to orbit (looks like it's moving)
	rocket_sprite.rotation = rocket_orbit_angle + PI / 2.0

# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func initialize(orbital_config: Dictionary) -> void:
	##
	# Initialize the orbital view with configuration from mission JSON.
	# Called by MissionController before showing orbital view.
	##
	if orbital_config.is_empty():
		push_warning("[OrbitalView] Empty config provided!")
		return
	
	_config = orbital_config
	_state = State.INITIALIZING
	
	if debug_logging:
		print("[OrbitalView] Initializing with config: ", _config)
	
	# Parse configuration
	_parse_config()
	
	# Create visual elements
	_create_planet()
	_create_rocket_sprite()
	_create_landing_zone_markers()
	
	# Setup camera
	_setup_camera()
	
	if debug_logging:
		print("[OrbitalView] Initialization complete")

func show_orbital_view() -> void:
	##
	# Show the orbital view and begin the sequence:
	# 1. Show dialogue (if any)
	# 2. Enable zone selection
	##
	visible = true
	_state = State.WAITING_FOR_SELECTION
	_show_pick_zone_prompt()

	set_process(true)
	
	# Enable orbital camera so we see this view, not gameplay
	if _orbital_camera != null:
		_orbital_camera.enabled = true
		_orbital_camera.make_current()
		if debug_logging:
			print("[OrbitalView] Showing orbital view, camera enabled + current")


func hide_orbital_view() -> void:
	##
	# Hide the orbital view (called after transition to landing)
	##

	# Disable orbital camera so gameplay camera takes over
	if _orbital_camera != null:
		_orbital_camera.enabled = false
		if _orbital_camera.is_current():
			_orbital_camera.clear_current()

	
	if debug_logging:
		print("[OrbitalView] Hidden, camera disabled")
	
	visible = false
	set_process(false)
	_state = State.HIDDEN

func begin_zoom_to_position(target_world_position: Vector2) -> void:
	##
	# Begin camera transition to a specific world position
	# Called by MissionController with the actual landing zone position
	##
	if _orbital_camera != null and _orbital_camera.has_method("begin_zoom_transition"):
		_orbital_camera.begin_zoom_transition(target_world_position)
	else:
		_complete_transition()

func begin_transition_to_landing() -> void:
	##
	# Begin the animated transition from orbital view to landing view.
	# This triggers the camera zoom animation.
	##
	if _selected_zone_id == "":
		push_warning("[OrbitalView] Cannot transition: no zone selected!")
		return
	
	_state = State.TRANSITIONING
	transition_started.emit()
	
	if debug_logging:
		print("[OrbitalView] Beginning transition to landing...")
	
	# Get the actual world position of the landing zone from terrain generator
	# This needs to be passed from MissionController
	# For now, use a signal to request it
	if _orbital_camera != null:
		# Camera will be given target position by MissionController
		# via the begin_zoom_to_position() method
		pass
	else:
		# Fallback: immediate transition
		_complete_transition()

func get_selected_zone_id() -> String:
	return _selected_zone_id

# -------------------------------------------------------------------
# Configuration Parsing
# -------------------------------------------------------------------

func _parse_config() -> void:
	# Planet visual settings
	var planet_cfg: Dictionary = _config.get("planet_visual", {})
	_planet_radius = float(planet_cfg.get("radius", 320.0))
	_planet_center = Vector2.ZERO 				# ORBITAL_VIEW_OFFSET  # Far from gameplay area
	
	# Lander orbit settings
	var rocket_cfg: Dictionary = _config.get("lander_orbit", {})
	rocket_orbit_radius = float(rocket_cfg.get("orbit_radius", 450.0))
	rocket_orbit_speed = float(rocket_cfg.get("orbit_speed", 0.8))
	
	# Landing zones
	_landing_zones = _config.get("landing_zones", [])


# -------------------------------------------------------------------
# Visual Creation
# -------------------------------------------------------------------

func _create_planet() -> void:
	# Get or create PlanetRenderer
	if planet_renderer_path != NodePath(""):
		_planet_renderer = get_node_or_null(planet_renderer_path)
	
	if _planet_renderer == null:
		# Create planet renderer node
		_planet_renderer = Node2D.new()
		_planet_renderer.name = "PlanetRenderer"
		add_child(_planet_renderer)
		
		# For now, just draw a simple circle
		# In a real implementation, you'd use PlanetRenderer.gd
		var planet_sprite := Sprite2D.new()
		planet_sprite.name = "PlanetSprite"
		_planet_renderer.add_child(planet_sprite)
		
		# Create a simple circular texture (placeholder)
		_create_simple_planet_texture(planet_sprite)
	
	_planet_renderer.position = _planet_center
	
	if debug_logging:
		print("[OrbitalView] Planet created at ", _planet_center, " with radius ", _planet_radius)

func _create_simple_planet_texture(sprite: Sprite2D) -> void:
	# Create a simple circular planet using a placeholder texture
	# In production, you'd load actual planet textures
	var planet_cfg: Dictionary = _config.get("planet_visual", {})
	var color_tint: Color = Color(planet_cfg.get("color_tint", "#c0c0c0"))
	
	# For now, we'll use a simple colored circle
	# You can replace this with actual texture loading later
	var image := Image.create(int(_planet_radius * 2), int(_planet_radius * 2), false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	
	# Draw circle
	var center := Vector2(_planet_radius, _planet_radius)
	for x in range(int(_planet_radius * 2)):
		for y in range(int(_planet_radius * 2)):
			var dist := Vector2(x, y).distance_to(center)
			if dist <= _planet_radius:
				# Simple gradient for depth
				var brightness := 1.0 - (dist / _planet_radius) * 0.3
				image.set_pixel(x, y, color_tint * brightness)
	
	var texture := ImageTexture.create_from_image(image)
	sprite.texture = texture
	sprite.centered = true

func _create_rocket_sprite() -> void:
	rocket_sprite = Sprite2D.new()
	rocket_sprite.name = "OrbitingLander"
	add_child(rocket_sprite)
	
	var rocket_image:Image = Image.new()
	var err = rocket_image.load("res://assets/images/rocket_prime_01.png")
	
	if err != OK:
		# Create simple lander visual (triangle pointing right)
		rocket_image = Image.create(32, 32, false, Image.FORMAT_RGBA8)
		rocket_image.fill(Color.TRANSPARENT)
	
		# Draw triangle (simplified lander shape)
		var white := Color.WHITE
		for x in range(16, 28):
			var y_offset := int((x - 16) * 0.6)
			for y in range(16 - y_offset, 16 + y_offset + 1):
				if y >= 0 and y < 32:
					rocket_image.set_pixel(x, y, white)
	
	var rocket_texture := ImageTexture.create_from_image(rocket_image)
	rocket_sprite.texture = rocket_texture
	rocket_sprite.centered = true

	rocket_orbit_angle = -PI / 2.0		# Start at top of orbit
	_update_orbit_animation(0.0)		# Make sure orbit is immediate (otherwise sits in planet center for several seconds)
	
	if debug_logging:
		print("[OrbitalView] Lander sprite created")

func _create_landing_zone_markers() -> void:
	# Clear existing markers
	for marker in _zone_markers:
		if is_instance_valid(marker):
			marker.queue_free()
	_zone_markers.clear()
	
	# Create marker for each landing zone
	for zone_cfg in _landing_zones:
		var marker := _create_zone_marker(zone_cfg)
		if marker != null:
			_zone_markers.append(marker)
	
	if debug_logging:
		print("[OrbitalView] Created ", _zone_markers.size(), " landing zone markers")

func _create_zone_marker(zone_cfg: Dictionary) -> Node2D:
	var zone_id: String = zone_cfg.get("id", "")
	if zone_id == "":
		return null
	
	var angle_deg: float = float(zone_cfg.get("angle_deg", 0.0))
	var angle_rad := deg_to_rad(angle_deg)
	
	var difficulty: String = zone_cfg.get("difficulty", "medium")
	var color: Color = Color(zone_cfg.get("color", "#ffff00"))
	
	# Create marker node
	var marker := Node2D.new()
	marker.name = "ZoneMarker_" + zone_id
	marker.set_meta("zone_id", zone_id)
	marker.set_meta("zone_config", zone_cfg)
	add_child(marker)
	
	# Position on planet surface
	var marker_distance := _planet_radius + 40.0  # Slightly outside planet
	var marker_pos := Vector2(
		_planet_center.x + cos(angle_rad) * marker_distance,
		_planet_center.y + sin(angle_rad) * marker_distance
	)
	marker.position = marker_pos
	
	# Create visual (simple flag/beacon for now)
	var visual := _create_marker_visual(difficulty, color)
	marker.add_child(visual)
	
	# Add click detection area
	var click_area := Area2D.new()
	click_area.name = "ClickArea"
	marker.add_child(click_area)
	
	var collision := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = 20.0
	collision.shape = shape
	click_area.add_child(collision)
	
	click_area.input_event.connect(_on_marker_clicked.bind(zone_id))
	
	return marker

func _create_marker_visual(difficulty: String, color: Color) -> Node2D:
	var visual := Node2D.new()
	visual.name = "Visual"
	
	# Draw a simple flag/beacon icon
	var icon := Sprite2D.new()
	visual.add_child(icon)
	
	# Create flag icon
	var icon_image := Image.create(24, 24, false, Image.FORMAT_RGBA8)
	icon_image.fill(Color.TRANSPARENT)
	
	# Draw flag pole
	for y in range(4, 20):
		icon_image.set_pixel(12, y, Color.WHITE)
	
	# Draw flag
	for x in range(13, 20):
		for y in range(4, 12):
			icon_image.set_pixel(x, y, color)
	
	var icon_texture := ImageTexture.create_from_image(icon_image)
	icon.texture = icon_texture
	icon.centered = true
	
	return visual

# -------------------------------------------------------------------
# Zone Selection
# -------------------------------------------------------------------

func _on_marker_clicked(viewport: Node, event: InputEvent, shape_idx: int, zone_id: String) -> void:
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_select_zone(zone_id)

func _select_zone(zone_id: String) -> void:
	if _selected_zone_id != "":
		if debug_logging:
			print("[OrbitalView] Zone already selected: ", _selected_zone_id)
		return
	
	_selected_zone_id = zone_id
	zone_selected.emit(zone_id)
	
	if debug_logging:
		print("[OrbitalView] Zone selected: ", zone_id)
	
	# Highlight selected marker
	_highlight_selected_marker(zone_id)
	
	# Auto-start transition after brief delay
	await get_tree().create_timer(0.5).timeout
	begin_transition_to_landing()

func _highlight_selected_marker(zone_id: String) -> void:
	for marker in _zone_markers:
		if marker.get_meta("zone_id", "") == zone_id:
			# Pulse or highlight animation
			var tween := create_tween()
			tween.tween_property(marker, "scale", Vector2(1.3, 1.3), 0.2)
			tween.tween_property(marker, "scale", Vector2(1.0, 1.0), 0.2)

# -------------------------------------------------------------------
# Camera Setup
# -------------------------------------------------------------------

func _setup_camera() -> void:
	if orbital_camera_path != NodePath(""):
		_orbital_camera = get_node_or_null(orbital_camera_path) as Camera2D
	
	if _orbital_camera == null:
		_orbital_camera = Camera2D.new()
		_orbital_camera.name = "OrbitalCamera"
		add_child(_orbital_camera)
	
	_orbital_camera.position = _planet_center  # Positioned at orbital view offset
	_orbital_camera.enabled = false  # Will be enabled when view is shown

# -------------------------------------------------------------------
# Transition
# -------------------------------------------------------------------

func _complete_transition() -> void:
	_state = State.COMPLETED

	var _lander = get_node_or_null("/root/Game/World/Player/VehicleLander")
	if _lander:
		_lander.reset_for_new_mission()	
		_activate_lander_camera(_lander)
	else:
		push_warning("[MissionController] Lander not ready; cannot activate lander camera.")

	reset()
	transition_completed.emit()
	
	if debug_logging:
		print("[OrbitalView] Transition complete")


# -------------------------------------------------------------------
# Simple Pick-Zone Prompt (Dialogue Popup)
# -------------------------------------------------------------------

func _show_pick_zone_prompt() -> void:
	if _pick_prompt_shown:
		return
	_pick_prompt_shown = true
	
	if _prompt_layer == null:
		_prompt_layer = CanvasLayer.new()
		_prompt_layer.layer = 50
		add_child(_prompt_layer)

	if _prompt_panel == null:
		_prompt_panel = PanelContainer.new()
		_prompt_panel.name = "PickZonePrompt"
		_prompt_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_prompt_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
		_prompt_panel.offset_top = 20
		_prompt_panel.offset_bottom = 120		# border size

		var label := Label.new()
		label.text = "Pick a landing zone"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		
		label.add_theme_font_size_override("font_size", 48) 			 # default ~24, so 48 = 2×
		
		_prompt_panel.add_child(label)

		_prompt_layer.add_child(_prompt_panel)

	if _prompt_timer == null:
		_prompt_timer = Timer.new()
		_prompt_timer.one_shot = true
		_prompt_timer.wait_time = 5.0
		_prompt_timer.timeout.connect(_hide_pick_zone_prompt)
		add_child(_prompt_timer)

	_prompt_panel.visible = true
	_prompt_timer.start()


func _hide_pick_zone_prompt() -> void:
	if _prompt_panel != null:
		_prompt_panel.visible = false

func _activate_lander_camera(_lander:RigidBody2D) -> void:
	# 1. Disable OrbitalView camera if it exists
	$OrbitalCamera.enabled = false

	# 2. Enable the Lander’s camera
	#var _woild = get_node_or_null("/root/Game/World")
	var lander_cam := _lander.get_node_or_null("LanderCam")
	if lander_cam:
		lander_cam.enabled = true
		lander_cam.make_current()
		#_woild.visible = true
		#_lander.visible = true
	else:
		push_warning("[MissionController] LanderCamera not found under Lander.")

func reset():
	_config = {}  # The orbital_view config from mission JSON
	_planet_renderer = null
	_orbital_camera  = null

	_landing_zones  = []  # Array of zone config dictionaries
	_zone_markers   = []  # Array of LandingZoneMarker nodes
	_selected_zone_id  = ""

	rocket_sprite         = null
	rocket_orbit_angle    = 0.0
	rocket_orbit_radius   = 450.0
	rocket_orbit_speed    = 0.8

	_planet_center = Vector2.ZERO
	_planet_radius = 320.0

	_prompt_layer = null
	_prompt_panel = null
	_prompt_timer = null
	_pick_prompt_shown = false
