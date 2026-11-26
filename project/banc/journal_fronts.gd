extends RefCounted
## Enregistre les fronts reçus d'une ligne (signal edge_detected de GpioLine).

var rising: Array[bool] = []
var timestamps_ns: PackedInt64Array = []
var received_us: PackedInt64Array = []


func on_edge(is_rising: bool, timestamp_ns: int) -> void:
	rising.append(is_rising)
	timestamps_ns.append(timestamp_ns)
	received_us.append(Time.get_ticks_usec())


func count() -> int:
	return rising.size()


func clear() -> void:
	rising.clear()
	timestamps_ns.clear()
	received_us.clear()


func count_of(value: bool) -> int:
	return rising.count(value)
