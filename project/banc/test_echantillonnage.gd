extends RefCounted
## Tests de l'anti-rebond par échantillonnage (GpioChip.request_input_sampled),
## sur le fil sortie -> entrée du banc. Appelé par test_materiel.gd.
##
## Le dernier test reproduit le cas des câbles longs : des impulsions parasites
## très brèves pendant un relâchement. L'anti-rebond du noyau ne valide le
## relâchement qu'à la fin des parasites ; l'échantillonnage le valide aussitôt.

const EdgeLog := preload("res://banc/journal_fronts.gd")
const Rapport := preload("res://banc/rapport.gd")

const BIAS_PULL_DOWN := 3
const EDGE_BOTH := 3
const DEBOUNCE_US := 10_000
const GLITCH_MS := 300
const CONSUMER := "banc-gpio"

var _bench: Node


func _init(bench: Node) -> void:
	_bench = bench


func run() -> void:
	var out: RefCounted = _bench._request_output(_bench.output_line, false)
	if out == null:
		return
	var inp: RefCounted = _request_sampled()
	if inp == null:
		out.call(&"release")
		return
	_bench._check(bool(inp.call(&"is_sampled")), "is_sampled() vaut true")
	var info: Dictionary = _bench._chip.call(&"get_line_info", _bench.input_line)
	_bench._check(
		str(info.get("edge", "")) == "none" and int(info.get("debounce_us", -1)) == 0,
		"le noyau ne surveille pas les fronts (ni anti-rebond noyau)",
		"edge=%s debounce_us=%s" % [info.get("edge", "?"), info.get("debounce_us", "?")]
	)
	_bench._check(int(inp.call(&"get_value")) == 0, "valeur initiale lue : 0")

	var edges := EdgeLog.new()
	inp.connect(&"edge_detected", edges.on_edge)
	await _bench._wait_ms(50)
	edges.clear()

	var start_us: int = Time.get_ticks_usec()
	out.call(&"set_value", true)
	var delay_ms: float = _wait_value(inp, 1, 200)
	_bench._check(
		delay_ms >= 0.0 and edges.count_of(true) <= 1,
		"changement franc validé après l'anti-rebond (10 ms)",
		"%.1f ms" % delay_ms
	)
	await _bench._wait_ms(30)
	_bench._check(
		edges.count() == 1 and edges.count_of(true) == 1,
		"un seul front montant émis",
		"%d front(s) %s" % [edges.count(), edges.rising]
	)
	if delay_ms >= 0.0:
		_bench._check(
			delay_ms >= 8.0 and delay_ms <= 40.0,
			"délai de validation proche de 10 ms",
			"%.1f ms (depuis %d µs)" % [delay_ms, start_us]
		)

	edges.clear()
	_bench._burst(out, 21)
	await _bench._wait_ms(100)
	_bench._check(
		edges.count() == 1 and edges.count_of(false) == 1,
		"rafale de 21 changements -> 1 front",
		"%d front(s) %s" % [edges.count(), edges.rising]
	)
	edges.clear()
	_bench._burst(out, 20)
	await _bench._wait_ms(100)
	_bench._check(edges.count() == 0, "rafale de 20 changements -> 0 front", "%d" % edges.count())

	out.call(&"set_value", false)
	await _bench._wait_ms(50)
	edges.clear()
	_glitches(out, false, GLITCH_MS)
	await _bench._wait_ms(50)
	_bench._check(
		edges.count() == 0 and int(inp.call(&"get_value")) == 0,
		"impulsions parasites (%d ms) sur une ligne au repos -> ignorées" % GLITCH_MS,
		"%d front(s)" % edges.count()
	)
	inp.call(&"release")

	await _compare_release(out)
	out.call(&"release")


## Relâchement pendant une rafale de parasites : échantillonnage contre noyau.
func _compare_release(out: RefCounted) -> void:
	var sampled_ms: float = await _release_delay(out, _request_sampled())
	_bench._check(
		sampled_ms >= 0.0 and sampled_ms < 80.0,
		"échantillonnage : relâchement validé malgré %d ms de parasites" % GLITCH_MS,
		"%.1f ms" % sampled_ms
	)
	var kernel: RefCounted = _bench._request_input(
		_bench.input_line, BIAS_PULL_DOWN, DEBOUNCE_US, EDGE_BOTH
	)
	var kernel_ms: float = await _release_delay(out, kernel)
	_bench._add(
		Rapport.Status.INFO,
		"anti-rebond du noyau, même situation",
		"relâchement validé après %.1f ms (attendu : après la fin des parasites)" % kernel_ms
	)


## Appui, puis relâchement noyé dans des impulsions parasites. Renvoie le délai
## (ms) entre le relâchement et sa validation, -1 si jamais validé.
func _release_delay(out: RefCounted, inp: RefCounted) -> float:
	if inp == null:
		return -1.0
	out.call(&"set_value", true)
	_wait_value(inp, 1, 200)
	var released_us: int = Time.get_ticks_usec()
	var seen_us: int = _glitches(out, false, GLITCH_MS, inp)
	if seen_us < 0:
		var after: float = _wait_value(inp, 0, 500)
		seen_us = -1 if after < 0.0 else Time.get_ticks_usec()
	inp.call(&"release")
	out.call(&"set_value", false)
	await _bench._wait_ms(30)
	return -1.0 if seen_us < 0 else (seen_us - released_us) / 1000.0


## Maintient la sortie à [param level] en y ajoutant des impulsions de quelques
## microsecondes toutes les 0,5 ms. Si [param watch] est donné, renvoie l'instant
## (µs) où sa valeur validée passe à [param level], sinon -1.
func _glitches(out: RefCounted, level: bool, duration_ms: int, watch: RefCounted = null) -> int:
	var seen_us: int = -1
	var end_us: int = Time.get_ticks_usec() + duration_ms * 1000
	out.call(&"set_value", level)
	while Time.get_ticks_usec() < end_us:
		out.call(&"set_value", not level)
		out.call(&"set_value", level)
		if watch != null and seen_us < 0 and int(watch.call(&"get_value")) == int(level):
			seen_us = Time.get_ticks_usec()
		OS.delay_usec(500)
	return seen_us


func _wait_value(inp: RefCounted, value: int, timeout_ms: int) -> float:
	var start_us: int = Time.get_ticks_usec()
	var deadline_us: int = start_us + timeout_ms * 1000
	while Time.get_ticks_usec() < deadline_us:
		if int(inp.call(&"get_value")) == value:
			return (Time.get_ticks_usec() - start_us) / 1000.0
		OS.delay_usec(200)
	return -1.0


func _request_sampled() -> RefCounted:
	var inp: RefCounted = _bench._chip.call(
		&"request_input_sampled", _bench.input_line, BIAS_PULL_DOWN, DEBOUNCE_US, false, CONSUMER
	)
	if inp == null:
		_bench._add(
			Rapport.Status.KO,
			"request_input_sampled() sur la ligne %d" % _bench.input_line,
			str(_bench._chip.call(&"get_last_error"))
		)
	return inp
