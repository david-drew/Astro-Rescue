## res://scripts/modes/mode4/store_manager.gd
extends Control

##
# StoreManager (starter)
#
# Responsibilities:
#   - Display store inventory from GameState.
#   - Let player purchase fuel / items / upgrades.
#   - Emit intent for purchases.
#
# Data expectations (add to GameState later):
#   GameState.store_inventory : Array[Dictionary]
#     Inventory dictionary suggested keys:
#       id: String
#       display_name: String
#       category: String      # "fuel", "item", "upgrade"
#       price_credits: int
#       description: String   # optional
#       stock: int            # optional (0 = out of stock)
#
# Intents:
#   EventBus.emit_signal("store_purchase_requested", item_id, quantity)
#
# NOTE: StoreManager does not deduct credits or apply upgrades.
#       That should be handled by GameState or MissionController.
##

@export var max_displayed_items: int = 12
@export var debug_logging: bool = false

@onready var store_container: Control = $MarginContainer/StoreContainer
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
	if store_container == null:
		push_warning("StoreManager: %StoreContainer missing.")
		return

	_clear_list()

	if not GameState:
		push_warning("StoreManager: GameState autoload not found.")
		_show_empty_state(true)
		return

	var inventory: Array = []
	inventory = GameState.store_inventory

	if inventory.is_empty():
		_show_empty_state(true)
		return

	_show_empty_state(false)

	var count: int = inventory.size()
	if count > max_displayed_items:
		count = max_displayed_items

	for i in range(count):
		var item_raw = inventory[i]
		if typeof(item_raw) != TYPE_DICTIONARY:
			continue
		_add_store_row(item_raw)


func _clear_list() -> void:
	for child in store_container.get_children():
		store_container.remove_child(child)
		child.queue_free()


func _show_empty_state(show: bool) -> void:
	if empty_label:
		empty_label.visible = show


func _add_store_row(item: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var name_label := Label.new()
	var name: String = item.get("display_name", item.get("id", "Unknown"))
	name_label.text = name
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	var cat_label := Label.new()
	var category: String = item.get("category", "misc")
	cat_label.text = category.capitalize()
	row.add_child(cat_label)

	var price_label := Label.new()
	var price: int = int(item.get("price_credits", 0))
	price_label.text = str(price) + " cr"
	row.add_child(price_label)

	var stock: int = int(item.get("stock", -1))
	var stock_label := Label.new()
	if stock >= 0:
		stock_label.text = "Stock: " + str(stock)
	else:
		stock_label.text = ""
	row.add_child(stock_label)

	var buy_button := Button.new()
	buy_button.text = "Buy"
	buy_button.set_meta("item_id", item.get("id", ""))
	buy_button.set_meta("stock", stock)
	buy_button.pressed.connect(Callable(self, "_on_buy_pressed").bind(buy_button))
	row.add_child(buy_button)

	# Disable button if stock is 0
	if stock == 0:
		buy_button.disabled = true

	store_container.add_child(row)


# -------------------------------------------------------------------
# Event handlers
# -------------------------------------------------------------------

func _on_buy_pressed(btn: Button) -> void:
	var id_meta = btn.get_meta("item_id")
	if id_meta == null:
		return

	var item_id: String = str(id_meta)
	if item_id == "":
		return

	# Quantity UI can come later; for now always 1
	var qty: int = 1

	if debug_logging:
		print("[StoreManager] purchase requested: ", item_id, " x", qty)

	EventBus.emit_signal("store_purchase_requested", item_id, qty)
