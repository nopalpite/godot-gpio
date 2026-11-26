extends Control
## Menu du banc de test GPIO :
##   godot --path project res://banc/banc.tscn

const TEXT := """Test automatique : relier par un fil GPIO 23 (broche 16) et GPIO 24 (broche 18).
Laisser GPIO 25 (broche 22) libre, reliée à rien. Durée : environ 15 secondes.
Un rapport est écrit dans user://rapports/.

Banc manuel : réserver n'importe quelle ligne en entrée ou en sortie
pour essayer un bouton, une LED, un relais..."""


func _ready() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	center.add_child(box)

	var title := Label.new()
	title.text = "Banc de test GPIO"
	title.add_theme_font_size_override("font_size", 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var help := Label.new()
	help.text = TEXT
	box.add_child(help)
	box.add_child(_button("Test automatique", "res://banc/test_materiel.tscn"))
	box.add_child(_button("Banc manuel", "res://banc/banc_manuel.tscn"))
	var quit := Button.new()
	quit.text = "Quitter"
	quit.pressed.connect(get_tree().quit)
	box.add_child(quit)


func _button(text: String, scene: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(320, 56)
	button.pressed.connect(func() -> void: get_tree().change_scene_to_file(scene))
	return button
