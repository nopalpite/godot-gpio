extends Control
## Moniteur GPIO : le connecteur 40 broches à l'écran, l'état de chaque ligne en direct,
## et le réglage de n'importe quelle broche en entrée ou en sortie.
##
##   godot --path project res://banc/moniteur.tscn
##   options : -- --exemple (bouton GPIO 17 + LED GPIO 27, reliés)
##             -- --bouton=22 (GPIO du bouton de l'exemple, 17 par défaut)
##             -- --capture=/tmp/moniteur.png (capture d'écran après 2 s, puis quitte)
##
## Une entrée peut commander une sortie (liaison), et la configuration se sauvegarde en
## gpio_config.tres, directement utilisable par l'autoload Gpio d'un jeu.

enum Mode { FREE, INPUT, OUTPUT }

const BrocheBouton := preload("res://banc/broche_bouton.gd")
const CONSUMER := "moniteur-gpio"
const AUTO_CHIP_LABELS: Array[String] = ["pinctrl-rp1", "pinctrl-bcm2711", "pinctrl-bcm2835"]
const EDGE_BOTH := 3
const EXPORT_USER := "user://gpio_config.tres"
const EXPORT_PROJECT := "res://config/gpio_config_moniteur.tres"
const MAX_LOG_LINES := 300

const COLOR_FREE := Color("#7a7a7a")
const COLOR_INPUT := Color("#3a8ee6")
const COLOR_OUTPUT := Color("#f0a030")
const COLOR_BUSY := Color("#9b59b6")
const COLOR_ERROR := Color("#e04040")

## Connecteur 40 broches, de la broche 1 à 40 : [libellé, numéro GPIO ou -1, type].
const HEADER: Array[Array] = [
	["3,3 V", -1, 1],
	["5 V", -1, 2],
	["GPIO 2 (SDA)", 2, 0],
	["5 V", -1, 2],
	["GPIO 3 (SCL)", 3, 0],
	["GND", -1, 3],
	["GPIO 4", 4, 0],
	["GPIO 14 (TXD)", 14, 0],
	["GND", -1, 3],
	["GPIO 15 (RXD)", 15, 0],
	["GPIO 17", 17, 0],
	["GPIO 18", 18, 0],
	["GPIO 27", 27, 0],
	["GND", -1, 3],
	["GPIO 22", 22, 0],
	["GPIO 23", 23, 0],
	["3,3 V", -1, 1],
	["GPIO 24", 24, 0],
	["GPIO 10 (MOSI)", 10, 0],
	["GND", -1, 3],
	["GPIO 9 (MISO)", 9, 0],
	["GPIO 25", 25, 0],
	["GPIO 11 (SCLK)", 11, 0],
	["GPIO 8 (CE0)", 8, 0],
	["GND", -1, 3],
	["GPIO 7 (CE1)", 7, 0],
	["GPIO 0 (ID_SD)", 0, 0],
	["GPIO 1 (ID_SC)", 1, 0],
	["GPIO 5", 5, 0],
	["GND", -1, 3],
	["GPIO 6", 6, 0],
	["GPIO 12", 12, 0],
	["GPIO 13", 13, 0],
	["GND", -1, 3],
	["GPIO 19", 19, 0],
	["GPIO 16", 16, 0],
	["GPIO 26", 26, 0],
	["GPIO 20", 20, 0],
	["GND", -1, 3],
	["GPIO 21", 21, 0],
]

var _chip: RefCounted = null
var _chip_error: String = ""
var _pins: Dictionary[int, PinState] = {}
var _buttons: Dictionary[int, BrocheBouton] = {}
var _selected: int = -1
var _example_button: int = 17
var _syncing: bool = false

var _chip_label: Label
var _log: RichTextLabel
var _title: Label
var _status: Label
var _name_edit: LineEdit
var _mode_buttons: Array[Button] = []
var _input_box: Control
var _output_box: Control
var _bias: OptionButton
var _debounce: SpinBox
var _filter: OptionButton
var _active_low: CheckBox
var _drive: OptionButton
var _initial: CheckBox
var _indicator: ColorRect
var _value_label: Label
var _stats: Label
var _toggle: Button
var _blink: Button
var _link: OptionButton
var _link_invert: CheckBox
var _settings: Control


## État d'une broche GPIO du connecteur.
class PinState:
	extends RefCounted
	var gpio: int = 0
	var offset: int = 0
	var mode: int = 0
	var name: String = ""
	var bias: int = 2
	var debounce_ms: float = 20.0
	var sampled: bool = true
	var active_low: bool = false
	var drive: int = 0
	var initial: bool = false
	var link: int = -1
	var link_invert: bool = false
	var line: RefCounted = null
	var value: int = -1
	var edges: int = 0
	var presses: int = 0
	var press_start_ms: int = -1
	var last_press_ms: int = -1
	var blinking: bool = false
	var busy_by: String = ""
	var error: String = ""


func _ready() -> void:
	# Les broches du projet d'exemple ne doivent pas être prises par l'autoload.
	Gpio.shutdown()
	# Interface pensée pour 1280 x 720 : agrandie sur un écran Full HD (tactile). La taille
	# finale de la fenêtre n'est connue qu'après coup (Wayland) : on suit ses changements.
	get_tree().root.size_changed.connect(_update_scale)
	_update_scale()
	_build_ui()
	_open_chip()
	for entry: Array in HEADER:
		var gpio: int = entry[1]
		if gpio >= 0:
			var state := PinState.new()
			state.gpio = gpio
			state.offset = _offset_of(gpio)
			_pins[gpio] = state
	_refresh_line_info()
	var info_timer := Timer.new()
	info_timer.wait_time = 1.0
	info_timer.autostart = true
	info_timer.timeout.connect(_refresh_line_info)
	add_child(info_timer)
	var blink_timer := Timer.new()
	blink_timer.wait_time = 0.25
	blink_timer.autostart = true
	blink_timer.timeout.connect(_on_blink_timeout)
	add_child(blink_timer)
	_select(17)
	_handle_arguments()


func _exit_tree() -> void:
	for state: PinState in _pins.values():
		_release(state)
	get_tree().root.size_changed.disconnect(_update_scale)
	get_tree().root.content_scale_factor = 1.0


func _update_scale() -> void:
	var window: Window = get_tree().root
	var factor: float = clampf(float(window.size.y) / 720.0, 1.0, 2.0)
	if not is_equal_approx(window.content_scale_factor, factor):
		window.content_scale_factor = factor


func _process(_delta: float) -> void:
	for state: PinState in _pins.values():
		if state.line != null:
			state.value = state.line.call(&"get_value")
		_update_button(state)
	if _selected >= 0:
		_update_live(_pins[_selected])


# --- Puce et lignes -----------------------------------------------------------------


func _open_chip() -> void:
	if not ClassDB.class_exists(&"GpioChip"):
		_chip_error = "GDExtension non chargée : moniteur sans matériel (normal hors Linux)."
		_chip_label.text = "Pas de GPIO"
		_write_log("[color=#ff7070]%s[/color]" % _chip_error)
		return
	for candidate: String in AUTO_CHIP_LABELS + ["0"]:
		var chip: RefCounted = ClassDB.instantiate(&"GpioChip")
		if int(chip.call(&"open", candidate)) == OK:
			_chip = chip
			_chip_label.text = ("%s (%s)" % [chip.call(&"get_label"), chip.call(&"get_path")])
			_write_log("Puce ouverte : %s" % _chip_label.text)
			return
		_chip_error = chip.call(&"get_last_error")
	_chip_label.text = "Aucune puce"
	_write_log("[color=#ff7070]%s[/color]" % _chip_error)


func _offset_of(gpio: int) -> int:
	if _chip == null:
		return gpio
	var offset: int = _chip.call(&"find_line", "GPIO%d" % gpio)
	return offset if offset >= 0 else gpio


func _refresh_line_info() -> void:
	if _chip == null:
		return
	for state: PinState in _pins.values():
		if state.line != null:
			state.busy_by = ""
			continue
		var info: Dictionary = _chip.call(&"get_line_info", state.offset)
		state.busy_by = (str(info.get("consumer", "?")) if info.get("used", false) else "")
		if state.busy_by.is_empty() and info.get("used", false):
			state.busy_by = "?"


func _apply(state: PinState) -> void:
	_release(state)
	state.error = ""
	state.edges = 0
	state.presses = 0
	state.last_press_ms = -1
	if state.mode == Mode.FREE:
		_write_log("GPIO %d libérée." % state.gpio)
		_refresh_line_info()
		return
	if _chip == null:
		state.error = _chip_error if not _chip_error.is_empty() else "pas de puce GPIO"
		return
	var line: RefCounted = null
	if state.mode == Mode.INPUT and state.sampled and state.debounce_ms > 0.0:
		line = _chip.call(
			&"request_input_sampled",
			state.offset,
			state.bias,
			roundi(state.debounce_ms * 1000.0),
			state.active_low,
			CONSUMER
		)
	elif state.mode == Mode.INPUT:
		line = _chip.call(
			&"request_input",
			state.offset,
			state.bias,
			roundi(state.debounce_ms * 1000.0),
			EDGE_BOTH,
			state.active_low,
			CONSUMER
		)
	else:
		line = _chip.call(
			&"request_output", state.offset, state.initial, state.active_low, state.drive, CONSUMER
		)
	if line == null:
		state.error = _chip.call(&"get_last_error")
		_write_log("[color=#ff7070]GPIO %d : %s[/color]" % [state.gpio, state.error])
		return
	state.line = line
	state.busy_by = ""
	line.connect(&"line_error", _on_line_error.bind(state.gpio))
	if state.mode == Mode.INPUT:
		line.connect(&"edge_detected", _on_edge.bind(state.gpio))
	_write_log(
		"GPIO %d réservée en %s." % [state.gpio, "entrée" if state.mode == Mode.INPUT else "sortie"]
	)


func _release(state: PinState) -> void:
	state.blinking = false
	if state.line != null:
		state.line.call(&"release")
		state.line = null
	state.value = -1


func _set_output(state: PinState, value: bool) -> void:
	if state.mode != Mode.OUTPUT or state.line == null:
		return
	if int(state.line.call(&"set_value", value)) != OK:
		state.error = state.line.call(&"get_last_error")
		_write_log("[color=#ff7070]GPIO %d : %s[/color]" % [state.gpio, state.error])


func _on_edge(rising: bool, _timestamp_ns: int, gpio: int) -> void:
	var state: PinState = _pins[gpio]
	state.edges += 1
	if rising:
		state.presses += 1
		state.press_start_ms = Time.get_ticks_msec()
	elif state.press_start_ms >= 0:
		state.last_press_ms = Time.get_ticks_msec() - state.press_start_ms
		state.press_start_ms = -1
	if state.link >= 0 and _pins.has(state.link):
		var target: PinState = _pins[state.link]
		target.blinking = false
		_set_output(target, rising != state.link_invert)


func _on_line_error(message: String, gpio: int) -> void:
	_pins[gpio].error = message
	_write_log("[color=#ff7070]GPIO %d : %s[/color]" % [gpio, message])


func _on_blink_timeout() -> void:
	for state: PinState in _pins.values():
		if state.blinking and state.line != null:
			_set_output(state, state.value != 1)


func _pulse(state: PinState) -> void:
	state.blinking = false
	_set_output(state, true)
	await get_tree().create_timer(0.2).timeout
	_set_output(state, false)


# --- Exemple et export --------------------------------------------------------------


func _load_example() -> void:
	var gpio: int = _example_button if _pins.has(_example_button) else 17
	for state: PinState in _pins.values():
		if state.mode != Mode.FREE:
			state.mode = Mode.FREE
			state.link = -1
			_apply(state)
	var button: PinState = _pins[gpio]
	button.name = "bouton"
	button.mode = Mode.INPUT
	button.bias = 2
	button.active_low = true
	button.debounce_ms = 20.0
	var led: PinState = _pins[27]
	led.name = "led"
	led.mode = Mode.OUTPUT
	led.active_low = false
	_apply(led)
	button.link = 27
	_apply(button)
	_write_log(
		(
			(
				"Exemple chargé : bouton GPIO %d (broche %d, vers la masse) commande la LED GPIO 27"
				% [gpio, _physical_of(gpio)]
			)
			+ " (broche 13, résistance 330 Ω vers la masse)."
		)
	)
	_select(gpio)


func _physical_of(gpio: int) -> int:
	for i: int in HEADER.size():
		if HEADER[i][1] == gpio:
			return i + 1
	return 0


func _export_config() -> void:
	var config := GpioConfig.new()
	config.default_chip = "auto"
	for gpio: int in _sorted_gpios():
		var state: PinState = _pins[gpio]
		if state.mode == Mode.FREE:
			continue
		var pin := GpioPin.new()
		pin.name = StringName(state.name if not state.name.is_empty() else "gpio%d" % gpio)
		pin.line = state.offset
		pin.active_low = state.active_low
		if state.mode == Mode.INPUT:
			pin.direction = GpioPin.Direction.INPUT
			pin.bias = state.bias as GpioPin.Bias
			pin.debounce_ms = state.debounce_ms
			pin.debounce_mode = (
				GpioPin.DebounceMode.SAMPLED if state.sampled else GpioPin.DebounceMode.KERNEL
			)
			pin.action = pin.name
		else:
			pin.direction = GpioPin.Direction.OUTPUT
			pin.initial_value = state.initial
		config.pins.append(pin)
	if config.pins.is_empty():
		_write_log("Rien à exporter : aucune broche n'est réglée en entrée ou en sortie.")
		return
	for path: String in [EXPORT_USER, EXPORT_PROJECT]:
		var err: Error = ResourceSaver.save(config, path)
		if err == OK:
			_write_log(
				(
					"Configuration (%d broches) enregistrée : %s"
					% [config.pins.size(), ProjectSettings.globalize_path(path)]
				)
			)
		else:
			_write_log(
				"[color=#ff7070]Échec de l'écriture de %s (%s)[/color]" % [path, error_string(err)]
			)


func _sorted_gpios() -> Array[int]:
	var gpios: Array[int] = []
	gpios.assign(_pins.keys())
	gpios.sort()
	return gpios


func _handle_arguments() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--bouton="):
			_example_button = argument.trim_prefix("--bouton=").to_int()
	for argument: String in OS.get_cmdline_user_args():
		if argument == "--exemple":
			_load_example()
		elif argument.begins_with("--capture="):
			_capture(argument.trim_prefix("--capture="))


func _capture(path: String) -> void:
	await get_tree().create_timer(2.0).timeout
	var image: Image = get_viewport().get_texture().get_image()
	var err: Error = image.save_png(path)
	print("Capture : %s (%s)" % [path, error_string(err)])
	get_tree().quit()


# --- Affichage ----------------------------------------------------------------------


func _update_button(state: PinState) -> void:
	var button: BrocheBouton = _buttons.get(state.gpio)
	if button == null:
		return
	var fill: Color = COLOR_FREE
	match state.mode:
		Mode.INPUT:
			fill = COLOR_INPUT
		Mode.OUTPUT:
			fill = COLOR_OUTPUT
	if not state.error.is_empty():
		fill = COLOR_ERROR
	elif state.mode == Mode.FREE and not state.busy_by.is_empty():
		fill = COLOR_BUSY
	var lit: bool = state.value == 1 or (state.mode == Mode.FREE and not state.busy_by.is_empty())
	button.set_state(fill, lit, not state.busy_by.is_empty(), state.gpio == _selected)
	var label: String = "GPIO %d" % state.gpio
	for entry: Array in HEADER:
		if entry[1] == state.gpio:
			label = entry[0]
	if not state.name.is_empty():
		label += "  « %s »" % state.name
	if button.label_text != label:
		button.label_text = label
		button.queue_redraw()


func _update_live(state: PinState) -> void:
	var active: bool = state.line != null
	_indicator.color = (
		(COLOR_INPUT if state.mode == Mode.INPUT else COLOR_OUTPUT)
		if active and state.value == 1
		else Color(0.18, 0.18, 0.18)
	)
	_value_label.text = str(state.value) if active and state.value >= 0 else "—"
	var status: String = "Libre."
	if not state.error.is_empty():
		status = "Erreur : " + state.error
	elif not state.busy_by.is_empty():
		status = "Utilisée par un autre programme : « %s »." % state.busy_by
	elif state.mode == Mode.INPUT:
		status = "Entrée réservée."
	elif state.mode == Mode.OUTPUT:
		status = "Sortie réservée."
	_status.text = status
	if state.mode == Mode.INPUT:
		_stats.text = (
			"Fronts : %d    Appuis : %d    Dernier appui : %s"
			% [
				state.edges,
				state.presses,
				"%d ms" % state.last_press_ms if state.last_press_ms >= 0 else "—",
			]
		)
	else:
		_stats.text = ""
	_toggle.set_pressed_no_signal(state.value == 1)
	_toggle.text = "Éteindre" if state.value == 1 else "Allumer"
	_blink.set_pressed_no_signal(state.blinking)


func _select(gpio: int) -> void:
	if not _pins.has(gpio):
		return
	_selected = gpio
	var state: PinState = _pins[gpio]
	_syncing = true
	var physical: int = 0
	for i: int in HEADER.size():
		if HEADER[i][1] == gpio:
			physical = i + 1
	_title.text = "Broche %d : GPIO %d (ligne %d)" % [physical, gpio, state.offset]
	_name_edit.text = state.name
	for i: int in _mode_buttons.size():
		_mode_buttons[i].set_pressed_no_signal(i == state.mode)
	_bias.select(state.bias)
	_debounce.set_value_no_signal(state.debounce_ms)
	_filter.select(0 if state.sampled else 1)
	_active_low.set_pressed_no_signal(state.active_low)
	_drive.select(state.drive)
	_initial.set_pressed_no_signal(state.initial)
	_input_box.visible = state.mode == Mode.INPUT
	_output_box.visible = state.mode == Mode.OUTPUT
	_settings.visible = state.mode != Mode.FREE
	_rebuild_link_options(state)
	_syncing = false
	_update_live(state)


func _rebuild_link_options(state: PinState) -> void:
	_link.clear()
	_link.add_item("aucune", -1)
	var index: int = 0
	for gpio: int in _sorted_gpios():
		if _pins[gpio].mode == Mode.OUTPUT:
			_link.add_item("GPIO %d %s" % [gpio, _pins[gpio].name], gpio)
			if gpio == state.link:
				index = _link.item_count - 1
	_link.select(index)
	_link_invert.set_pressed_no_signal(state.link_invert)


func _write_log(text: String) -> void:
	print(text)
	if _log == null:
		return
	_log.append_text(text + "\n")
	if _log.get_paragraph_count() > MAX_LOG_LINES:
		_log.remove_paragraph(0)


# --- Réactions de l'interface ---------------------------------------------------------


func _current() -> PinState:
	return _pins.get(_selected)


func _on_mode_pressed(mode: int) -> void:
	var state: PinState = _current()
	if state == null or _syncing:
		return
	state.mode = mode
	if mode != Mode.INPUT:
		state.link = -1
	# Une sortie qui disparaît ne doit plus être commandée.
	for other: PinState in _pins.values():
		if other.link == state.gpio and mode != Mode.OUTPUT:
			other.link = -1
	_apply(state)
	_select(state.gpio)


func _on_setting_changed(_value: Variant = null) -> void:
	var state: PinState = _current()
	if state == null or _syncing:
		return
	state.bias = _bias.get_selected_id()
	state.debounce_ms = _debounce.value
	state.sampled = _filter.get_selected_id() == 0
	state.active_low = _active_low.button_pressed
	state.drive = _drive.get_selected_id()
	_apply(state)


func _on_initial_toggled(pressed: bool) -> void:
	var state: PinState = _current()
	if state != null and not _syncing:
		state.initial = pressed


func _on_name_changed(text: String) -> void:
	var state: PinState = _current()
	if state != null and not _syncing:
		state.name = text.strip_edges().replace(" ", "_")


func _on_link_selected(index: int) -> void:
	var state: PinState = _current()
	if state != null and not _syncing:
		state.link = _link.get_item_id(index)
		if state.link >= 0:
			_write_log("GPIO %d commande désormais GPIO %d." % [state.gpio, state.link])


func _on_link_invert_toggled(pressed: bool) -> void:
	var state: PinState = _current()
	if state != null and not _syncing:
		state.link_invert = pressed


func _on_toggle_pressed() -> void:
	var state: PinState = _current()
	if state != null:
		state.blinking = false
		_set_output(state, state.value != 1)


func _on_blink_toggled(pressed: bool) -> void:
	var state: PinState = _current()
	if state != null and state.mode == Mode.OUTPUT:
		state.blinking = pressed


func _on_reset_counters() -> void:
	var state: PinState = _current()
	if state != null:
		state.edges = 0
		state.presses = 0
		state.last_press_ms = -1


func _on_release_all() -> void:
	for state: PinState in _pins.values():
		state.mode = Mode.FREE
		state.link = -1
		_release(state)
		state.error = ""
	_write_log("Toutes les broches sont libérées.")
	_refresh_line_info()
	_select(_selected)


# --- Construction de l'interface ------------------------------------------------------


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = Color("#1d2026")
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)
	var root := VBoxContainer.new()
	margin.add_child(root)

	var top := HBoxContainer.new()
	root.add_child(top)
	var title := Label.new()
	title.text = "Moniteur GPIO"
	title.add_theme_font_size_override("font_size", 24)
	top.add_child(title)
	_chip_label = Label.new()
	_chip_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chip_label.modulate = Color(0.7, 0.7, 0.7)
	top.add_child(_chip_label)
	top.add_child(_button("Exemple bouton + LED", _load_example))
	top.add_child(_button("Tout libérer", _on_release_all))
	top.add_child(_button("Exporter la config", _export_config))
	top.add_child(
		_button("Menu", func() -> void: get_tree().change_scene_to_file("res://banc/banc.tscn"))
	)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	root.add_child(body)
	body.add_child(_build_header())
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(right)
	_build_panel(right)
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.custom_minimum_size.y = 120
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(_log)


func _build_header() -> Control:
	var frame := PanelContainer.new()
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("v_separation", 0)
	grid.add_theme_constant_override("h_separation", 4)
	frame.add_child(grid)
	for i: int in HEADER.size():
		var entry: Array = HEADER[i]
		var button := BrocheBouton.new()
		button.setup(i + 1, entry[0], entry[2], entry[1], i % 2 == 0)
		var gpio: int = entry[1]
		if gpio >= 0:
			_buttons[gpio] = button
			button.pressed.connect(_select.bind(gpio))
		grid.add_child(button)
	return frame


func _build_panel(parent: Control) -> void:
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 22)
	parent.add_child(_title)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(_status)

	var name_row := HBoxContainer.new()
	parent.add_child(name_row)
	name_row.add_child(_label("Nom (pour l'export)"))
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "bouton, led..."
	_name_edit.custom_minimum_size.x = 220
	_name_edit.text_changed.connect(_on_name_changed)
	name_row.add_child(_name_edit)

	var modes := HBoxContainer.new()
	parent.add_child(modes)
	var group := ButtonGroup.new()
	for i: int in 3:
		var mode_button := Button.new()
		mode_button.text = ["Libre", "Entrée", "Sortie"][i]
		mode_button.toggle_mode = true
		mode_button.button_group = group
		mode_button.custom_minimum_size = Vector2(130, 44)
		mode_button.pressed.connect(_on_mode_pressed.bind(i))
		modes.add_child(mode_button)
		_mode_buttons.append(mode_button)

	_settings = VBoxContainer.new()
	parent.add_child(_settings)
	_active_low = CheckBox.new()
	_active_low.text = "Actif à l'état bas (bouton vers la masse, relais actif bas)"
	_active_low.toggled.connect(_on_setting_changed)
	_settings.add_child(_active_low)

	_input_box = HBoxContainer.new()
	_settings.add_child(_input_box)
	_input_box.add_child(_label("Tirage"))
	_bias = _options(["inchangé", "aucun", "pull-up", "pull-down"])
	_input_box.add_child(_bias)
	_input_box.add_child(_label("Anti-rebond (ms)"))
	_debounce = SpinBox.new()
	_debounce.max_value = 1000
	_debounce.step = 1
	_debounce.value_changed.connect(_on_setting_changed)
	_input_box.add_child(_debounce)
	_filter = _options(["par échantillonnage", "par le noyau"])
	_filter.tooltip_text = (
		"Échantillonnage : robuste aux parasites (câbles longs).\n"
		+ "Noyau : horodatage précis, mais bloqué par les parasites."
	)
	_input_box.add_child(_filter)

	_output_box = VBoxContainer.new()
	_settings.add_child(_output_box)
	var drive_row := HBoxContainer.new()
	_output_box.add_child(drive_row)
	drive_row.add_child(_label("Mode"))
	_drive = _options(["push-pull", "drain ouvert", "source ouverte"])
	drive_row.add_child(_drive)
	_initial = CheckBox.new()
	_initial.text = "Allumée au démarrage du jeu (export)"
	_initial.toggled.connect(_on_initial_toggled)
	drive_row.add_child(_initial)
	var actions := HBoxContainer.new()
	_output_box.add_child(actions)
	_toggle = _button("Allumer", _on_toggle_pressed)
	_toggle.custom_minimum_size = Vector2(160, 52)
	actions.add_child(_toggle)
	var pulse := _button("Impulsion 0,2 s", func() -> void: _pulse(_current()))
	pulse.custom_minimum_size.y = 52
	actions.add_child(pulse)
	_blink = Button.new()
	_blink.text = "Clignoter"
	_blink.toggle_mode = true
	_blink.custom_minimum_size.y = 52
	_blink.toggled.connect(_on_blink_toggled)
	actions.add_child(_blink)

	var live := HBoxContainer.new()
	live.add_theme_constant_override("separation", 16)
	parent.add_child(live)
	_indicator = ColorRect.new()
	_indicator.custom_minimum_size = Vector2(64, 64)
	live.add_child(_indicator)
	_value_label = Label.new()
	_value_label.add_theme_font_size_override("font_size", 40)
	live.add_child(_value_label)
	var stats_box := VBoxContainer.new()
	live.add_child(stats_box)
	_stats = Label.new()
	stats_box.add_child(_stats)
	var link_row := HBoxContainer.new()
	stats_box.add_child(link_row)
	link_row.add_child(_label("Commande la sortie"))
	_link = OptionButton.new()
	_link.item_selected.connect(_on_link_selected)
	link_row.add_child(_link)
	_link_invert = CheckBox.new()
	_link_invert.text = "inversée"
	_link_invert.toggled.connect(_on_link_invert_toggled)
	link_row.add_child(_link_invert)
	stats_box.add_child(_button("Remettre les compteurs à zéro", _on_reset_counters))
	_input_box.visibility_changed.connect(func() -> void: link_row.visible = _input_box.visible)


func _options(items: Array) -> OptionButton:
	var option := OptionButton.new()
	for i: int in items.size():
		option.add_item(items[i], i)
	option.item_selected.connect(_on_setting_changed)
	return option


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	return button
