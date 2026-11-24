@tool
extends EditorPlugin
## Active l'addon : enregistre l'autoload « Gpio ».

const AUTOLOAD_NAME := "Gpio"
const AUTOLOAD_PATH := "res://addons/gpio/gpio.gd"


func _enable_plugin() -> void:
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	if not ProjectSettings.has_setting(GpioService.CONFIG_SETTING):
		ProjectSettings.set_setting(GpioService.CONFIG_SETTING, GpioService.DEFAULT_CONFIG_PATH)
		ProjectSettings.set_initial_value(
			GpioService.CONFIG_SETTING, GpioService.DEFAULT_CONFIG_PATH
		)
		ProjectSettings.save()


func _disable_plugin() -> void:
	if ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		remove_autoload_singleton(AUTOLOAD_NAME)
