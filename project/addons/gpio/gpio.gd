class_name GpioService
extends Node
## Autoload [code]Gpio[/code] : broches GPIO nommées pour les jeux.
##
## - Les entrées deviennent des actions Godot ([InputEventAction] pressed / released)
##   et émettent [signal pin_changed].
## - Les sorties se pilotent par leur nom : [method set_pin], [method blink], [method pulse].
## - Sans la GDExtension (PC de dev) ou sans puce GPIO, tout passe en simulation :
##   les entrées se simulent au clavier ou par [method simulate_input].
##
## Règle : ne jamais planter. Une broche absente ou un accès refusé produit une
## erreur signalée ([signal pin_error]) et le reste continue.

## Une broche a changé de valeur (logique). Émis pour les entrées comme pour les sorties.
signal pin_changed(pin_name: StringName, value: bool)
## Une broche n'a pas pu être ouverte ou pilotée.
signal pin_error(pin_name: StringName, message: String)
## La configuration a été (re)chargée.
signal configured

const CONFIG_SETTING := "gpio/config_path"
const DEFAULT_CONFIG_PATH := "res://config/gpio_config.tres"
const EXTENSION_CLASS := &"GpioChip"
const AUTO_CHIP_LABELS: Array[String] = ["pinctrl-rp1", "pinctrl-bcm2711", "pinctrl-bcm2835"]
const EDGE_BOTH := 3
const DRIVE_PUSH_PULL := 0

var config: GpioConfig = null

var _simulated: bool = true
var _pins: Dictionary[StringName, _PinState] = {}
var _chips: Dictionary[String, RefCounted] = {}
var _chip_errors: Dictionary[String, String] = {}
var _general_error: String = ""


class _PinState:
	extends RefCounted
	enum Effect { NONE, BLINK, PULSE }

	var pin: GpioPin
	var line: RefCounted = null
	var value: bool = false
	var error: String = ""
	var timer: Timer = null
	var effect: Effect = Effect.NONE
	var toggles_left: int = 0

	func _init(p_pin: GpioPin) -> void:
		pin = p_pin


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var path: String = ProjectSettings.get_setting(CONFIG_SETTING, DEFAULT_CONFIG_PATH)
	var loaded: GpioConfig = null
	if ResourceLoader.exists(path):
		loaded = load(path) as GpioConfig
	if loaded == null:
		_general_error = "configuration GPIO introuvable ou invalide : %s" % path
		push_warning("[Gpio] %s (aucune broche)" % _general_error)
		loaded = GpioConfig.new()
	setup(loaded)


func _exit_tree() -> void:
	shutdown()


func _input(event: InputEvent) -> void:
	if not _simulated:
		return
	var key_event: InputEventKey = event as InputEventKey
	if key_event == null or key_event.echo:
		return
	for state: _PinState in _pins.values():
		var key: Key = state.pin.sim_key
		if key == KEY_NONE or not state.pin.is_input():
			continue
		if key_event.keycode == key or key_event.physical_keycode == key:
			simulate_input(state.pin.name, key_event.pressed)


## (Re)configure toutes les broches. Libère d'abord celles déjà ouvertes.
func setup(new_config: GpioConfig) -> void:
	shutdown()
	config = new_config if new_config != null else GpioConfig.new()
	_simulated = _detect_simulation()
	if _simulated:
		print_rich("[color=yellow][Gpio] Mode simulation[/color] (%s)" % _simulation_reason())
	for pin: GpioPin in config.pins:
		_add_pin(pin)
	configured.emit()


## Libère les lignes et ferme les puces. Appelé automatiquement en quittant.
func shutdown() -> void:
	for state: _PinState in _pins.values():
		_stop_effect(state)
		if state.timer != null:
			state.timer.queue_free()
		if state.line != null:
			if state.pin.is_output() and config != null and config.reset_outputs_on_exit:
				state.line.call(&"set_value", false)
			state.line.call(&"release")
			state.line = null
	_pins.clear()
	for chip: RefCounted in _chips.values():
		if chip != null:
			chip.call(&"close")
	_chips.clear()
	_chip_errors.clear()


## true si les broches sont simulées (pas de matériel).
func is_simulated() -> bool:
	return _simulated


func has_pin(pin_name: StringName) -> bool:
	return _pins.has(pin_name)


func get_pin_names() -> Array[StringName]:
	var names: Array[StringName] = []
	names.assign(_pins.keys())
	return names


## Valeur logique d'une broche. Pour une entrée réelle, relit la ligne.
func get_pin(pin_name: StringName) -> bool:
	var state: _PinState = _get_state(pin_name)
	if state == null:
		return false
	if not _simulated and state.line != null and state.pin.is_input():
		var raw: int = state.line.call(&"get_value")
		if raw < 0:
			_report(state, str(state.line.call(&"get_last_error")))
		else:
			_apply_input(state, raw == 1)
	return state.value


## Écrit une sortie (annule un clignotement ou une impulsion en cours).
func set_pin(pin_name: StringName, value: bool) -> bool:
	var state: _PinState = _get_output(pin_name)
	if state == null:
		return false
	_stop_effect(state)
	return _write(state, value)


## Inverse une sortie. Renvoie la nouvelle valeur.
func toggle_pin(pin_name: StringName) -> bool:
	var state: _PinState = _get_output(pin_name)
	if state == null:
		return false
	set_pin(pin_name, not state.value)
	return state.value


## Fait clignoter une sortie : [param count] allumages de [param period] secondes
## (moitié allumé, moitié éteint), puis éteint. [param count] <= 0 : sans fin.
func blink(pin_name: StringName, period: float = 0.5, count: int = 3) -> void:
	var state: _PinState = _get_output(pin_name)
	if state == null:
		return
	_stop_effect(state)
	state.effect = _PinState.Effect.BLINK
	state.toggles_left = count * 2 - 1 if count > 0 else -1
	_write(state, true)
	state.timer.one_shot = false
	state.timer.start(maxf(period * 0.5, 0.01))


## Allume une sortie pendant [param duration] secondes puis l'éteint.
func pulse(pin_name: StringName, duration: float = 0.2) -> void:
	var state: _PinState = _get_output(pin_name)
	if state == null:
		return
	_stop_effect(state)
	state.effect = _PinState.Effect.PULSE
	_write(state, true)
	state.timer.one_shot = true
	state.timer.start(maxf(duration, 0.01))


## Arrête un clignotement ou une impulsion, sans changer la valeur actuelle.
func stop_effect(pin_name: StringName) -> void:
	var state: _PinState = _get_state(pin_name)
	if state != null:
		_stop_effect(state)


## Injecte une valeur sur une entrée (simulation, tests, panneau de diagnostic).
func simulate_input(pin_name: StringName, value: bool) -> void:
	var state: _PinState = _get_state(pin_name)
	if state == null:
		return
	if not state.pin.is_input():
		_report(state, "simulate_input() sur une sortie : utilisez set_pin()")
		return
	_apply_input(state, value)


## Dernière erreur d'une broche ("" si tout va bien).
func get_pin_error(pin_name: StringName) -> String:
	var state: _PinState = _pins.get(pin_name)
	return state.error if state != null else "broche inconnue : %s" % pin_name


## Toutes les erreurs : broches et configuration.
func get_errors() -> PackedStringArray:
	var errors: PackedStringArray = []
	if not _general_error.is_empty():
		errors.append(_general_error)
	for state: _PinState in _pins.values():
		if not state.error.is_empty():
			errors.append("%s : %s" % [state.pin.name, state.error])
	return errors


## État de chaque broche, pour un panneau de diagnostic ou des logs.
func get_status() -> Array[Dictionary]:
	var status: Array[Dictionary] = []
	for state: _PinState in _pins.values():
		var entry: Dictionary = {
			"name": state.pin.name,
			"direction": "input" if state.pin.is_input() else "output",
			"chip": _chip_spec(state.pin),
			"line": state.pin.line,
			"value": state.value,
			"action": state.pin.action,
			"sim_key": state.pin.sim_key,
			"hardware": state.line != null,
			"effect": state.effect != _PinState.Effect.NONE,
			"error": state.error,
		}
		status.append(entry)
	return status


## Résumé texte de l'état (mode, puces, broches) : pratique pour un log ou l'overlay F12.
func describe() -> String:
	var lines: PackedStringArray = []
	lines.append(
		"GPIO : %s" % ("simulation (%s)" % _simulation_reason() if _simulated else "matériel")
	)
	for spec: String in _chips:
		var chip: RefCounted = _chips[spec]
		if chip != null:
			lines.append("  puce %s -> %s" % [spec, chip.call(&"get_path")])
	for state: _PinState in _pins.values():
		var text: String = "  %s = %d" % [state.pin.describe(), int(state.value)]
		if not state.error.is_empty():
			text += "  [ERREUR] " + state.error
		lines.append(text)
	return "\n".join(lines)


# --- Ouverture -------------------------------------------------------------------


func _detect_simulation() -> bool:
	match config.simulation:
		GpioConfig.SimulationMode.ALWAYS:
			return true
		GpioConfig.SimulationMode.NEVER:
			return false
	if not ClassDB.class_exists(EXTENSION_CLASS):
		return true
	var probe: RefCounted = ClassDB.instantiate(EXTENSION_CLASS)
	if not bool(probe.call(&"is_supported")):
		return true
	var chips: Array = probe.call(&"list_chips")
	return chips.is_empty()


func _simulation_reason() -> String:
	if config != null and config.simulation == GpioConfig.SimulationMode.ALWAYS:
		return "forcé par la configuration"
	if not ClassDB.class_exists(EXTENSION_CLASS):
		return "extension GPIO non chargée sur cette plateforme"
	return "aucune puce GPIO sur cette machine"


func _add_pin(pin: GpioPin) -> void:
	if pin == null:
		return
	if pin.name == &"":
		_general_error = "une broche de la configuration n'a pas de nom (ligne %d)" % pin.line
		push_error("[Gpio] " + _general_error)
		return
	if _pins.has(pin.name):
		push_error("[Gpio] broche « %s » déclarée deux fois : la seconde est ignorée" % pin.name)
		return

	var state := _PinState.new(pin)
	_pins[pin.name] = state

	if pin.is_output():
		state.value = pin.initial_value
		state.timer = Timer.new()
		state.timer.name = "Effect_%s" % pin.name
		state.timer.timeout.connect(_on_effect_timeout.bind(state))
		add_child(state.timer)
	elif pin.action != &"" and not InputMap.has_action(pin.action):
		InputMap.add_action(pin.action)
		push_warning(
			(
				"[Gpio] action « %s » absente de l'InputMap : créée pour la broche « %s »"
				% [pin.action, pin.name]
			)
		)

	if _simulated:
		return
	_open_line(state)


func _open_line(state: _PinState) -> void:
	var pin: GpioPin = state.pin
	if not ClassDB.class_exists(EXTENSION_CLASS):
		_report(state, "extension GPIO non chargée (bibliothèque absente pour cette plateforme ?)")
		return
	var chip: RefCounted = _get_chip(_chip_spec(pin))
	if chip == null:
		_report(state, _chip_errors.get(_chip_spec(pin), "puce introuvable"))
		return

	var line: RefCounted = null
	if pin.is_input():
		var debounce_us: int = roundi(pin.debounce_ms * 1000.0)
		if pin.debounce_mode == GpioPin.DebounceMode.SAMPLED and debounce_us > 0:
			line = chip.call(
				&"request_input_sampled",
				pin.line,
				int(pin.bias),
				debounce_us,
				pin.active_low,
				config.consumer
			)
		else:
			line = chip.call(
				&"request_input",
				pin.line,
				int(pin.bias),
				debounce_us,
				EDGE_BOTH,
				pin.active_low,
				config.consumer
			)
	else:
		line = chip.call(
			&"request_output",
			pin.line,
			pin.initial_value,
			pin.active_low,
			DRIVE_PUSH_PULL,
			config.consumer
		)
	if line == null:
		_report(state, str(chip.call(&"get_last_error")))
		return

	state.line = line
	line.connect(&"line_error", _on_line_error.bind(state))
	if pin.is_input():
		line.connect(&"edge_detected", _on_line_edge.bind(state))
		var raw: int = line.call(&"get_value")
		if raw >= 0:
			state.value = raw == 1


func _chip_spec(pin: GpioPin) -> String:
	if not pin.chip.strip_edges().is_empty():
		return pin.chip.strip_edges()
	return config.default_chip.strip_edges() if config != null else "auto"


func _get_chip(spec: String) -> RefCounted:
	if _chips.has(spec):
		return _chips[spec]
	if _chip_errors.has(spec):
		return null
	var candidates: Array[String] = []
	if spec.is_empty() or spec == "auto":
		candidates.assign(AUTO_CHIP_LABELS)
		candidates.append("0")
	else:
		candidates.append(spec)

	var errors: PackedStringArray = []
	for candidate: String in candidates:
		var chip: RefCounted = ClassDB.instantiate(EXTENSION_CLASS)
		var err: int = chip.call(&"open", candidate)
		if err == OK:
			print("[Gpio] puce « %s » ouverte : %s" % [spec, chip.call(&"get_path")])
			_chips[spec] = chip
			return chip
		errors.append(str(chip.call(&"get_last_error")))

	var message: String = errors[errors.size() - 1] if not errors.is_empty() else "puce introuvable"
	if spec == "auto" or spec.is_empty():
		message = "aucune puce Raspberry Pi reconnue (auto) ; " + message
	_chip_errors[spec] = message
	push_error("[Gpio] " + message)
	return null


# --- Entrées / sorties ------------------------------------------------------------


func _get_state(pin_name: StringName) -> _PinState:
	var state: _PinState = _pins.get(pin_name)
	if state == null:
		push_error("[Gpio] broche inconnue : « %s »" % pin_name)
	return state


func _get_output(pin_name: StringName) -> _PinState:
	var state: _PinState = _get_state(pin_name)
	if state != null and not state.pin.is_output():
		_report(state, "la broche est une entrée : écriture impossible")
		return null
	return state


func _write(state: _PinState, value: bool) -> bool:
	if not _simulated:
		# Broche en erreur ou écriture refusée : l'état connu ne change pas.
		if state.line == null:
			return false
		var err: int = state.line.call(&"set_value", value)
		if err != OK:
			_report(state, str(state.line.call(&"get_last_error")))
			return false
	if state.value != value:
		state.value = value
		pin_changed.emit(state.pin.name, value)
	return true


func _apply_input(state: _PinState, value: bool) -> void:
	if state.value == value:
		return
	state.value = value
	if state.pin.action != &"":
		var event := InputEventAction.new()
		event.action = state.pin.action
		event.pressed = value
		event.strength = 1.0 if value else 0.0
		Input.parse_input_event(event)
	pin_changed.emit(state.pin.name, value)


func _stop_effect(state: _PinState) -> void:
	state.effect = _PinState.Effect.NONE
	state.toggles_left = 0
	if state.timer != null:
		state.timer.stop()


func _report(state: _PinState, message: String) -> void:
	if message.is_empty():
		message = "erreur inconnue"
	var changed: bool = state.error != message
	state.error = message
	if changed:
		push_error("[Gpio] %s : %s" % [state.pin.describe(), message])
		pin_error.emit(state.pin.name, message)


# --- Signaux -----------------------------------------------------------------------


func _on_line_edge(rising: bool, _timestamp_ns: int, state: _PinState) -> void:
	_apply_input(state, rising)


func _on_line_error(message: String, state: _PinState) -> void:
	_report(state, message)


func _on_effect_timeout(state: _PinState) -> void:
	match state.effect:
		_PinState.Effect.PULSE:
			_stop_effect(state)
			_write(state, false)
		_PinState.Effect.BLINK:
			if state.toggles_left == 0:
				_stop_effect(state)
				return
			if state.toggles_left > 0:
				state.toggles_left -= 1
			_write(state, not state.value)
			if state.toggles_left == 0:
				_stop_effect(state)
		_:
			state.timer.stop()
