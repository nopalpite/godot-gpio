@tool
class_name GpioConfig
extends Resource
## Configuration de l'autoload [code]Gpio[/code] : liste des broches nommées.
##
## Par défaut l'autoload charge [code]res://config/gpio_config.tres[/code]
## (réglage de projet [code]gpio/config_path[/code]).

enum SimulationMode {
	AUTO,  ## Simulation si l'extension n'est pas chargée ou s'il n'y a aucune puce GPIO.
	ALWAYS,  ## Toujours simuler, même sur le Pi (tests sans câblage).
	NEVER,  ## Jamais : sans matériel, chaque broche signale une erreur.
}

## Puce utilisée par les broches qui n'en précisent pas. [code]auto[/code] cherche
## [code]pinctrl-rp1[/code] (Pi 5), puis [code]pinctrl-bcm2711[/code] (Pi 4),
## puis [code]pinctrl-bcm2835[/code], puis la puce 0.
@export var default_chip: String = "auto"
@export var simulation: SimulationMode = SimulationMode.AUTO
## Nom affiché par [code]gpioinfo[/code] pour les lignes réservées par Godot.
@export var consumer: String = "godot"
## Remet les sorties à 0 (valeur logique) en quittant.
@export var reset_outputs_on_exit: bool = true
@export var pins: Array[GpioPin] = []
