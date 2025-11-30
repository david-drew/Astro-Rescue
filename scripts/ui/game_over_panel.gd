extends Control

@export var debug: bool = false

@onready var title_label: Label    = $VBox/TitleLabel
@onready var message_label: Label  = $VBox/MessageLabel
@onready var return_button: Button = $VBox/ReturnButton

var _last_reason: String = ""
var _last_result: Dictionary = {}

func _ready() -> void:
	visible = false

	if return_button:
		return_button.pressed.connect(_on_return_pressed)


func show_game_over(reason: String, result: Dictionary) -> void:
	_last_reason = reason
	_last_result = result

	if debug:
		print("[GameOverPanel] show_game_over: reason=", reason)

	# Basic title
	if title_label:
		title_label.text = "Game Over"

	# Main message text
	if message_label:
		message_label.text = _build_message(reason, result)

	visible = true

	# Give focus to the button for keyboard/gamepad users
	if return_button:
		return_button.grab_focus()


func _build_message(reason: String, result: Dictionary) -> String:
	var base_message: String = ""

	# Reason-based base text
	if reason == "player_died":
		base_message = "You did not survive the mission."
	elif reason == "lander_destroyed":
		base_message = "Your lander was destroyed."
	elif reason == "timeout":
		base_message = "You ran out of mission time."
	else:
		base_message = "The mission has failed."

	# Optional extra detail from the mission result
	var extra: String = ""
	if result.has("failure_reason"):
		var value = result.get("failure_reason")
		if typeof(value) == TYPE_STRING:
			if value != "":
				extra = value
	elif result.has("failure_cause"):
		var value2 = result.get("failure_cause")
		if typeof(value2) == TYPE_STRING:
			if value2 != "":
				extra = value2

	if extra != "":
		return base_message + "\n\nReason: " + extra

	return base_message


func _on_return_pressed() -> void:
	if debug:
		print("[GameOverPanel] Return to Launch Menu pressed")

	visible = false

	# Notify the game that the player wants to go back to Launch Menu
	EventBus.emit_signal("game_over_return_requested")
