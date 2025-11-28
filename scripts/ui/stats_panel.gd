extends Control

@onready var reputation_label: Label = $PlayerStats/HBox/Reputation
@onready var credits_label: Label    = $PlayerStats/HBox/Credits

func _ready() -> void:
	# Connect to stats updates
	if not EventBus.is_connected("update_player_stats", Callable(self, "_on_update_player_stats")):
		EventBus.connect("update_player_stats", Callable(self, "_on_update_player_stats"))

	# Initialize from current profile so HQ shows correct values immediately
	if GameState:
		var profile: Dictionary = GameState.get_profile_copy()
		var rep: int = int(profile.get("reputation", 0))
		var creds: int = int(profile.get("funds", 0))
		_update_labels(rep, creds)


func _on_update_player_stats(rep: int, creds: int) -> void:
	_update_labels(rep, creds)

func _update_labels(rep: int, creds: int) -> void:
	if reputation_label:
		reputation_label.text = str(rep)

	if credits_label:
		credits_label.text = str(creds)
