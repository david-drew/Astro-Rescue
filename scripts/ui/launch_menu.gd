## res://scripts/ui/launch_menu.gd
extends Control

##
# LaunchMenu
#
# Responsibilities:
#   - Present the main menu with:
#       1) New Game
#       2) Load Game (stub for now)
#       3) Settings  (stub for now)
#       4) Quit
#   - For now, only "New Game" and "Quit" are wired:
#       - New Game:
#           * Reset the player profile (fresh career).
#       - Quit:
#           * Exit the game.
#
# Assumptions:
#   - GameState is an autoload with a reset_profile() method.
##

@export var debug_logging: bool = false

@onready var new_game_button: Button    = $Panel/VBoxContainer/NewGameButton
@onready var load_game_button: Button   = $Panel/VBoxContainer/LoadGameButton
@onready var settings_button: Button    = $Panel/VBoxContainer/SettingsButton
@onready var quit_button: Button        = $Panel/VBoxContainer/QuitButton

@onready var dialogue_ui:Control = $"../DialoguePanel"
@onready var hq_ui:Control = $"../HQ"
@onready var lander_hud:Control = $"../LanderHUD"

func _ready() -> void:
	#hq_ui.visible = false
	#dialogue_ui.visible = false
	#lander_hud.visible = false
	#print("...print all nodes...")
	#print_all_nodes(get_tree().root)
	
	# Connect buttons if present
	if new_game_button != null and not new_game_button.pressed.is_connected(Callable(self, "_on_new_game_pressed")):
		new_game_button.pressed.connect(Callable(self, "_on_new_game_pressed"))

	if load_game_button != null and not load_game_button.pressed.is_connected(Callable(self, "_on_load_game_pressed")):
		load_game_button.pressed.connect(Callable(self, "_on_load_game_pressed"))

	if settings_button != null and not settings_button.pressed.is_connected(Callable(self, "_on_settings_pressed")):
		settings_button.pressed.connect(Callable(self, "_on_settings_pressed"))

	if quit_button != null and not quit_button.pressed.is_connected(Callable(self, "_on_quit_pressed")):
		quit_button.pressed.connect(Callable(self, "_on_quit_pressed"))

func print_all_nodes(node: Node, indent: String = ""):
	print(indent + node.name)
	for child in node.get_children():
		print_all_nodes(child, indent + "  ")

# -------------------------------------------------------------------
# Button handlers
# -------------------------------------------------------------------

func _on_new_game_pressed() -> void:
	if debug_logging:
		print("[LaunchMenu] New Game pressed")

	# 1) Reset the profile to a clean "new career" state
	if GameState.has_method("reset_profile"):
		GameState.reset_profile()
	elif debug_logging:
		print("[LaunchMenu] GameState.reset_profile() not found.")

	var game := get_tree().get_root().get_node("Game")
	if game != null and game.has_method("start_new_career"):
		game.start_new_career()
	else:
		print("ERROR: Critical Error, root Game node not found.")

func _on_load_game_pressed() -> void:
	print("New Game Pressed But We're Doing Nothing")
	# Stub: you can hook this to SaveSystem.
	if debug_logging:
		print("[LaunchMenu] Load Game pressed (not implemented yet)")

func _on_settings_pressed() -> void:
	# Stub: you can open a settings panel or separate scene later.
	if debug_logging:
		print("[LaunchMenu] Settings pressed (not implemented yet)")

func _on_quit_pressed() -> void:
	print("Should Be Quitting")
	if debug_logging:
		print("[LaunchMenu] Quit pressed")

	get_tree().quit()
