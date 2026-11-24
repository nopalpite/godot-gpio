extends Control
## Exemple : le bouton (GPIO17) allume la LED (GPIO27) tant qu'il est appuyé.
## Au relâchement, le gyrophare (GPIO22) clignote trois fois.
##
## En simulation (PC), la barre d'espace remplace le bouton, ou le panneau de droite.

@onready var _state_label: Label = %StateLabel


func _ready() -> void:
	Gpio.pin_changed.connect(_on_pin_changed)
	print(Gpio.describe())
	_update_label()


func _unhandled_input(event: InputEvent) -> void:
	# Le jeu ne connaît que l'action : clavier, OSC ou GPIO, c'est pareil.
	if event.is_action_pressed(&"bouton_rouge"):
		Gpio.set_pin(&"led", true)
	elif event.is_action_released(&"bouton_rouge"):
		Gpio.set_pin(&"led", false)
		Gpio.blink(&"gyrophare", 0.4, 3)


func _on_pin_changed(_pin_name: StringName, _value: bool) -> void:
	_update_label()


func _update_label() -> void:
	var mode: String = "simulation (espace = bouton)" if Gpio.is_simulated() else "matériel"
	_state_label.text = (
		"Mode : %s\nBouton : %s\nLED : %s\nGyrophare : %s"
		% [
			mode,
			_pin_text(&"bouton", "appuyé", "relâché"),
			_pin_text(&"led", "allumée", "éteinte"),
			_pin_text(&"gyrophare", "allumé", "éteint"),
		]
	)


func _pin_text(pin_name: StringName, on_text: String, off_text: String) -> String:
	if not Gpio.has_pin(pin_name):
		return "absent de la configuration"
	return on_text if Gpio.get_pin(pin_name) else off_text
