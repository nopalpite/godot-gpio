extends Control
## Banc manuel : réserver n'importe quelle ligne en entrée ou en sortie et la manipuler.
##
## Pour essayer un vrai bouton, une LED, un relais... sans écrire de code :
##   godot --path project res://banc/banc_manuel.tscn
## Plusieurs lignes peuvent être réservées en même temps (bouton + LED, par exemple).

const CONSUMER := "banc-gpio"
const AUTO_CHIP_LABELS: Array[String] = ["pinctrl-rp1", "pinctrl-bcm2711", "pinctrl-bcm2835"]
const MAX_LOG_LINES := 200

var _chip: RefCounted = null
var _lines: Dictionary[int, RefCounted] = {}
var _edge_counts: Dictionary[int, int] = {}
var _last_edge_ns: Dictionary[int, int] = {}
var _blink_lines: Dictionary[int, bool] = {}
var _selected: int = -1

var _chip_select: OptionButton
var _line_list: ItemList
var _info: Label
var _value_rect: ColorRect
var _value_label: Label
var _input_box: VBoxContainer
var _output_box: VBoxContainer
var _bias: OptionButton
var _edges: OptionButton
var _debounce: SpinBox
var _active_low: CheckBox
var _initial: CheckBox
var _drive: OptionButton
var _release_button: Button
var _toggle_button: Button
var _log: RichTextLabel
var _blink_timer: Timer


func _ready() -> void:
	Gpio.shutdown()
	_build_ui()
	if not ClassDB.class_exists(&"GpioChip"):
		_write_log("[color=#ff7070]GDExtension non chargée : banc indisponible ici.[/color]")
		return
	var chips: Array = ClassDB.instantiate(&"GpioChip").call(&"list_chips")
	for chip: Dictionary in chips:
		var text: String = "%s (%s)" % [chip.get("label", "?"), chip.get("path", "?")]
		if chip.has("error"):
			text += " : inaccessible"
			_write_log("[color=#ff7070]%s[/color]" % str(chip["error"]))
		_chip_select.add_item(text)
		_chip_select.set_item_metadata(_chip_select.item_count - 1, chip.get("path", ""))
	if chips.is_empty():
		_write_log("Aucune puce GPIO sur cette machine.")
		return
	_chip_select.select(_preferred_chip(chips))
	_on_chip_selected(_chip_select.selected)


func _exit_tree() -> void:
	for line: RefCounted in _lines.values():
		line.call(&"release")
	_lines.clear()


func _process(_delta: float) -> void:
	_refresh_value()


# --- Puce et lignes -----------------------------------------------------------------


func _preferred_chip(chips: Array) -> int:
	for label: String in AUTO_CHIP_LABELS:
		for i: int in chips.size():
			if chips[i].get("label", "") == label:
				return i
	return 0


func _on_chip_selected(index: int) -> void:
	_exit_tree()
	_chip = ClassDB.instantiate(&"GpioChip")
	var path: String = _chip_select.get_item_metadata(index)
	if int(_chip.call(&"open", path)) != OK:
		_write_log("[color=#ff7070]%s[/color]" % _chip.call(&"get_last_error"))
		_chip = null
		return
	_write_log("Puce ouverte : %s" % path)
	_refresh_list()


func _refresh_list() -> void:
	var keep: int = _selected
	_line_list.clear()
	if _chip == null:
		return
	for offset: int in int(_chip.call(&"get_line_count")):
		var info: Dictionary = _chip.call(&"get_line_info", offset)
		var text: String = "%2d  %s" % [offset, info.get("name", "")]
		if _lines.has(offset):
			var line: RefCounted = _lines[offset]
			text += "  [%s]" % ("sortie" if int(line.call(&"get_direction")) == 1 else "entrée")
		elif info.get("used", false):
			text += "  (utilisée : %s)" % info.get("consumer", "?")
		_line_list.add_item(text)
	if keep >= 0 and keep < _line_list.item_count:
		_line_list.select(keep)
	_update_panel()


func _on_line_selected(index: int) -> void:
	_selected = index
	_update_panel()


func _update_panel() -> void:
	var has_line: bool = _selected >= 0 and _lines.has(_selected)
	var line: RefCounted = _lines.get(_selected)
	var is_output: bool = has_line and int(line.call(&"get_direction")) == 1
	_input_box.visible = _selected >= 0 and not has_line
	_output_box.visible = _selected >= 0 and not has_line
	_release_button.visible = has_line
	_toggle_button.get_parent().visible = is_output
	if _chip == null or _selected < 0:
		_info.text = "Choisir une ligne dans la liste."
		return
	var info: Dictionary = _chip.call(&"get_line_info", _selected)
	var lines: PackedStringArray = []
	for key: String in [
		"name", "used", "consumer", "direction", "active_low", "bias", "edge", "debounce_us"
	]:
		lines.append("%s : %s" % [key, info.get(key, "?")])
	if has_line:
		lines.append("fronts reçus : %d" % _edge_counts.get(_selected, 0))
	_info.text = "Ligne %d\n%s" % [_selected, "\n".join(lines)]


func _refresh_value() -> void:
	if _selected < 0 or not _lines.has(_selected):
		_value_rect.color = Color(0.25, 0.25, 0.25)
		_value_label.text = "—"
		return
	var value: int = _lines[_selected].call(&"get_value")
	_value_rect.color = Color(0.2, 0.9, 0.3) if value == 1 else Color(0.35, 0.1, 0.1)
	_value_label.text = "erreur" if value < 0 else str(value)


# --- Réservation --------------------------------------------------------------------


func _request_input() -> void:
	if _chip == null or _selected < 0:
		return
	var line: RefCounted = _chip.call(
		&"request_input",
		_selected,
		_bias.get_selected_id(),
		int(_debounce.value),
		_edges.get_selected_id(),
		_active_low.button_pressed,
		CONSUMER
	)
	_store(line, "entrée")
	if line != null:
		line.connect(&"edge_detected", _on_edge.bind(_selected))


func _request_output() -> void:
	if _chip == null or _selected < 0:
		return
	var line: RefCounted = _chip.call(
		&"request_output",
		_selected,
		_initial.button_pressed,
		_active_low.button_pressed,
		_drive.get_selected_id(),
		CONSUMER
	)
	_store(line, "sortie")


func _store(line: RefCounted, kind: String) -> void:
	if line == null:
		_write_log("[color=#ff7070]%s[/color]" % _chip.call(&"get_last_error"))
		return
	_lines[_selected] = line
	_edge_counts[_selected] = 0
	line.connect(&"line_error", _on_line_error.bind(_selected))
	_write_log("Ligne %d réservée en %s." % [_selected, kind])
	_refresh_list()


func _release_selected() -> void:
	if not _lines.has(_selected):
		return
	_lines[_selected].call(&"release")
	_lines.erase(_selected)
	_blink_lines.erase(_selected)
	_write_log("Ligne %d libérée." % _selected)
	_refresh_list()


func _set_output(value: bool) -> void:
	if not _lines.has(_selected):
		return
	var line: RefCounted = _lines[_selected]
	if int(line.call(&"set_value", value)) != OK:
		_write_log("[color=#ff7070]%s[/color]" % line.call(&"get_last_error"))


func _pulse() -> void:
	var offset: int = _selected
	if not _lines.has(offset):
		return
	var line: RefCounted = _lines[offset]
	line.call(&"set_value", true)
	await get_tree().create_timer(0.2).timeout
	if line.call(&"is_valid"):
		line.call(&"set_value", false)


func _toggle_blink() -> void:
	if not _lines.has(_selected):
		return
	if _blink_lines.has(_selected):
		_blink_lines.erase(_selected)
	else:
		_blink_lines[_selected] = true


func _on_blink_timeout() -> void:
	for offset: int in _blink_lines.keys():
		var line: RefCounted = _lines.get(offset)
		if line == null:
			continue
		line.call(&"set_value", int(line.call(&"get_value")) != 1)


func _on_edge(rising: bool, timestamp_ns: int, offset: int) -> void:
	_edge_counts[offset] = _edge_counts.get(offset, 0) + 1
	var delta: String = ""
	if _last_edge_ns.has(offset):
		delta = "  (+%.3f ms)" % ((timestamp_ns - _last_edge_ns[offset]) / 1_000_000.0)
	_last_edge_ns[offset] = timestamp_ns
	_write_log(
		(
			"Ligne %d : front %s, n° %d%s"
			% [offset, "montant" if rising else "descendant", _edge_counts[offset], delta]
		)
	)
	if offset == _selected:
		_update_panel()


func _on_line_error(message: String, offset: int) -> void:
	_write_log("[color=#ff7070]Ligne %d : %s[/color]" % [offset, message])


func _write_log(text: String) -> void:
	print(text)
	_log.append_text(text + "\n")
	if _log.get_paragraph_count() > MAX_LOG_LINES:
		_log.remove_paragraph(0)


# --- Interface ----------------------------------------------------------------------


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)
	var root := VBoxContainer.new()
	margin.add_child(root)

	var top := HBoxContainer.new()
	root.add_child(top)
	var title := Label.new()
	title.text = "Banc manuel GPIO"
	title.add_theme_font_size_override("font_size", 22)
	top.add_child(title)
	_chip_select = OptionButton.new()
	_chip_select.item_selected.connect(_on_chip_selected)
	top.add_child(_chip_select)
	top.add_child(_button("Rafraîchir", _refresh_list))
	top.add_child(
		_button("Menu", func() -> void: get_tree().change_scene_to_file("res://banc/banc.tscn"))
	)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)
	_line_list = ItemList.new()
	_line_list.custom_minimum_size.x = 340
	_line_list.item_selected.connect(_on_line_selected)
	split.add_child(_line_list)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	var value_row := HBoxContainer.new()
	right.add_child(value_row)
	_value_rect = ColorRect.new()
	_value_rect.custom_minimum_size = Vector2(48, 48)
	value_row.add_child(_value_rect)
	_value_label = Label.new()
	_value_label.add_theme_font_size_override("font_size", 28)
	value_row.add_child(_value_label)
	_info = Label.new()
	right.add_child(_info)

	_active_low = CheckBox.new()
	_active_low.text = "Actif à l'état bas"
	right.add_child(_active_low)
	_build_input_box(right)
	_build_output_box(right)
	_release_button = _button("Libérer la ligne", _release_selected)
	right.add_child(_release_button)
	var actions := HBoxContainer.new()
	right.add_child(actions)
	_toggle_button = _button("Allumer", func() -> void: _set_output(true))
	actions.add_child(_toggle_button)
	actions.add_child(_button("Éteindre", func() -> void: _set_output(false)))
	actions.add_child(_button("Impulsion 0,2 s", _pulse))
	actions.add_child(_button("Clignoter / arrêter", _toggle_blink))

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.custom_minimum_size.y = 180
	root.add_child(_log)

	_blink_timer = Timer.new()
	_blink_timer.wait_time = 0.25
	_blink_timer.autostart = true
	_blink_timer.timeout.connect(_on_blink_timeout)
	add_child(_blink_timer)
	_update_panel()


func _build_input_box(parent: Control) -> void:
	_input_box = VBoxContainer.new()
	parent.add_child(_input_box)
	var row := HBoxContainer.new()
	_input_box.add_child(row)
	_bias = _options(row, "Tirage", ["inchangé", "aucun", "pull-up", "pull-down"], 2)
	_edges = _options(row, "Fronts", ["aucun", "montants", "descendants", "les deux"], 3)
	var label := Label.new()
	label.text = "Anti-rebond (µs)"
	row.add_child(label)
	_debounce = SpinBox.new()
	_debounce.max_value = 1_000_000
	_debounce.step = 1000
	_debounce.value = 20_000
	row.add_child(_debounce)
	_input_box.add_child(_button("Réserver en entrée", _request_input))


func _build_output_box(parent: Control) -> void:
	_output_box = VBoxContainer.new()
	parent.add_child(_output_box)
	var row := HBoxContainer.new()
	_output_box.add_child(row)
	_initial = CheckBox.new()
	_initial.text = "Valeur initiale 1"
	row.add_child(_initial)
	_drive = _options(row, "Mode", ["push-pull", "drain ouvert", "source ouverte"], 0)
	_output_box.add_child(_button("Réserver en sortie", _request_output))


func _options(
	row: HBoxContainer, text: String, items: Array[String], selected: int
) -> OptionButton:
	var label := Label.new()
	label.text = text
	row.add_child(label)
	var option := OptionButton.new()
	for i: int in items.size():
		option.add_item(items[i], i)
	option.select(selected)
	row.add_child(option)
	return option


func _button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	return button
