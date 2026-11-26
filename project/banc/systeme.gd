extends RefCounted
## Lectures système (Linux) pour le banc : périphériques, groupes, descripteurs.


static func gpio_devices() -> PackedStringArray:
	var found: PackedStringArray = []
	if OS.get_name() != "Linux":
		return found
	for file: String in DirAccess.get_files_at("/dev"):
		if file.begins_with("gpiochip"):
			found.append("/dev/" + file)
	return found


static func read_text(path: String, fallback: String) -> String:
	# Les fichiers de /proc annoncent une taille nulle : on lit par blocs jusqu'à la fin.
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return fallback
	var bytes := PackedByteArray()
	while bytes.size() < 1_000_000:
		var chunk: PackedByteArray = file.get_buffer(4096)
		if chunk.is_empty():
			break
		bytes.append_array(chunk)
	# Le device tree termine ses chaînes par un octet nul.
	var end: int = bytes.find(0)
	if end >= 0:
		bytes = bytes.slice(0, end)
	var text: String = bytes.get_string_from_utf8().strip_edges()
	return text if not text.is_empty() else fallback


static func user_groups() -> PackedStringArray:
	var ids: PackedStringArray = []
	for line: String in read_text("/proc/self/status", "").split("\n"):
		if line.begins_with("Groups:"):
			ids = line.trim_prefix("Groups:").strip_edges().split(" ", false)
	var names: PackedStringArray = []
	for entry: String in read_text("/etc/group", "").split("\n"):
		var fields: PackedStringArray = entry.split(":")
		if fields.size() >= 3 and ids.has(fields[2]):
			names.append(fields[0])
	return names


static func count_entries(path: String, directories: bool) -> int:
	if OS.get_name() != "Linux":
		return 0
	if directories:
		return DirAccess.get_directories_at(path).size()
	return DirAccess.get_files_at(path).size()
