extends RefCounted
## Résultats du banc : affichage (console et interface) et rapport texte.

enum Status { OK, KO, IGNORE, INFO }

const STATUS_TEXT: Array[String] = ["OK", "KO", "IGNORÉ", "INFO"]
const STATUS_COLOR: Array[String] = ["#5fd35f", "#ff5f5f", "#c0c0c0", "#7fb2ff"]

## Ligne de paramètres affichée en tête et écrite dans le rapport.
var header: String = ""
var output_log: RichTextLabel = null
var summary: Label = null

var _results: Array[Dictionary] = []
var _section: String = ""


func reset() -> void:
	_results.clear()
	_section = ""
	if output_log != null:
		output_log.clear()
	emit("BANC GPIO : " + header, "[b]Banc GPIO[/b] : " + header.replace("[", "[lb]"))


func begin(section: String) -> void:
	_section = section
	emit("\n== %s ==" % section, "[b]%s[/b]" % section)


func check(condition: bool, title: String, detail: String = "") -> void:
	add(Status.OK if condition else Status.KO, title, detail)


func add(status: Status, title: String, detail: String = "") -> void:
	_results.append({"section": _section, "status": status, "name": title, "detail": detail})
	var text: String = "  [%s] %s" % [STATUS_TEXT[status], title]
	if not detail.is_empty():
		text += " : " + detail
	var rich: String = (
		"  [color=%s][%s][/color] %s"
		% [STATUS_COLOR[status], STATUS_TEXT[status], title.replace("[", "[lb]")]
	)
	if not detail.is_empty():
		rich += " [color=#a0a0a0]: %s[/color]" % detail.replace("[", "[lb]")
	emit(text, rich)


func emit(text: String, rich: String) -> void:
	print(text)
	if output_log != null:
		output_log.append_text(rich + "\n")


func count(status: Status) -> int:
	var total: int = 0
	for result: Dictionary in _results:
		if result["status"] == status:
			total += 1
	return total


func finish() -> void:
	var text: String = (
		"%d OK, %d KO, %d ignoré(s), %d info(s)"
		% [count(Status.OK), count(Status.KO), count(Status.IGNORE), count(Status.INFO)]
	)
	emit("\nRÉSULTAT : " + text, "\n[b]Résultat : %s[/b]" % text)
	if summary != null:
		summary.text = text
		summary.modulate = Color("#ff7070") if count(Status.KO) > 0 else Color("#70ff70")
	_save()


func _save() -> void:
	DirAccess.make_dir_recursive_absolute("user://rapports")
	var stamp: String = Time.get_datetime_string_from_system().replace(":", "-")
	var path: String = "user://rapports/banc-gpio-%s.txt" % stamp
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		print("Rapport non écrit (%s)" % error_string(FileAccess.get_open_error()))
		return
	file.store_line("Banc GPIO, %s" % Time.get_datetime_string_from_system(true))
	file.store_line(header)
	var section: String = ""
	for result: Dictionary in _results:
		if result["section"] != section:
			section = result["section"]
			file.store_line("\n== %s ==" % section)
		var line: String = "[%s] %s" % [STATUS_TEXT[result["status"]], result["name"]]
		if not str(result["detail"]).is_empty():
			line += " : " + str(result["detail"])
		file.store_line(line)
	file.store_line(
		"\n%d OK, %d KO, %d ignoré(s)" % [count(Status.OK), count(Status.KO), count(Status.IGNORE)]
	)
	file.close()
	var absolute: String = ProjectSettings.globalize_path(path)
	emit("Rapport : " + absolute, "Rapport : " + absolute.replace("[", "[lb]"))
