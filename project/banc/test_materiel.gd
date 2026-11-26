extends Control
## Test automatique du matériel GPIO, à lancer sur le Raspberry Pi.
##
## Câblage minimal (voir README, « Tester sur un Raspberry Pi ») :
##   - un fil entre la broche SORTIE (GPIO 23, broche physique 16)
##     et la broche ENTRÉE (GPIO 24, broche physique 18) ;
##   - la broche FLOTTANTE (GPIO 25, broche physique 22) ne doit être reliée à RIEN.
##
## Lancement :
##   godot --path project res://banc/test_materiel.tscn
##   godot --headless --path project res://banc/test_materiel.tscn -- --sortie=23 --entree=24
## Options : --sortie=N --entree=N --flottante=N (-1 : sans) --puce=auto|label|numéro
## Code de sortie : 0 si aucun échec (des tests peuvent être ignorés), 1 sinon.
## Un rapport texte est écrit dans user://rapports/.

const EdgeLog := preload("res://banc/journal_fronts.gd")
const Rapport := preload("res://banc/rapport.gd")
const Systeme := preload("res://banc/systeme.gd")
const CONSUMER := "banc-gpio"
const AUTO_CHIP_LABELS: Array[String] = ["pinctrl-rp1", "pinctrl-bcm2711", "pinctrl-bcm2835"]

# Valeurs des énumérations de la GDExtension (GpioChip.Bias / Edge / Drive).
const BIAS_DISABLED := 1
const BIAS_PULL_UP := 2
const BIAS_PULL_DOWN := 3
const EDGE_NONE := 0
const EDGE_RISING := 1
const EDGE_FALLING := 2
const EDGE_BOTH := 3
const DRIVE_PUSH_PULL := 0
const DRIVE_OPEN_DRAIN := 1
const DRIVE_OPEN_SOURCE := 2

var output_line: int = 23
var input_line: int = 24
var floating_line: int = 25
var chip_spec: String = "auto"

var _report: Rapport = Rapport.new()
var _chip: RefCounted = null
var _headless: bool = false
var _running: bool = false
var _kept_lines: Array[RefCounted] = []

var _log: RichTextLabel
var _summary: Label
var _run_button: Button
var _output_spin: SpinBox
var _input_spin: SpinBox
var _floating_spin: SpinBox
var _chip_edit: LineEdit


## Enregistre les fronts reçus d'une ligne (signal edge_detected).
func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	_parse_arguments()
	if not _headless:
		_build_ui()
	# Les broches de la configuration du projet ne doivent pas gêner le banc.
	Gpio.shutdown()
	if _headless:
		await _run_all()
		_finish_headless()


# --- Déroulement -------------------------------------------------------------------


func _run_all() -> void:
	_running = true
	_report.header = (
		"sortie GPIO %d -> entrée GPIO %d, flottante GPIO %d, puce %s"
		% [output_line, input_line, floating_line, chip_spec]
	)
	_report.reset()

	_report.begin("Environnement")
	_test_environment()
	var hardware: bool = _test_extension()
	if hardware:
		hardware = _test_chip()
	if hardware:
		_report.begin("Sortie -> entrée (fil)")
		await _test_loopback()
		_report.begin("Actif bas, valeur initiale, mode de sortie")
		await _test_output_modes()
		_report.begin("Résistances de tirage (broche flottante)")
		await _test_bias()
		_report.begin("Fronts")
		await _test_edges()
		_report.begin("Anti-rebond du noyau")
		await _test_debounce()
		_report.begin("Robustesse")
		await _test_robustness()
		_report.begin("Autoload Gpio sur le matériel")
		await _test_autoload()
		_report.begin("Erreurs attendues")
		_test_errors()
	else:
		_report.begin("Matériel")
		_add(
			Rapport.Status.IGNORE, "tests matériel", "pas de puce GPIO utilisable sur cette machine"
		)

	_report.finish()
	_running = false


func _finish_headless() -> void:
	# On quitte volontairement avec une entrée surveillée et une sortie réservées :
	# si la fermeture de Godot plantait, le code de sortie serait > 1.
	if _chip != null:
		var watched: RefCounted = _chip.call(
			&"request_input", input_line, BIAS_PULL_DOWN, 0, EDGE_BOTH, false, CONSUMER
		)
		var driven: RefCounted = _chip.call(
			&"request_output", output_line, false, false, DRIVE_PUSH_PULL, CONSUMER
		)
		if watched != null:
			_kept_lines.append(watched)
		if driven != null:
			_kept_lines.append(driven)
	get_tree().quit(1 if _report.count(Rapport.Status.KO) > 0 else 0)


# --- Environnement et puce ----------------------------------------------------------


func _test_environment() -> void:
	var version: Dictionary = Engine.get_version_info()
	_add(Rapport.Status.INFO, "Godot", "%s (%s)" % [version.get("string", "?"), _build_kind()])
	_add(Rapport.Status.INFO, "système", "%s %s" % [OS.get_name(), Engine.get_architecture_name()])
	if OS.get_name() != "Linux":
		return
	_add(Rapport.Status.INFO, "carte", Systeme.read_text("/proc/device-tree/model", "inconnue"))
	_add(Rapport.Status.INFO, "noyau", Systeme.read_text("/proc/sys/kernel/osrelease", "inconnu"))
	var groups: PackedStringArray = Systeme.user_groups()
	if groups.has("gpio"):
		_add(Rapport.Status.INFO, "groupe gpio", "l'utilisateur en fait partie")
	else:
		_add(
			Rapport.Status.INFO,
			"groupe gpio",
			"absent des groupes du processus (%s) : l'accès peut être refusé" % ", ".join(groups)
		)


func _test_extension() -> bool:
	var devices: PackedStringArray = Systeme.gpio_devices()
	var loaded: bool = ClassDB.class_exists(&"GpioChip")
	if not loaded:
		if devices.is_empty():
			_add(
				Rapport.Status.IGNORE,
				"GDExtension",
				"non chargée sur cette plateforme (normal hors Linux)"
			)
		else:
			_add(
				Rapport.Status.KO,
				"GDExtension",
				(
					"non chargée alors que %s existe : .so absent ou mauvaise architecture ?"
					% devices[0]
				)
			)
		return false
	_add(Rapport.Status.OK, "GDExtension", "chargée")
	var probe: RefCounted = ClassDB.instantiate(&"GpioChip")
	var supported: bool = probe.call(&"is_supported")
	_check(supported, "is_supported()", "true attendu sous Linux")
	if not supported:
		return false

	var chips: Array = probe.call(&"list_chips")
	if chips.is_empty():
		_add(Rapport.Status.IGNORE, "list_chips()", "aucune puce GPIO sur cette machine")
		return false
	var errors: int = 0
	for chip: Dictionary in chips:
		if chip.has("error"):
			errors += 1
			_add(Rapport.Status.KO, "puce %s" % chip.get("path", "?"), str(chip["error"]))
		else:
			_add(
				Rapport.Status.INFO,
				"puce %s" % chip.get("path", "?"),
				"label « %s », %d lignes" % [chip.get("label", ""), int(chip.get("lines", 0))]
			)
	_check(errors == 0, "list_chips()", "%d puce(s), %d inaccessible(s)" % [chips.size(), errors])
	return true


func _test_chip() -> bool:
	_report.begin("Puce GPIO")
	_chip = _open_chip(chip_spec)
	if _chip == null:
		return false
	var path: String = _chip.call(&"get_path")
	var label: String = _chip.call(&"get_label")
	var chip_name: String = _chip.call(&"get_name")
	var lines: int = _chip.call(&"get_line_count")
	_add(
		Rapport.Status.OK,
		"ouverture (%s)" % chip_spec,
		"%s, label « %s », %d lignes" % [path, label, lines]
	)

	# Les quatre façons de désigner une puce doivent mener au même fichier.
	var number: String = chip_name.trim_prefix("gpiochip")
	for spec: String in [label, chip_name, path, number]:
		var other: RefCounted = ClassDB.instantiate(&"GpioChip")
		var err: int = other.call(&"open", spec)
		_check(
			err == OK and str(other.call(&"get_path")) == path,
			"open(« %s »)" % spec,
			str(other.call(&"get_last_error")) if err != OK else path
		)
		other.call(&"close")
		_check(not bool(other.call(&"is_open")), "close() après open(« %s »)" % spec)

	for line: int in [output_line, input_line, floating_line]:
		if line < 0:
			continue
		if line >= lines:
			_add(Rapport.Status.KO, "ligne %d" % line, "hors limites (la puce a %d lignes)" % lines)
			return false
		var info: Dictionary = _chip.call(&"get_line_info", line)
		var line_name: String = info.get("name", "")
		var used: bool = info.get("used", false)
		_check(
			not used,
			"ligne %d (%s) libre" % [line, line_name],
			"utilisée par « %s »" % info.get("consumer", "") if used else "libre"
		)
		if used:
			return false
		if not line_name.is_empty():
			_check(
				int(_chip.call(&"find_line", line_name)) == line,
				"find_line(« %s »)" % line_name,
				"doit renvoyer %d" % line
			)
	return true


# --- Sortie -> entrée ---------------------------------------------------------------


func _test_loopback() -> void:
	var out: RefCounted = _request_output(output_line, false)
	var inp: RefCounted = _request_input(input_line, BIAS_PULL_DOWN, 0, EDGE_NONE)
	if out == null or inp == null:
		_release(out, inp)
		return
	await _wait_ms(5)
	var mismatches: int = 0
	var first_bad: String = ""
	for i: int in 40:
		var value: bool = i % 2 == 0
		out.call(&"set_value", value)
		var read: int = inp.call(&"get_value")
		if read != int(value):
			mismatches += 1
			if first_bad.is_empty():
				first_bad = "écrit %d, lu %d" % [int(value), read]
	_check(
		mismatches == 0,
		"40 écritures relues sur l'entrée",
		(
			(
				"%d erreur(s), %s : vérifier le fil GPIO %d -> GPIO %d"
				% [mismatches, first_bad, output_line, input_line]
			)
			if mismatches > 0
			else "toutes identiques"
		)
	)

	out.call(&"set_value", true)
	_check(int(out.call(&"get_value")) == 1, "relecture d'une sortie", "get_value() sur la sortie")

	var out_info: Dictionary = _chip.call(&"get_line_info", output_line)
	_check(
		out_info.get("used", false) and out_info.get("consumer", "") == CONSUMER,
		"infos de la sortie : réservée par « %s »" % CONSUMER,
		str(out_info)
	)
	_check(out_info.get("direction", "") == "output", "infos de la sortie : direction output")
	var in_info: Dictionary = _chip.call(&"get_line_info", input_line)
	_check(
		in_info.get("direction", "") == "input" and in_info.get("bias", "") == "pull_down",
		"infos de l'entrée : input, pull_down",
		str(in_info)
	)

	var err: int = inp.call(&"set_value", true)
	_check(
		err != OK and not str(inp.call(&"get_last_error")).is_empty(),
		"écrire une entrée est refusé",
		str(inp.call(&"get_last_error"))
	)

	_release(out, inp)
	_check(not bool(out.call(&"is_valid")), "release() invalide la ligne")
	_check(int(out.call(&"set_value", true)) != OK, "écrire une ligne libérée est refusé")
	_check(int(out.call(&"get_value")) == -1, "lire une ligne libérée renvoie -1")
	var after: Dictionary = _chip.call(&"get_line_info", output_line)
	_check(not after.get("used", true), "la sortie est libre après release()")


func _test_output_modes() -> void:
	var inp: RefCounted = _request_input(input_line, BIAS_PULL_DOWN, 0, EDGE_NONE)
	if inp == null:
		return
	for initial: bool in [true, false]:
		var out: RefCounted = _request_output(output_line, initial)
		if out != null:
			await _wait_ms(2)
			_check(
				int(inp.call(&"get_value")) == int(initial),
				"valeur initiale %d" % int(initial),
				"entrée lue : %d" % int(inp.call(&"get_value"))
			)
			out.call(&"release")

	# Sortie active à l'état bas : true logique = 0 V.
	var low: RefCounted = _request_output(output_line, false, true)
	if low != null:
		await _wait_ms(2)
		_check(int(inp.call(&"get_value")) == 1, "sortie actif bas, false -> 3,3 V")
		low.call(&"set_value", true)
		_check(int(inp.call(&"get_value")) == 0, "sortie actif bas, true -> 0 V")
		var info: Dictionary = _chip.call(&"get_line_info", output_line)
		_check(info.get("active_low", false), "infos de la sortie : active_low")
		low.call(&"release")
	inp.call(&"release")

	# Entrée active à l'état bas.
	var out2: RefCounted = _request_output(output_line, true)
	var inp_low: RefCounted = _request_input(input_line, BIAS_PULL_DOWN, 0, EDGE_NONE, true)
	if out2 != null and inp_low != null:
		await _wait_ms(2)
		_check(int(inp_low.call(&"get_value")) == 0, "entrée actif bas, 3,3 V -> 0 logique")
		out2.call(&"set_value", false)
		_check(int(inp_low.call(&"get_value")) == 1, "entrée actif bas, 0 V -> 1 logique")
	_release(out2, inp_low)

	# Drain ouvert : la sortie ne tire que vers 0 V, la résistance de l'entrée fait le 1.
	await _test_drive(DRIVE_OPEN_DRAIN, BIAS_PULL_UP, "drain ouvert + pull-up")
	# Source ouverte : la sortie ne tire que vers 3,3 V, la résistance de l'entrée fait le 0.
	await _test_drive(DRIVE_OPEN_SOURCE, BIAS_PULL_DOWN, "source ouverte + pull-down")


func _test_drive(drive: int, bias: int, label: String) -> void:
	var inp: RefCounted = _request_input(input_line, bias, 0, EDGE_NONE)
	var out: RefCounted = null
	if inp != null:
		out = _chip.call(&"request_output", output_line, false, false, drive, CONSUMER)
		if out == null:
			_add(Rapport.Status.KO, label, str(_chip.call(&"get_last_error")))
	if out != null:
		var ok: bool = true
		for value: bool in [true, false, true, false]:
			out.call(&"set_value", value)
			await _wait_ms(2)
			ok = ok and int(inp.call(&"get_value")) == int(value)
		_check(ok, label, "1 et 0 relus correctement" if ok else "valeurs relues incorrectes")
	_release(out, inp)


func _test_bias() -> void:
	if floating_line < 0:
		_add(Rapport.Status.IGNORE, "tirages", "pas de broche flottante (--flottante=-1)")
		return
	for bias: int in [BIAS_PULL_UP, BIAS_PULL_DOWN, BIAS_PULL_UP]:
		var expected: int = 1 if bias == BIAS_PULL_UP else 0
		var label: String = "pull_up" if bias == BIAS_PULL_UP else "pull_down"
		var inp: RefCounted = _request_input(floating_line, bias, 0, EDGE_NONE)
		if inp == null:
			return
		await _wait_ms(5)
		var value: int = inp.call(&"get_value")
		_check(
			value == expected,
			"GPIO %d en %s lit %d" % [floating_line, label, expected],
			(
				"lu %d : la broche flottante est-elle bien reliée à rien ?" % value
				if value != expected
				else "ok"
			)
		)
		var info: Dictionary = _chip.call(&"get_line_info", floating_line)
		_check(info.get("bias", "") == label, "infos de la ligne : bias %s" % label, str(info))
		inp.call(&"release")


# --- Fronts -------------------------------------------------------------------------


func _test_edges() -> void:
	var out: RefCounted = _request_output(output_line, false)
	var inp: RefCounted = _request_input(input_line, BIAS_PULL_DOWN, 0, EDGE_BOTH)
	if out == null or inp == null:
		_release(out, inp)
		return
	_check(bool(inp.call(&"has_edge_detection")), "has_edge_detection()")
	var edges := EdgeLog.new()
	inp.connect(&"edge_detected", edges.on_edge)
	await _wait_ms(50)
	edges.clear()

	var latencies: Array[int] = []
	var timeouts: int = 0
	for i: int in 20:
		var value: bool = i % 2 == 0
		var before: int = edges.count()
		var sent_us: int = Time.get_ticks_usec()
		out.call(&"set_value", value)
		if await _wait_until(func() -> bool: return edges.count() > before, 500):
			latencies.append(edges.received_us[before] - sent_us)
		else:
			timeouts += 1
		await _wait_ms(10)
	_check(
		edges.count() == 20 and timeouts == 0,
		"20 changements -> 20 fronts",
		"%d front(s) reçu(s), %d attente(s) sans front" % [edges.count(), timeouts]
	)
	var alternating: bool = edges.count() > 0
	for i: int in edges.count():
		alternating = alternating and edges.rising[i] == (i % 2 == 0)
	_check(alternating, "fronts montant / descendant dans l'ordre", str(edges.rising))
	var increasing: bool = true
	for i: int in range(1, edges.timestamps_ns.size()):
		increasing = increasing and edges.timestamps_ns[i] > edges.timestamps_ns[i - 1]
	_check(increasing, "horodatages du noyau croissants")
	if not latencies.is_empty():
		latencies.sort()
		var average: float = 0.0
		for latency: int in latencies:
			average += latency
		average /= latencies.size()
		_add(
			Rapport.Status.INFO,
			"latence écriture -> signal",
			(
				"min %.2f ms, moyenne %.2f ms, max %.2f ms (inclut l'attente de la frame suivante)"
				% [latencies[0] / 1000.0, average / 1000.0, latencies[-1] / 1000.0]
			)
		)
		_check(latencies[-1] < 100_000, "latence maximale < 100 ms", "%d µs" % latencies[-1])
	inp.call(&"release")

	await _test_edge_filter(out, EDGE_RISING, "fronts montants seulement", true)
	await _test_edge_filter(out, EDGE_FALLING, "fronts descendants seulement", false)
	await _test_edge_none(out)
	await _test_edge_active_low(out)
	out.call(&"release")


func _test_edge_filter(out: RefCounted, edge: int, label: String, rising: bool) -> void:
	out.call(&"set_value", false)
	var inp: RefCounted = _request_input(input_line, BIAS_PULL_DOWN, 0, edge)
	if inp == null:
		return
	var edges := EdgeLog.new()
	inp.connect(&"edge_detected", edges.on_edge)
	await _wait_ms(20)
	edges.clear()
	for i: int in 10:
		out.call(&"set_value", i % 2 == 0)
		await _wait_ms(10)
	await _wait_ms(50)
	_check(
		edges.count() == 5 and edges.count_of(rising) == 5,
		label,
		"%d front(s) reçu(s), 5 attendus" % edges.count()
	)
	var info: Dictionary = _chip.call(&"get_line_info", input_line)
	_check(
		info.get("edge", "") == ("rising" if rising else "falling"),
		"infos de la ligne : edge %s" % ("rising" if rising else "falling"),
		str(info.get("edge", "?"))
	)
	inp.call(&"release")


func _test_edge_none(out: RefCounted) -> void:
	var inp: RefCounted = _request_input(input_line, BIAS_PULL_DOWN, 0, EDGE_NONE)
	if inp == null:
		return
	var edges := EdgeLog.new()
	inp.connect(&"edge_detected", edges.on_edge)
	for i: int in 6:
		out.call(&"set_value", i % 2 == 0)
		await _wait_ms(5)
	await _wait_ms(50)
	_check(
		edges.count() == 0 and not bool(inp.call(&"has_edge_detection")),
		"EDGE_NONE : aucun front, aucun thread",
		"%d front(s) reçu(s)" % edges.count()
	)
	inp.call(&"release")


func _test_edge_active_low(out: RefCounted) -> void:
	out.call(&"set_value", false)
	var inp: RefCounted = _request_input(input_line, BIAS_PULL_DOWN, 0, EDGE_BOTH, true)
	if inp == null:
		return
	var edges := EdgeLog.new()
	inp.connect(&"edge_detected", edges.on_edge)
	await _wait_ms(20)
	edges.clear()
	out.call(&"set_value", true)
	await _wait_until(func() -> bool: return edges.count() > 0, 500)
	_check(
		edges.count() == 1 and edges.rising[0] == false,
		"actif bas : 0 V -> 3,3 V donne un front descendant",
		str(edges.rising)
	)
	inp.call(&"release")


# --- Anti-rebond --------------------------------------------------------------------


func _test_debounce() -> void:
	var out: RefCounted = _request_output(output_line, false)
	if out == null:
		return
	var debounce_us: int = 10_000
	var inp: RefCounted = _request_input(input_line, BIAS_PULL_DOWN, debounce_us, EDGE_BOTH)
	if inp == null:
		out.call(&"release")
		return
	var info: Dictionary = _chip.call(&"get_line_info", input_line)
	_check(
		int(info.get("debounce_us", 0)) == debounce_us,
		"infos de la ligne : debounce_us = %d" % debounce_us,
		str(info.get("debounce_us", "?"))
	)
	var edges := EdgeLog.new()
	inp.connect(&"edge_detected", edges.on_edge)
	await _wait_ms(50)
	edges.clear()

	# Rafale impaire (finit à 1) : un seul front, une fois la ligne stable.
	_burst(out, 21)
	await _wait_ms(100)
	_check(
		edges.count() == 1 and edges.count_of(true) == 1,
		"rafale de 21 changements en < 10 ms -> 1 front",
		"%d front(s) reçu(s) %s" % [edges.count(), edges.rising]
	)
	# Rafale paire (revient à 1) : aucun front.
	edges.clear()
	_burst(out, 20)
	await _wait_ms(100)
	_check(
		edges.count() == 0,
		"rafale de 20 changements revenant à l'état stable -> 0 front",
		"%d front(s) reçu(s)" % edges.count()
	)
	# Changements lents (30 ms > 10 ms) : tous passent.
	edges.clear()
	for i: int in 6:
		out.call(&"set_value", i % 2 == 1)
		await _wait_ms(30)
	await _wait_ms(50)
	_check(edges.count() == 6, "6 changements espacés de 30 ms -> 6 fronts", "%d" % edges.count())
	inp.call(&"release")

	# Sans anti-rebond, à titre d'information.
	out.call(&"set_value", false)
	var raw: RefCounted = _request_input(input_line, BIAS_PULL_DOWN, 0, EDGE_BOTH)
	if raw != null:
		var raw_edges := EdgeLog.new()
		raw.connect(&"edge_detected", raw_edges.on_edge)
		await _wait_ms(20)
		raw_edges.clear()
		_burst(out, 20)
		await _wait_ms(100)
		_add(
			Rapport.Status.INFO,
			"rafale de 20 changements sans anti-rebond",
			"%d front(s) reçu(s) (le noyau peut en fusionner)" % raw_edges.count()
		)
		raw.call(&"release")
	out.call(&"release")


func _burst(out: RefCounted, changes: int) -> void:
	var value: bool = int(out.call(&"get_value")) == 1
	for i: int in changes:
		value = not value
		out.call(&"set_value", value)


# --- Robustesse ---------------------------------------------------------------------


func _test_robustness() -> void:
	var fds_before: int = Systeme.count_entries("/proc/self/fd", false)
	var threads_before: int = Systeme.count_entries("/proc/self/task", true)

	var failures: int = 0
	var inp: RefCounted = null
	for i: int in 100:
		inp = _chip.call(
			&"request_input", input_line, BIAS_PULL_DOWN, 0, EDGE_BOTH, false, CONSUMER
		)
		if inp == null:
			failures += 1
		elif i % 2 == 0:
			inp.call(&"release")
		# Une fois sur deux, la ligne est simplement abandonnée : le destructeur la libère.
		# (La référence doit tomber avant la réservation suivante, sinon EBUSY.)
		inp = null
	_check(failures == 0, "100 réservations / libérations avec fronts", "%d échec(s)" % failures)
	await _frames(3)

	# Événements en attente au moment où la ligne disparaît : ne doit pas planter.
	var out: RefCounted = _request_output(output_line, false)
	var inp2: RefCounted = _request_input(input_line, BIAS_PULL_DOWN, 0, EDGE_BOTH)
	if out != null and inp2 != null:
		var edges := EdgeLog.new()
		inp2.connect(&"edge_detected", edges.on_edge)
		_burst(out, 50)
		inp2 = null
		await _frames(5)
		_add(Rapport.Status.OK, "ligne détruite avec des fronts en attente", "pas de plantage")
	_release(out, inp2)
	await _frames(3)

	var fds_after: int = Systeme.count_entries("/proc/self/fd", false)
	var threads_after: int = Systeme.count_entries("/proc/self/task", true)
	_check(
		fds_after - fds_before <= 2,
		"pas de fuite de descripteurs",
		"%d avant, %d après" % [fds_before, fds_after]
	)
	_check(
		threads_after - threads_before <= 2,
		"pas de fuite de threads",
		"%d avant, %d après" % [threads_before, threads_after]
	)
	for line: int in [output_line, input_line]:
		var info: Dictionary = _chip.call(&"get_line_info", line)
		_check(not info.get("used", true), "ligne %d libre à la fin" % line)


# --- Autoload Gpio ------------------------------------------------------------------


func _test_autoload() -> void:
	var config := GpioConfig.new()
	config.simulation = GpioConfig.SimulationMode.NEVER
	config.default_chip = chip_spec
	config.consumer = CONSUMER
	config.pins.append(_pin(&"banc_sortie", output_line, GpioPin.Direction.OUTPUT))
	var entree: GpioPin = _pin(&"banc_entree", input_line, GpioPin.Direction.INPUT)
	entree.bias = GpioPin.Bias.PULL_DOWN
	entree.debounce_ms = 0.0
	entree.action = &"banc_action"
	config.pins.append(entree)
	# Même ligne que la sortie : doit échouer seule, sans bloquer les autres.
	config.pins.append(_pin(&"banc_doublon", output_line, GpioPin.Direction.INPUT))

	var changes: Array[Array] = []
	var on_change := func(pin_name: StringName, value: bool) -> void:
		changes.append([pin_name, value, Time.get_ticks_msec()])
	Gpio.pin_changed.connect(on_change)
	Gpio.setup(config)

	_check(not Gpio.is_simulated(), "mode matériel")
	var doublon_error: String = Gpio.get_pin_error(&"banc_doublon")
	_check(
		doublon_error.contains("réservée"),
		"broche en double : erreur « déjà réservée », le reste continue",
		doublon_error
	)
	_check(
		(
			Gpio.get_pin_error(&"banc_sortie").is_empty()
			and Gpio.get_pin_error(&"banc_entree").is_empty()
		),
		"sortie et entrée ouvertes sans erreur",
		"%s / %s" % [Gpio.get_pin_error(&"banc_sortie"), Gpio.get_pin_error(&"banc_entree")]
	)

	changes.clear()
	Gpio.set_pin(&"banc_sortie", true)
	var got: bool = await _wait_until(
		func() -> bool: return _has_change(changes, &"banc_entree", true), 500
	)
	_check(got, "set_pin(sortie, true) -> pin_changed(entree, true)")
	_check(Input.is_action_pressed(&"banc_action"), "l'entrée presse l'action banc_action")
	_check(Gpio.get_pin(&"banc_entree"), "get_pin(entree) relit 1")
	Gpio.set_pin(&"banc_sortie", false)
	await _wait_until(func() -> bool: return not Input.is_action_pressed(&"banc_action"), 500)
	_check(not Input.is_action_pressed(&"banc_action"), "relâcher la sortie relâche l'action")

	changes.clear()
	Gpio.pulse(&"banc_sortie", 0.2)
	await _wait_ms(400)
	var on_ms: int = _first_change_ms(changes, &"banc_entree", true)
	var off_ms: int = _first_change_ms(changes, &"banc_entree", false)
	var duration: int = off_ms - on_ms
	_check(
		on_ms >= 0 and off_ms >= 0 and absi(duration - 200) <= 50,
		"pulse(0,2 s) vu sur l'entrée",
		"%d ms mesurées" % duration if on_ms >= 0 and off_ms >= 0 else "front manquant"
	)

	changes.clear()
	Gpio.blink(&"banc_sortie", 0.1, 5)
	await _wait_ms(800)
	var ons: int = 0
	for change: Array in changes:
		if change[0] == &"banc_entree" and change[1] == true:
			ons += 1
	_check(ons == 5, "blink(0,1 s, 5) -> 5 allumages vus sur l'entrée", "%d vus" % ons)

	Gpio.pin_changed.disconnect(on_change)
	Gpio.shutdown()
	var info: Dictionary = _chip.call(&"get_line_info", output_line)
	_check(not info.get("used", true), "shutdown() libère les lignes")


func _pin(pin_name: StringName, line: int, direction: GpioPin.Direction) -> GpioPin:
	var pin := GpioPin.new()
	pin.name = pin_name
	pin.line = line
	pin.direction = direction
	return pin


func _has_change(changes: Array[Array], pin_name: StringName, value: bool) -> bool:
	return _first_change_ms(changes, pin_name, value) >= 0


func _first_change_ms(changes: Array[Array], pin_name: StringName, value: bool) -> int:
	for change: Array in changes:
		if change[0] == pin_name and change[1] == value:
			return change[2]
	return -1


# --- Erreurs ------------------------------------------------------------------------


func _test_errors() -> void:
	var out: RefCounted = _request_output(output_line, false)
	if out != null:
		var twice: RefCounted = _chip.call(
			&"request_output", output_line, false, false, DRIVE_PUSH_PULL, CONSUMER
		)
		var message: String = _chip.call(&"get_last_error")
		_check(
			twice == null and message.contains("réservée"),
			"réserver deux fois la même ligne (EBUSY)",
			message
		)
		out.call(&"release")
	var lines: int = _chip.call(&"get_line_count")
	var beyond: RefCounted = _chip.call(
		&"request_input", lines + 10, BIAS_DISABLED, 0, EDGE_NONE, false, CONSUMER
	)
	var beyond_message: String = _chip.call(&"get_last_error")
	_check(
		beyond == null and not beyond_message.is_empty(),
		"ligne hors limites refusée",
		beyond_message
	)
	var info: Dictionary = _chip.call(&"get_line_info", lines + 10)
	_check(
		info.is_empty(),
		"get_line_info() hors limites renvoie {}",
		str(_chip.call(&"get_last_error"))
	)
	_check(int(_chip.call(&"find_line", "N_EXISTE_PAS")) == -1, "find_line() inconnue renvoie -1")
	var missing: RefCounted = ClassDB.instantiate(&"GpioChip")
	var err: int = missing.call(&"open", "pinctrl-n-existe-pas")
	_check(
		err != OK and str(missing.call(&"get_last_error")).contains("pinctrl-n-existe-pas"),
		"puce inexistante",
		str(missing.call(&"get_last_error"))
	)


# --- Outils GPIO --------------------------------------------------------------------


func _open_chip(spec: String) -> RefCounted:
	var candidates: Array[String] = []
	if spec == "auto" or spec.is_empty():
		candidates.assign(AUTO_CHIP_LABELS)
		candidates.append("0")
	else:
		candidates.append(spec)
	var last_error: String = ""
	for candidate: String in candidates:
		var chip: RefCounted = ClassDB.instantiate(&"GpioChip")
		if int(chip.call(&"open", candidate)) == OK:
			return chip
		last_error = chip.call(&"get_last_error")
	_add(Rapport.Status.KO, "ouverture de la puce (%s)" % spec, last_error)
	return null


func _request_output(line: int, initial: bool, active_low: bool = false) -> RefCounted:
	var out: RefCounted = _chip.call(
		&"request_output", line, initial, active_low, DRIVE_PUSH_PULL, CONSUMER
	)
	if out == null:
		_add(
			Rapport.Status.KO,
			"réservation de la sortie %d" % line,
			str(_chip.call(&"get_last_error"))
		)
	return out


func _request_input(
	line: int, bias: int, debounce_us: int, edges: int, active_low: bool = false
) -> RefCounted:
	var inp: RefCounted = _chip.call(
		&"request_input", line, bias, debounce_us, edges, active_low, CONSUMER
	)
	if inp == null:
		_add(
			Rapport.Status.KO,
			"réservation de l'entrée %d" % line,
			str(_chip.call(&"get_last_error"))
		)
	return inp


func _release(a: RefCounted, b: RefCounted) -> void:
	for line: RefCounted in [a, b]:
		if line != null:
			line.call(&"release")


# --- Outils système -----------------------------------------------------------------


func _build_kind() -> String:
	return "debug" if OS.is_debug_build() else "release"


func _wait_ms(ms: int) -> void:
	await get_tree().create_timer(ms / 1000.0, true, false, true).timeout


func _frames(count: int) -> void:
	for i: int in count:
		await get_tree().process_frame


func _wait_until(condition: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while not condition.call():
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().process_frame
	return true


# --- Résultats ----------------------------------------------------------------------


func _check(condition: bool, title: String, detail: String = "") -> void:
	_report.check(condition, title, detail)


func _add(status: Rapport.Status, title: String, detail: String = "") -> void:
	_report.add(status, title, detail)


# --- Paramètres et interface --------------------------------------------------------


func _parse_arguments() -> void:
	for argument: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = argument.trim_prefix("--").split("=", true, 1)
		if parts.size() != 2:
			continue
		match parts[0]:
			"sortie":
				output_line = parts[1].to_int()
			"entree", "entrée":
				input_line = parts[1].to_int()
			"flottante":
				floating_line = parts[1].to_int()
			"puce":
				chip_spec = parts[1]


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)
	var box := VBoxContainer.new()
	margin.add_child(box)

	var title := Label.new()
	title.text = "Test automatique du GPIO (fil entre la sortie et l'entrée)"
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)

	var row := HBoxContainer.new()
	box.add_child(row)
	_output_spin = _add_spin(row, "Sortie GPIO", output_line, 0)
	_input_spin = _add_spin(row, "Entrée GPIO", input_line, 0)
	_floating_spin = _add_spin(row, "Flottante GPIO (-1 : sans)", floating_line, -1)
	var chip_label := Label.new()
	chip_label.text = "Puce"
	row.add_child(chip_label)
	_chip_edit = LineEdit.new()
	_chip_edit.text = chip_spec
	_chip_edit.custom_minimum_size.x = 160
	row.add_child(_chip_edit)
	_run_button = Button.new()
	_run_button.text = "Lancer le test"
	_run_button.pressed.connect(_on_run_pressed)
	row.add_child(_run_button)
	var back := Button.new()
	back.text = "Menu"
	back.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://banc/banc.tscn"))
	row.add_child(back)

	_summary = Label.new()
	_report.summary = _summary
	_summary.text = (
		"Relier GPIO %d et GPIO %d par un fil, puis lancer le test." % [output_line, input_line]
	)
	box.add_child(_summary)
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_log)
	_report.output_log = _log


func _add_spin(row: HBoxContainer, text: String, value: int, minimum: int) -> SpinBox:
	var label := Label.new()
	label.text = text
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = 63
	spin.value = value
	row.add_child(spin)
	return spin


func _on_run_pressed() -> void:
	if _running:
		return
	output_line = int(_output_spin.value)
	input_line = int(_input_spin.value)
	floating_line = int(_floating_spin.value)
	chip_spec = _chip_edit.text.strip_edges()
	_run_button.disabled = true
	_chip = null
	await _run_all()
	_chip = null
	_run_button.disabled = false
