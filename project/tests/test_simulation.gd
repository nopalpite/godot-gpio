extends Node
## Test automatique, sans écran ni matériel :
##   godot --headless --path project res://tests/test_simulation.tscn
## Code de sortie 0 si tout passe, 1 sinon.
##
## Vérifie le mode simulation de l'autoload Gpio, la règle « ne jamais planter »
## et, si la GDExtension est chargée (Linux), ses messages d'erreur.

var _failures: PackedStringArray = []
var _changes: Array[Array] = []


func _ready() -> void:
	Gpio.pin_changed.connect(
		func(pin_name: StringName, value: bool) -> void: _changes.append([pin_name, value])
	)
	await _run()
	if _failures.is_empty():
		print("TEST GPIO : OK")
		get_tree().quit(0)
	else:
		for failure: String in _failures:
			printerr("ÉCHEC : " + failure)
		print("TEST GPIO : %d échec(s)" % _failures.size())
		get_tree().quit(1)


func _run() -> void:
	print(Gpio.describe())
	_check(Gpio.is_simulated(), "le mode simulation doit être actif sans matériel")
	_check(
		Gpio.get_errors().is_empty(),
		"aucune erreur attendue en simulation : %s" % Gpio.get_errors()
	)
	_check(Gpio.has_pin(&"bouton") and Gpio.has_pin(&"led"), "broches de la configuration chargées")

	# Entrée -> action Godot + signal.
	_changes.clear()
	Gpio.simulate_input(&"bouton", true)
	await _frames(2)
	_check(Input.is_action_pressed(&"bouton_rouge"), "l'action bouton_rouge doit être pressée")
	_check(_changes.has([&"bouton", true]), "pin_changed(bouton, true) attendu")
	_check(Gpio.get_pin(&"led"), "la scène d'exemple doit allumer la LED")
	Gpio.simulate_input(&"bouton", false)
	await _frames(2)
	_check(not Input.is_action_pressed(&"bouton_rouge"), "l'action bouton_rouge doit être relâchée")
	_check(not Gpio.get_pin(&"led"), "la LED doit être éteinte au relâchement")

	# Touche de simulation (espace).
	var key := InputEventKey.new()
	key.keycode = KEY_SPACE
	key.pressed = true
	Input.parse_input_event(key)
	await _frames(2)
	_check(Gpio.get_pin(&"bouton"), "la touche espace doit simuler le bouton")
	key = key.duplicate()
	key.pressed = false
	Input.parse_input_event(key)
	await _frames(2)
	_check(not Gpio.get_pin(&"bouton"), "relâcher espace doit relâcher le bouton")

	# Sorties : set_pin, pulse, blink.
	Gpio.stop_effect(&"gyrophare")
	Gpio.set_pin(&"gyrophare", false)
	_check(Gpio.set_pin(&"led", true) and Gpio.get_pin(&"led"), "set_pin(led, true)")
	_check(not Gpio.toggle_pin(&"led"), "toggle_pin inverse la sortie")
	Gpio.pulse(&"led", 0.1)
	_check(Gpio.get_pin(&"led"), "pulse allume immédiatement")
	await get_tree().create_timer(0.25).timeout
	_check(not Gpio.get_pin(&"led"), "pulse éteint après la durée")

	_changes.clear()
	Gpio.blink(&"gyrophare", 0.06, 3)
	await get_tree().create_timer(0.5).timeout
	var ons: int = _changes.count([&"gyrophare", true])
	var offs: int = _changes.count([&"gyrophare", false])
	_check(
		ons == 3 and offs == 3,
		"blink(3) : 3 allumages et 3 extinctions (reçu %d / %d)" % [ons, offs]
	)
	_check(not Gpio.get_pin(&"gyrophare"), "blink se termine éteint")

	# Ne jamais planter : broche inconnue, mauvais sens.
	_check(not Gpio.set_pin(&"inexistante", true), "set_pin sur une broche inconnue renvoie false")
	_check(not Gpio.get_pin(&"inexistante"), "get_pin sur une broche inconnue renvoie false")
	_check(not Gpio.set_pin(&"bouton", true), "écrire une entrée est refusé")
	Gpio.blink(&"inexistante")
	Gpio.pulse(&"bouton")

	await _test_extension()
	await _test_hardware_errors()


## Sans matériel, le mode NEVER doit produire des erreurs lisibles, sans planter.
func _test_hardware_errors() -> void:
	var original: GpioConfig = Gpio.config
	var config := GpioConfig.new()
	config.simulation = GpioConfig.SimulationMode.NEVER
	config.default_chip = "pinctrl-rp1"
	var pin := GpioPin.new()
	pin.name = &"absente"
	pin.line = 4
	config.pins.append(pin)
	var output := GpioPin.new()
	output.name = &"sortie_absente"
	output.direction = GpioPin.Direction.OUTPUT
	output.line = 5
	config.pins.append(output)

	Gpio.setup(config)
	_check(not Gpio.is_simulated(), "mode NEVER : pas de simulation")
	_check(
		Gpio.get_errors().size() == 2, "deux broches en erreur attendues : %s" % Gpio.get_errors()
	)
	print("Erreurs attendues (mode NEVER sans matériel) :\n  " + "\n  ".join(Gpio.get_errors()))
	_check(
		not Gpio.set_pin(&"sortie_absente", true), "écrire une broche sans matériel renvoie false"
	)
	_check(not Gpio.get_pin(&"absente"), "lire une broche sans matériel renvoie false")

	Gpio.setup(original)
	_check(Gpio.is_simulated() and Gpio.has_pin(&"led"), "retour à la configuration d'origine")
	await _frames(1)


## Si la GDExtension est chargée (Linux), elle doit répondre sans planter.
func _test_extension() -> void:
	if not ClassDB.class_exists(&"GpioChip"):
		print("GDExtension non chargée sur cette plateforme : tests de l'extension ignorés.")
		return
	var chip: RefCounted = ClassDB.instantiate(&"GpioChip")
	print("GDExtension chargée. is_supported = %s" % chip.call(&"is_supported"))
	print("Puces : %s" % [chip.call(&"list_chips")])
	var err: int = chip.call(&"open", "pinctrl-n-existe-pas")
	_check(err != OK, "ouvrir une puce inexistante échoue")
	var message: String = chip.call(&"get_last_error")
	print("Erreur attendue : " + message)
	_check(not message.is_empty(), "un message d'erreur lisible est fourni")
	var line: Variant = chip.call(&"request_input", 17)
	_check(line == null, "réserver une ligne sur une puce fermée renvoie null")
	print("Erreur attendue : " + str(chip.call(&"get_last_error")))
	await _frames(1)


func _frames(count: int) -> void:
	for i: int in count:
		await get_tree().process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok  " + message)
	else:
		_failures.append(message)
		print("  KO  " + message)
