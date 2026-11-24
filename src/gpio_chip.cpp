#include "gpio_chip.h"

#include "gpio_errors.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#ifdef __linux__
#include <dirent.h>
#include <fcntl.h>
#include <linux/gpio.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <string>
#include <vector>
#endif

using namespace godot;

#ifdef __linux__
namespace {

struct ChipEntry {
	std::string path;
	std::string name;
	std::string label;
	int lines = 0;
	int open_errno = 0; // 0 si la puce a pu être interrogée.
};

String to_godot(const char *p_text) {
	return String::utf8(p_text);
}

// Ouvre /dev/<p_path> et lit gpiochip_info. Renvoie le fd ouvert, ou -1 (errno conservé).
int open_chip(const std::string &p_path, struct gpiochip_info &r_info) {
	const int fd = ::open(p_path.c_str(), O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		return -1;
	}
	memset(&r_info, 0, sizeof(r_info));
	if (ioctl(fd, GPIO_GET_CHIPINFO_IOCTL, &r_info) < 0) {
		const int saved = errno;
		::close(fd);
		errno = saved;
		return -1;
	}
	return fd;
}

// Énumère /dev/gpiochip*, triées par numéro.
std::vector<ChipEntry> scan_chips() {
	std::vector<ChipEntry> chips;
	DIR *dir = opendir("/dev");
	if (dir == nullptr) {
		return chips;
	}
	while (struct dirent *entry = readdir(dir)) {
		if (strncmp(entry->d_name, "gpiochip", 8) != 0) {
			continue;
		}
		ChipEntry chip;
		chip.path = std::string("/dev/") + entry->d_name;
		chip.name = entry->d_name;
		struct gpiochip_info info;
		const int fd = open_chip(chip.path, info);
		if (fd < 0) {
			chip.open_errno = errno;
		} else {
			chip.name = info.name;
			chip.label = info.label;
			chip.lines = static_cast<int>(info.lines);
			::close(fd);
		}
		chips.push_back(chip);
	}
	closedir(dir);
	std::sort(chips.begin(), chips.end(), [](const ChipEntry &a, const ChipEntry &b) {
		const int na = atoi(a.path.c_str() + strlen("/dev/gpiochip"));
		const int nb = atoi(b.path.c_str() + strlen("/dev/gpiochip"));
		return na < nb;
	});
	return chips;
}

String describe_available(const std::vector<ChipEntry> &p_chips) {
	if (p_chips.empty()) {
		return "aucune puce /dev/gpiochip* sur cette machine";
	}
	PackedStringArray parts;
	for (const ChipEntry &chip : p_chips) {
		String text = to_godot(chip.path.c_str());
		if (chip.open_errno != 0) {
			text += " (inaccessible)";
		} else {
			text += " = " + to_godot(chip.label.c_str());
		}
		parts.push_back(text);
	}
	return "puces disponibles : " + String(", ").join(parts);
}

} // namespace
#endif

void GpioChip::_bind_methods() {
	ClassDB::bind_static_method("GpioChip", D_METHOD("is_supported"), &GpioChip::is_supported);
	ClassDB::bind_static_method("GpioChip", D_METHOD("list_chips"), &GpioChip::list_chips);

	ClassDB::bind_method(D_METHOD("open", "chip"), &GpioChip::open);
	ClassDB::bind_method(D_METHOD("close"), &GpioChip::close);
	ClassDB::bind_method(D_METHOD("is_open"), &GpioChip::is_open);
	ClassDB::bind_method(D_METHOD("get_path"), &GpioChip::get_path);
	ClassDB::bind_method(D_METHOD("get_name"), &GpioChip::get_name);
	ClassDB::bind_method(D_METHOD("get_label"), &GpioChip::get_label);
	ClassDB::bind_method(D_METHOD("get_line_count"), &GpioChip::get_line_count);
	ClassDB::bind_method(D_METHOD("get_last_error"), &GpioChip::get_last_error);
	ClassDB::bind_method(D_METHOD("get_line_info", "offset"), &GpioChip::get_line_info);
	ClassDB::bind_method(D_METHOD("find_line", "line_name"), &GpioChip::find_line);

	ClassDB::bind_method(
			D_METHOD("request_input", "offset", "bias", "debounce_us", "edges", "active_low", "consumer"),
			&GpioChip::request_input, DEFVAL(BIAS_AS_IS), DEFVAL(0), DEFVAL(EDGE_BOTH), DEFVAL(false),
			DEFVAL("godot"));
	ClassDB::bind_method(D_METHOD("request_output", "offset", "initial_value", "active_low", "drive", "consumer"),
			&GpioChip::request_output, DEFVAL(false), DEFVAL(false), DEFVAL(DRIVE_PUSH_PULL), DEFVAL("godot"));

	BIND_ENUM_CONSTANT(BIAS_AS_IS);
	BIND_ENUM_CONSTANT(BIAS_DISABLED);
	BIND_ENUM_CONSTANT(BIAS_PULL_UP);
	BIND_ENUM_CONSTANT(BIAS_PULL_DOWN);

	BIND_ENUM_CONSTANT(EDGE_NONE);
	BIND_ENUM_CONSTANT(EDGE_RISING);
	BIND_ENUM_CONSTANT(EDGE_FALLING);
	BIND_ENUM_CONSTANT(EDGE_BOTH);

	BIND_ENUM_CONSTANT(DRIVE_PUSH_PULL);
	BIND_ENUM_CONSTANT(DRIVE_OPEN_DRAIN);
	BIND_ENUM_CONSTANT(DRIVE_OPEN_SOURCE);
}

bool GpioChip::is_supported() {
#ifdef __linux__
	return true;
#else
	return false;
#endif
}

TypedArray<Dictionary> GpioChip::list_chips() {
	TypedArray<Dictionary> result;
#ifdef __linux__
	for (const ChipEntry &chip : scan_chips()) {
		Dictionary entry;
		entry["path"] = to_godot(chip.path.c_str());
		entry["name"] = to_godot(chip.name.c_str());
		entry["label"] = to_godot(chip.label.c_str());
		entry["lines"] = chip.lines;
		if (chip.open_errno != 0) {
			entry["error"] = gpio_errno_message("ouverture de " + to_godot(chip.path.c_str()), chip.open_errno);
		}
		result.push_back(entry);
	}
#endif
	return result;
}

Error GpioChip::open(const String &p_chip) {
	close();
	last_error = String();

#ifdef __linux__
	const String wanted = p_chip.strip_edges();
	if (wanted.is_empty()) {
		last_error = gpio_u8("aucune puce GPIO indiquée");
		return ERR_INVALID_PARAMETER;
	}

	std::string target_path;
	int access_errno = 0;
	const std::vector<ChipEntry> chips = scan_chips();

	if (wanted.begins_with("/")) {
		target_path = wanted.utf8().get_data();
	} else {
		// 1. Par label ou par nom.
		const std::string wanted_std = wanted.utf8().get_data();
		for (const ChipEntry &chip : chips) {
			if (chip.open_errno != 0) {
				access_errno = chip.open_errno;
				continue;
			}
			if (chip.label == wanted_std || chip.name == wanted_std) {
				target_path = chip.path;
				break;
			}
		}
		// 2. Repli sur le numéro.
		if (target_path.empty() && wanted.is_valid_int()) {
			target_path = std::string("/dev/gpiochip") + wanted.utf8().get_data();
		}
	}

	if (target_path.empty()) {
		last_error = gpio_u8("puce GPIO « ") + wanted + gpio_u8(" » introuvable (") + describe_available(chips) + ")";
		if (access_errno != 0) {
			last_error += ". Certaines puces sont inaccessibles : " +
					gpio_errno_message("ouverture", access_errno);
			return ERR_FILE_NO_PERMISSION;
		}
		return ERR_DOES_NOT_EXIST;
	}

	struct gpiochip_info info;
	const int fd = open_chip(target_path, info);
	if (fd < 0) {
		const int err = errno;
		last_error = gpio_errno_message("ouverture de " + to_godot(target_path.c_str()), err);
		if (err == ENOENT) {
			last_error += " (" + describe_available(chips) + ")";
			return ERR_DOES_NOT_EXIST;
		}
		return (err == EACCES || err == EPERM) ? ERR_FILE_NO_PERMISSION : ERR_CANT_OPEN;
	}

	chip_fd = fd;
	path = to_godot(target_path.c_str());
	name = to_godot(info.name);
	label = to_godot(info.label);
	line_count = static_cast<int>(info.lines);
	return OK;
#else
	(void)p_chip;
	last_error = gpio_unsupported_message();
	return ERR_UNAVAILABLE;
#endif
}

void GpioChip::close() {
#ifdef __linux__
	if (chip_fd >= 0) {
		::close(chip_fd);
	}
#endif
	chip_fd = -1;
	path = String();
	name = String();
	label = String();
	line_count = 0;
}

bool GpioChip::is_open() const {
	return chip_fd >= 0;
}

String GpioChip::get_path() const {
	return path;
}

String GpioChip::get_name() const {
	return name;
}

String GpioChip::get_label() const {
	return label;
}

int GpioChip::get_line_count() const {
	return line_count;
}

String GpioChip::get_last_error() const {
	return last_error;
}

Dictionary GpioChip::get_line_info(int p_offset) {
	Dictionary result;
#ifdef __linux__
	if (chip_fd < 0) {
		last_error = "puce non ouverte";
		return result;
	}
	if (p_offset < 0 || p_offset >= line_count) {
		last_error = "ligne " + itos(p_offset) + gpio_u8(" hors limites (0 à ") + itos(line_count - 1) + ")";
		return result;
	}
	struct gpio_v2_line_info info;
	memset(&info, 0, sizeof(info));
	info.offset = static_cast<uint32_t>(p_offset);
	if (ioctl(chip_fd, GPIO_V2_GET_LINEINFO_IOCTL, &info) < 0) {
		last_error = gpio_errno_message("lecture des informations de la ligne " + itos(p_offset), errno);
		return result;
	}
	const uint64_t flags = info.flags;
	result["offset"] = p_offset;
	result["name"] = to_godot(info.name);
	result["consumer"] = to_godot(info.consumer);
	result["used"] = (flags & GPIO_V2_LINE_FLAG_USED) != 0;
	result["direction"] = (flags & GPIO_V2_LINE_FLAG_OUTPUT) ? "output" : "input";
	result["active_low"] = (flags & GPIO_V2_LINE_FLAG_ACTIVE_LOW) != 0;
	if (flags & GPIO_V2_LINE_FLAG_BIAS_PULL_UP) {
		result["bias"] = "pull_up";
	} else if (flags & GPIO_V2_LINE_FLAG_BIAS_PULL_DOWN) {
		result["bias"] = "pull_down";
	} else if (flags & GPIO_V2_LINE_FLAG_BIAS_DISABLED) {
		result["bias"] = "disabled";
	} else {
		result["bias"] = "unknown";
	}
	const bool rising = (flags & GPIO_V2_LINE_FLAG_EDGE_RISING) != 0;
	const bool falling = (flags & GPIO_V2_LINE_FLAG_EDGE_FALLING) != 0;
	result["edge"] = rising && falling ? "both" : (rising ? "rising" : (falling ? "falling" : "none"));
	int debounce_us = 0;
	for (uint32_t i = 0; i < info.num_attrs && i < GPIO_V2_LINE_NUM_ATTRS_MAX; i++) {
		if (info.attrs[i].id == GPIO_V2_LINE_ATTR_ID_DEBOUNCE) {
			debounce_us = static_cast<int>(info.attrs[i].debounce_period_us);
		}
	}
	result["debounce_us"] = debounce_us;
#else
	(void)p_offset;
	last_error = gpio_unsupported_message();
#endif
	return result;
}

int GpioChip::find_line(const String &p_line_name) {
#ifdef __linux__
	for (int offset = 0; offset < line_count; offset++) {
		const Dictionary info = get_line_info(offset);
		if (!info.is_empty() && String(info["name"]) == p_line_name) {
			return offset;
		}
	}
#else
	(void)p_line_name;
#endif
	return -1;
}

String GpioChip::_describe_line_user(int p_offset) {
	const Dictionary info = get_line_info(p_offset);
	if (info.is_empty()) {
		return String();
	}
	const String consumer = info["consumer"];
	return consumer.is_empty() ? String() : gpio_u8(" (utilisée par « ") + consumer + gpio_u8(" »)");
}

Ref<GpioLine> GpioChip::_request(int p_offset, uint64_t p_flags, int p_debounce_us, bool p_has_output_value,
		bool p_output_value, const String &p_consumer, bool p_edges, bool p_active_low) {
	Ref<GpioLine> line;
#ifdef __linux__
	if (chip_fd < 0) {
		last_error = "puce non ouverte (appelez open() d'abord)";
		return line;
	}
	if (p_offset < 0 || p_offset >= line_count) {
		last_error = "ligne " + itos(p_offset) + " hors limites pour " + label + gpio_u8(" (0 à ") + itos(line_count - 1) + ")";
		return line;
	}

	struct gpio_v2_line_request request;
	memset(&request, 0, sizeof(request));
	request.offsets[0] = static_cast<uint32_t>(p_offset);
	request.num_lines = 1;
	const CharString consumer = p_consumer.utf8();
	strncpy(request.consumer, consumer.get_data(), GPIO_MAX_NAME_SIZE - 1);
	request.config.flags = p_flags;

	uint32_t attr_count = 0;
	if (p_has_output_value) {
		struct gpio_v2_line_config_attribute &attr = request.config.attrs[attr_count++];
		attr.attr.id = GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES;
		attr.attr.values = p_output_value ? 1 : 0;
		attr.mask = 1;
	}
	if (p_debounce_us > 0) {
		struct gpio_v2_line_config_attribute &attr = request.config.attrs[attr_count++];
		attr.attr.id = GPIO_V2_LINE_ATTR_ID_DEBOUNCE;
		attr.attr.debounce_period_us = static_cast<uint32_t>(p_debounce_us);
		attr.mask = 1;
	}
	request.config.num_attrs = attr_count;

	if (ioctl(chip_fd, GPIO_V2_GET_LINE_IOCTL, &request) < 0) {
		const int err = errno;
		last_error = gpio_errno_message(gpio_u8("réservation de la ligne ") + itos(p_offset) + " de " + label, err);
		if (err == EBUSY) {
			last_error += _describe_line_user(p_offset);
		}
		return line;
	}

	line.instantiate();
	const GpioLine::Direction direction =
			(p_flags & GPIO_V2_LINE_FLAG_OUTPUT) ? GpioLine::DIRECTION_OUTPUT : GpioLine::DIRECTION_INPUT;
	if (line->setup(request.fd, p_offset, direction, p_edges, p_active_low, label) != OK) {
		last_error = line->get_last_error();
		line->release();
		return Ref<GpioLine>();
	}
	last_error = String();
#else
	(void)p_offset;
	(void)p_flags;
	(void)p_debounce_us;
	(void)p_has_output_value;
	(void)p_output_value;
	(void)p_consumer;
	(void)p_edges;
	(void)p_active_low;
	last_error = gpio_unsupported_message();
#endif
	return line;
}

Ref<GpioLine> GpioChip::request_input(int p_offset, Bias p_bias, int p_debounce_us, Edge p_edges, bool p_active_low,
		const String &p_consumer) {
#ifdef __linux__
	uint64_t flags = GPIO_V2_LINE_FLAG_INPUT;
	switch (p_bias) {
		case BIAS_DISABLED:
			flags |= GPIO_V2_LINE_FLAG_BIAS_DISABLED;
			break;
		case BIAS_PULL_UP:
			flags |= GPIO_V2_LINE_FLAG_BIAS_PULL_UP;
			break;
		case BIAS_PULL_DOWN:
			flags |= GPIO_V2_LINE_FLAG_BIAS_PULL_DOWN;
			break;
		default:
			break;
	}
	if (p_edges == EDGE_RISING || p_edges == EDGE_BOTH) {
		flags |= GPIO_V2_LINE_FLAG_EDGE_RISING;
	}
	if (p_edges == EDGE_FALLING || p_edges == EDGE_BOTH) {
		flags |= GPIO_V2_LINE_FLAG_EDGE_FALLING;
	}
	if (p_active_low) {
		flags |= GPIO_V2_LINE_FLAG_ACTIVE_LOW;
	}
	return _request(p_offset, flags, p_debounce_us, false, false, p_consumer, p_edges != EDGE_NONE, p_active_low);
#else
	(void)p_bias;
	(void)p_edges;
	return _request(p_offset, 0, p_debounce_us, false, false, p_consumer, false, p_active_low);
#endif
}

Ref<GpioLine> GpioChip::request_output(int p_offset, bool p_initial_value, bool p_active_low, Drive p_drive,
		const String &p_consumer) {
#ifdef __linux__
	uint64_t flags = GPIO_V2_LINE_FLAG_OUTPUT;
	if (p_drive == DRIVE_OPEN_DRAIN) {
		flags |= GPIO_V2_LINE_FLAG_OPEN_DRAIN;
	} else if (p_drive == DRIVE_OPEN_SOURCE) {
		flags |= GPIO_V2_LINE_FLAG_OPEN_SOURCE;
	}
	if (p_active_low) {
		flags |= GPIO_V2_LINE_FLAG_ACTIVE_LOW;
	}
	return _request(p_offset, flags, 0, true, p_initial_value, p_consumer, false, p_active_low);
#else
	(void)p_drive;
	return _request(p_offset, 0, 0, true, p_initial_value, p_consumer, false, p_active_low);
#endif
}

GpioChip::~GpioChip() {
	close();
}
