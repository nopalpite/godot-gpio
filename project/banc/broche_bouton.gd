extends Button
## Une broche du connecteur 40 broches, dessinée comme sur la carte : un disque coloré
## (allumé quand la ligne est à 1) et son étiquette du côté extérieur.

enum Kind { GPIO, POWER_3V3, POWER_5V, GROUND }

const KIND_COLORS: Array[Color] = [
	Color("#7a7a7a"),  # GPIO libre
	Color("#e06c2b"),  # 3,3 V
	Color("#d62f2f"),  # 5 V
	Color("#202020"),  # masse
]

var physical: int = 0
var gpio: int = -1
var kind: Kind = Kind.GPIO
var label_on_left: bool = false
var label_text: String = ""
var fill: Color = KIND_COLORS[0]
var lit: bool = false
var hatched: bool = false
var selected: bool = false


func setup(p_physical: int, p_label: String, p_kind: Kind, p_gpio: int, left: bool) -> void:
	physical = p_physical
	label_text = p_label
	kind = p_kind
	gpio = p_gpio
	label_on_left = left
	fill = KIND_COLORS[kind]
	flat = true
	focus_mode = Control.FOCUS_NONE
	disabled = kind != Kind.GPIO
	custom_minimum_size = Vector2(250, 30)
	tooltip_text = "Broche %d : %s" % [physical, label_text]


func set_state(p_fill: Color, p_lit: bool, p_hatched: bool, p_selected: bool) -> void:
	if fill == p_fill and lit == p_lit and hatched == p_hatched and selected == p_selected:
		return
	fill = p_fill
	lit = p_lit
	hatched = p_hatched
	selected = p_selected
	queue_redraw()


func _draw() -> void:
	var radius: float = size.y * 0.38
	var center := Vector2(size.x - radius - 6.0 if label_on_left else radius + 6.0, size.y * 0.5)
	if selected:
		draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.12))
		draw_circle(center, radius + 4.0, Color.WHITE, false, 2.0)
	var color: Color = fill if lit or kind != Kind.GPIO else fill.darkened(0.55)
	draw_circle(center, radius, color)
	if kind == Kind.GROUND:
		draw_circle(center, radius, Color(0.55, 0.55, 0.55), false, 1.5)
	if lit:
		draw_circle(center, radius * 0.45, Color(1, 1, 1, 0.75))
	if hatched:
		for i: int in 3:
			var offset: float = (i - 1) * radius * 0.6
			draw_line(
				center + Vector2(offset - radius * 0.5, radius * 0.5),
				center + Vector2(offset + radius * 0.5, -radius * 0.5),
				Color(0, 0, 0, 0.8),
				2.0
			)
	var font: Font = get_theme_default_font()
	var font_size: int = get_theme_default_font_size()
	var number: String = str(physical)
	var number_width: float = font.get_string_size(number, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	draw_string(
		font,
		center + Vector2(-number_width * 0.5, 4.0),
		number,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		12,
		Color.BLACK if lit else Color.WHITE
	)
	var text_width: float = (
		font.get_string_size(label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	)
	var text_x: float = (
		center.x - radius - 10.0 - text_width if label_on_left else center.x + radius + 10.0
	)
	var text_color: Color = Color.WHITE if kind == Kind.GPIO else Color(0.65, 0.65, 0.65)
	draw_string(
		font,
		Vector2(text_x, size.y * 0.5 + font_size * 0.35),
		label_text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size,
		text_color
	)
