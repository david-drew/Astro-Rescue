## res://scripts/modes/mode4/crew_manager_panel.gd
extends Control

##
# CrewManagerPanel (starter)
#
# Responsibilities:
#   - Display recruitable NPC candidates from GameState.
#   - Show a short talent/role hint and recruitment cost.
#   - Emit intent when player tries to recruit.
#
# Data expectations (add to GameState later):
#   GameState.available_crew_candidates : Array[Dictionary]
#     Candidate dictionary suggested keys:
#       id: String
#       name: String
#       role_hint: String        # e.g., "Pilot", "Engineer"
#       talent_hint: String      # e.g., "High G tolerance"
#       cost_credits: int        # optional
#       cost_rep: int            # optional
#
# Intents:
#   EventBus.emit_signal("crew_recruit_requested", candidate_id)
#
# NOTE: This panel does not apply recruitment. MissionController or GameState should.
##

@export var max_displayed_candidates: int = 8
@export var debug_logging: bool = false

@onready var crew_container: Control = $MarginContainer/CrewContainer
@onready var empty_label: Label = $MarginContainer/EmptyLabel 


func _ready() -> void:
	refresh()

# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

func refresh() -> void:
	_refresh_from_gamestate()


# -------------------------------------------------------------------
# Internal helpers
# -------------------------------------------------------------------

func _refresh_from_gamestate() -> void:
	if crew_container == null:
		push_warning("CrewManagerPanel: %CrewContainer missing.")
		return

	_clear_list()

	if not GameState:
		push_warning("CrewManagerPanel: GameState autoload not found.")
		_show_empty_state(true)
		return

	var candidates: Array = []
	candidates = GameState.available_crew_candidates

	if candidates.is_empty():
		_show_empty_state(true)
		return

	_show_empty_state(false)

	var count: int = candidates.size()
	if count > max_displayed_candidates:
		count = max_displayed_candidates

	for i in range(count):
		var cand_raw = candidates[i]
		if typeof(cand_raw) != TYPE_DICTIONARY:
			continue
		_add_candidate_row(cand_raw)


func _clear_list() -> void:
	for child in crew_container.get_children():
		crew_container.remove_child(child)
		child.queue_free()


func _show_empty_state(show: bool) -> void:
	if empty_label:
		empty_label.visible = show


func _add_candidate_row(cand: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var name_label := Label.new()
	var cand_name: String = cand.get("name", "Unnamed Recruit")
	name_label.text = cand_name
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	var role_text: String = cand.get("role_hint", "")
	var talent_text: String = cand.get("talent_hint", "")

	var info_label := Label.new()
	var info: String = ""
	if role_text != "":
		info += role_text
	if talent_text != "":
		if info != "":
			info += " • "
		info += talent_text
	if info == "":
		info = "No details yet"
	info_label.text = info
	info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info_label)

	var cost_label := Label.new()
	var cost_line: String = _format_cost(cand)
	cost_label.text = cost_line
	row.add_child(cost_label)

	var recruit_button := Button.new()
	recruit_button.text = "Recruit"
	recruit_button.size_flags_horizontal = Control.SIZE_SHRINK_END
	recruit_button.set_meta("candidate_id", cand.get("id", ""))
	recruit_button.pressed.connect(Callable(self, "_on_recruit_pressed").bind(recruit_button))
	row.add_child(recruit_button)

	crew_container.add_child(row)


func _format_cost(cand: Dictionary) -> String:
	var credits: int = int(cand.get("cost_credits", 0))
	var rep: int = int(cand.get("cost_rep", 0))

	var parts: Array = []
	if credits > 0:
		parts.append(str(credits) + " cr")
	if rep > 0:
		parts.append(str(rep) + " rep")

	if parts.is_empty():
		return "Cost: TBD"

	return "Cost: " + " + ".join(parts)


# -------------------------------------------------------------------
# Event handlers
# -------------------------------------------------------------------

func _on_recruit_pressed(btn: Button) -> void:
	var cand_id_meta = btn.get_meta("candidate_id")
	if cand_id_meta == null:
		return

	var cand_id: String = str(cand_id_meta)
	if cand_id == "":
		return

	if debug_logging:
		print("[CrewManagerPanel] recruit requested: ", cand_id)

	EventBus.emit_signal("crew_recruit_requested", cand_id)
