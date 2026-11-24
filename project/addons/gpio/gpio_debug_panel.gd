class_name GpioDebugPanel
extends PanelContainer
## Panneau de diagnostic GPIO, réutilisable tel quel.
##
## Affiche le mode (matériel ou simulation), chaque broche, sa valeur et ses erreurs.
## Les entrées se simulent à la souris (bouton maintenu), les sorties se basculent.
## Il suffit de l'instancier : [code]add_child(GpioDebugPanel.new())[/code],
## par exemple dans l'overlay de debug (F12) du template.

const COLOR_ON := Color(0.2, 0.85, 0.35)
const COLOR_OFF := Color(0.25, 0.25, 0.28)
const COLOR_ERROR := Color(1.0, 0.4, 0.35)
const COLOR_SIMULATION := Color(1.0, 0.8, 0.3)

## Chemin de l'autoload.
@export var gpio_path: NodePath = ^"/root/Gpio"

var _gpio: GpioService = null
var _title: Label
var _grid: GridContainer
var _errors: Label
var _indicators: Dictionary[StringName, ColorRect] = {}
var _toggles: Dictionary[StringName, CheckButton] = {}


func _ready() -> void:
	custom_minimum_size = Vector2(360, 0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var box := VBoxContainer.new()
	add_child(box)

	_title = Label.new()
	box.add_child(_title)

	_grid = GridContainer.new()
	_grid.columns = 4
	_grid.add_theme_constant_override(&"h_separation", 12)
	box.add_child(_grid)

	_errors = Label.new()
	_errors.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_errors.add_theme_color_override(&"font_color", COLOR_ERROR)
	box.add_child(_errors)

	_gpio = get_node_or_null(gpio_path) as GpioService
	if _gpio == null:
		_title.text = "GPIO : autoload introuvable (%s)" % gpio_path
		_title.add_theme_color_override(&"font_color", COLOR_ERROR)
		return
	_gpio.pin_changed.connect(_on_pin_changed)
	_gpio.pin_error.connect(_on_pin_error)
	_gpio.configured.connect(_rebuild)
	_rebuild()


func _rebuild() -> void:
	for child: Node in _grid.get_children():
		child.queue_free()
	_indicators.clear()
	_toggles.clear()

	if _gpio.is_simulated():
		_title.text = "GPIO : SIMULATION"
		_title.add_theme_color_override(&"font_color", COLOR_SIMULATION)
	else:
		_title.text = "GPIO : matériel"
		_title.remove_theme_color_override(&"font_color")

	for info: Dictionary in _gpio.get_status():
		_add_row(info)
	_refresh_errors()


func _add_row(info: Dictionary) -> void:
	var pin_name: StringName = info["name"]
	var is_input: bool = info["direction"] == "input"

	var indicator := ColorRect.new()
	indicator.custom_minimum_size = Vector2(16, 16)
	indicator.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	indicator.color = COLOR_ON if info["value"] else COLOR_OFF
	_grid.add_child(indicator)
	_indicators[pin_name] = indicator

	var label := Label.new()
	label.text = String(pin_name)
	_grid.add_child(label)

	var detail := Label.new()
	var detail_text: String = "%s, ligne %d" % ["entrée" if is_input else "sortie", info["line"]]
	if is_input and info["sim_key"] != KEY_NONE and _gpio.is_simulated():
		detail_text += ", touche %s" % OS.get_keycode_string(info["sim_key"])
	if is_input and info["action"] != &"":
		detail_text += " -> %s" % info["action"]
	detail.text = detail_text
	detail.modulate = Color(1, 1, 1, 0.7)
	_grid.add_child(detail)

	if is_input:
		var button := Button.new()
		button.text = "Appuyer"
		button.tooltip_text = "Maintenir pour simuler l'entrée"
		button.button_down.connect(_gpio.simulate_input.bind(pin_name, true))
		button.button_up.connect(_gpio.simulate_input.bind(pin_name, false))
		_grid.add_child(button)
	else:
		var toggle := CheckButton.new()
		toggle.button_pressed = info["value"]
		toggle.toggled.connect(_on_output_toggled.bind(pin_name))
		_grid.add_child(toggle)
		_toggles[pin_name] = toggle


func _refresh_errors() -> void:
	_errors.text = "\n".join(_gpio.get_errors())
	_errors.visible = not _errors.text.is_empty()


func _on_output_toggled(pressed: bool, pin_name: StringName) -> void:
	if _gpio.get_pin(pin_name) != pressed:
		_gpio.set_pin(pin_name, pressed)


func _on_pin_changed(pin_name: StringName, value: bool) -> void:
	var indicator: ColorRect = _indicators.get(pin_name)
	if indicator != null:
		indicator.color = COLOR_ON if value else COLOR_OFF
	var toggle: CheckButton = _toggles.get(pin_name)
	if toggle != null:
		toggle.set_pressed_no_signal(value)


func _on_pin_error(_pin_name: StringName, _message: String) -> void:
	_refresh_errors()
