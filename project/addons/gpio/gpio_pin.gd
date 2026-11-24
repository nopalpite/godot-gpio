@tool
class_name GpioPin
extends Resource
## Une broche GPIO nommée, telle que les jeux la voient.
##
## Le jeu ne manipule que le [member name] ; le câblage (puce, numéro de ligne,
## résistance de tirage...) reste dans la configuration.

enum Direction { INPUT, OUTPUT }

## Même ordre que [code]GpioChip.Bias[/code] dans la GDExtension.
enum Bias {
	AS_IS,  ## Ne touche pas au réglage actuel de la broche.
	NONE,  ## Aucune résistance de tirage (résistance externe).
	PULL_UP,  ## Tirage vers 3,3 V : bouton câblé entre la broche et la masse.
	PULL_DOWN,  ## Tirage vers la masse : bouton câblé entre la broche et 3,3 V.
}

## Nom utilisé par le jeu : [code]Gpio.set_pin(&"led", true)[/code].
@export var name: StringName = &""
## Puce GPIO : label ([code]pinctrl-rp1[/code], [code]pinctrl-bcm2711[/code]), nom
## ([code]gpiochip0[/code]) ou numéro. Vide : la puce par défaut de [GpioConfig].
@export var chip: String = ""
## Numéro de ligne sur la puce. Sur le connecteur 40 broches du Pi, c'est le
## numéro BCM (GPIO17 = 17), pas le numéro physique de la broche.
@export_range(0, 63) var line: int = 0
@export var direction: Direction = Direction.INPUT
## Inverse la logique : la valeur 1 correspond au niveau électrique bas.
## Typique pour un bouton câblé vers la masse avec [constant PULL_UP].
@export var active_low: bool = false

@export_group("Entrée")
@export var bias: Bias = Bias.PULL_UP
## Anti-rebond appliqué par le noyau, en millisecondes (0 = aucun).
@export_range(0.0, 1000.0, 0.1, "suffix:ms") var debounce_ms: float = 20.0
## Action Godot déclenchée (pressed / released) quand l'entrée change.
@export var action: StringName = &""
## Touche qui simule cette entrée en mode simulation.
@export var sim_key: Key = KEY_NONE

@export_group("Sortie")
## Valeur logique au démarrage.
@export var initial_value: bool = false


func is_input() -> bool:
	return direction == Direction.INPUT


func is_output() -> bool:
	return direction == Direction.OUTPUT


## Description courte pour les messages et le panneau de diagnostic.
func describe() -> String:
	var kind: String = "entrée" if is_input() else "sortie"
	var where: String = chip if not chip.is_empty() else "puce par défaut"
	return "%s %s, ligne %d (%s)" % [name, kind, line, where]
