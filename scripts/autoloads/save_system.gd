## res://scripts/core/save_system.gd
extends Node
#class_name SaveSystem

##
# SaveSystem
#
# Responsible for loading and saving the player profile to disk.
#
# - Uses JSON for simplicity and transparency.
# - Collaborates with GameState (to supply/consume profile data).
# - Emits signals via EventBus for UI or debug hooks:
#     profile_saved(profile)
#     profile_save_failed(error_message)
#
# Typical usage:
#
#   # On game boot (e.g., from Main.tscn script):
#   SaveSystem.load_profile()
#
#   # When GameState updates the profile and wants to persist:
#   SaveSystem.save_profile(GameState.player_profile)
#
##

# -------------------------------------------------------------------
# File configuration
# -------------------------------------------------------------------

## Main save file (single-slot design for now).
const SAVE_FILE_PATH := "user://astro_rescue_profile.json"

## Optional backup file (written before overwriting main file).
const SAVE_FILE_BACKUP_PATH := "user://astro_rescue_profile_backup.json"


# -------------------------------------------------------------------
# State
# -------------------------------------------------------------------

## Last profile we loaded from disk (for debugging or quick access).
var last_loaded_profile: Dictionary = {}

## Last error message, if any save/load failed.
var last_error: String = ""


func _ready() -> void:
	# Nothing automatic here to avoid surprising behavior.
	# Call load_profile() explicitly from your boot script if desired.
	pass


# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func load_profile() -> void:
	##
	# Loads the player profile from disk (if present) and hands it off to GameState.
	#
	# Behavior:
	# - If the file exists:
	#       - Reads and parses JSON.
	#       - If valid Dictionary: calls GameState.load_profile_from_save(profile_dict)
	#       - If invalid: logs a warning, passes {} to GameState (which will create a default profile).
	# - If the file does not exist:
	#       - Calls GameState.load_profile_from_save({}) to use default profile.
	#
	# GameState.load_profile_from_save() will emit profile_loaded via EventBus.
	##
	last_error = ""
	last_loaded_profile = {}

	var profile_data: Dictionary = {}

	if FileAccess.file_exists(SAVE_FILE_PATH):
		var file := FileAccess.open(SAVE_FILE_PATH, FileAccess.READ)
		if file == null:
			last_error = "Failed to open save file for reading."
			push_warning("SaveSystem: %s (%s)" % [last_error, SAVE_FILE_PATH])
			# Fall back to default
			_call_game_state_load_profile({})
			return

		var text := file.get_as_text()
		file.close()

		if text.strip_edges() == "":
			push_warning("SaveSystem: Save file is empty, using default profile.")
			_call_game_state_load_profile({})
			return

		var parsed:Variant = JSON.parse_string(text)
		if typeof(parsed) == TYPE_DICTIONARY:
			profile_data = parsed
		else:
			push_warning("SaveSystem: Failed to parse save JSON, using default profile.")
			_call_game_state_load_profile({})
			return
	else:
		# No save file: use GameState's default behavior.
		_call_game_state_load_profile({})
		return

	last_loaded_profile = profile_data.duplicate(true)
	_call_game_state_load_profile(profile_data)


func save_profile(profile: Dictionary) -> bool:
	##
	# Saves the provided profile Dictionary to disk as JSON.
	#
	# Returns:
	#   true  on success
	#   false on failure (and sets last_error)
	#
	# Emits:
	#   EventBus.profile_saved(profile) on success
	#   EventBus.profile_save_failed(error_message) on failure
	##
	last_error = ""

	if profile.is_empty():
		last_error = "Refusing to save empty profile dictionary."
		push_warning("SaveSystem: %s" % last_error)
		_emit_save_failed(last_error)
		return false

	# Make a backup of the existing save file, if any.
	_make_backup_if_exists()

	# Serialize to JSON
	var json_text := JSON.stringify(profile, "  ")  # pretty-print with indentation

	var file := FileAccess.open(SAVE_FILE_PATH, FileAccess.WRITE)
	if file == null:
		last_error = "Failed to open save file for writing."
		push_warning("SaveSystem: %s (%s)" % [last_error, SAVE_FILE_PATH])
		_emit_save_failed(last_error)
		return false

	file.store_string(json_text)
	file.flush()
	file.close()

	last_loaded_profile = profile.duplicate(true)
	_emit_save_success(profile)
	return true


func delete_save() -> bool:
	##
	# Deletes the current save file (and backup) if they exist.
	# Returns true if at least one file was removed successfully, false otherwise.
	##
	var deleted_any := false

	if FileAccess.file_exists(SAVE_FILE_PATH):
		var err := DirAccess.remove_absolute(SAVE_FILE_PATH)
		if err == OK:
			deleted_any = true
		else:
			push_warning("SaveSystem: Failed to delete save file (%s), error code: %d" % [SAVE_FILE_PATH, err])

	if FileAccess.file_exists(SAVE_FILE_BACKUP_PATH):
		var err_backup := DirAccess.remove_absolute(SAVE_FILE_BACKUP_PATH)
		if err_backup == OK:
			deleted_any = true
		else:
			push_warning("SaveSystem: Failed to delete backup file (%s), error code: %d" % [SAVE_FILE_BACKUP_PATH, err_backup])

	return deleted_any


# -------------------------------------------------------------------
# Internal helpers
# -------------------------------------------------------------------

func _call_game_state_load_profile(profile: Dictionary) -> void:
	##
	# Convenience wrapper so we don't repeat global checks.
	##
	if Engine.has_singleton("GameState"):
		GameState.load_profile_from_save(profile)
	else:
		push_warning("SaveSystem: GameState singleton not found; cannot apply loaded profile.")


func _make_backup_if_exists() -> void:
	##
	# If the main save file exists, write a backup copy before overwriting.
	##
	if not FileAccess.file_exists(SAVE_FILE_PATH):
		return

	var src := FileAccess.open(SAVE_FILE_PATH, FileAccess.READ)
	if src == null:
		push_warning("SaveSystem: Could not open existing save for backup (%s)." % SAVE_FILE_PATH)
		return

	var contents := src.get_as_text()
	src.close()

	var dst := FileAccess.open(SAVE_FILE_BACKUP_PATH, FileAccess.WRITE)
	if dst == null:
		push_warning("SaveSystem: Could not open backup file for writing (%s)." % SAVE_FILE_BACKUP_PATH)
		return

	dst.store_string(contents)
	dst.flush()
	dst.close()


func _emit_save_success(profile: Dictionary) -> void:
	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("profile_saved", profile)


func _emit_save_failed(message: String) -> void:
	if Engine.has_singleton("EventBus"):
		EventBus.emit_signal("profile_save_failed", message)
