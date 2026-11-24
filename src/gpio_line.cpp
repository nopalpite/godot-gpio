#include "gpio_line.h"

#include "gpio_errors.h"

#include <godot_cpp/core/class_db.hpp>

#ifdef __linux__
#include <linux/gpio.h>
#include <poll.h>
#include <sys/eventfd.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#endif

using namespace godot;

void GpioLine::_bind_methods() {
	ClassDB::bind_method(D_METHOD("is_valid"), &GpioLine::is_valid);
	ClassDB::bind_method(D_METHOD("get_offset"), &GpioLine::get_offset);
	ClassDB::bind_method(D_METHOD("get_direction"), &GpioLine::get_direction);
	ClassDB::bind_method(D_METHOD("is_active_low"), &GpioLine::is_active_low);
	ClassDB::bind_method(D_METHOD("has_edge_detection"), &GpioLine::has_edge_detection);
	ClassDB::bind_method(D_METHOD("get_chip_label"), &GpioLine::get_chip_label);
	ClassDB::bind_method(D_METHOD("get_last_error"), &GpioLine::get_last_error);
	ClassDB::bind_method(D_METHOD("get_value"), &GpioLine::get_value);
	ClassDB::bind_method(D_METHOD("set_value", "value"), &GpioLine::set_value);
	ClassDB::bind_method(D_METHOD("release"), &GpioLine::release);
	// Méthode interne : appelée en différé depuis le thread des fronts.
	ClassDB::bind_method(D_METHOD("_emit_edge", "rising", "timestamp_ns"), &GpioLine::_emit_edge);

	// Émis sur le thread principal. « rising » est un front logique : avec
	// l'actif bas, un appui sur un bouton câblé vers la masse donne rising = true.
	ADD_SIGNAL(MethodInfo("edge_detected", PropertyInfo(Variant::BOOL, "rising"),
			PropertyInfo(Variant::INT, "timestamp_ns")));
	// Émis (sur le thread principal) si la surveillance des fronts s'arrête sur une erreur.
	ADD_SIGNAL(MethodInfo("line_error", PropertyInfo(Variant::STRING, "message")));

	BIND_ENUM_CONSTANT(DIRECTION_INPUT);
	BIND_ENUM_CONSTANT(DIRECTION_OUTPUT);
}

Error GpioLine::setup(int p_line_fd, int p_offset, Direction p_direction, bool p_edges, bool p_active_low,
		const String &p_chip_label) {
	line_fd = p_line_fd;
	offset = p_offset;
	direction = p_direction;
	edges_enabled = p_edges;
	active_low = p_active_low;
	chip_label = p_chip_label;
	last_error = String();

#ifdef __linux__
	if (!edges_enabled) {
		return OK;
	}
	wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
	if (wake_fd < 0) {
		last_error = gpio_errno_message(gpio_u8("création de l'eventfd du thread des fronts"), errno);
		edges_enabled = false;
		return ERR_CANT_CREATE;
	}
	running.store(true);
	edge_thread = std::thread(&GpioLine::_edge_loop, this);
	return OK;
#else
	return OK;
#endif
}

void GpioLine::_edge_loop() {
#ifdef __linux__
	struct pollfd fds[2];
	fds[0].fd = line_fd;
	fds[0].events = POLLIN | POLLPRI;
	fds[1].fd = wake_fd;
	fds[1].events = POLLIN;

	struct gpio_v2_line_event events[16];

	while (running.load()) {
		fds[0].revents = 0;
		fds[1].revents = 0;
		const int ready = poll(fds, 2, -1);
		if (ready < 0) {
			if (errno == EINTR) {
				continue;
			}
			call_deferred("emit_signal", "line_error", gpio_errno_message("poll sur la ligne", errno));
			break;
		}
		if (fds[1].revents != 0 || !running.load()) {
			break; // Demande d'arrêt.
		}
		if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) {
			call_deferred("emit_signal", "line_error", String(gpio_u8("la ligne GPIO ne répond plus (descripteur fermé ?)")));
			break;
		}
		if ((fds[0].revents & (POLLIN | POLLPRI)) == 0) {
			continue;
		}
		const ssize_t bytes = read(line_fd, events, sizeof(events));
		if (bytes < 0) {
			if (errno == EINTR || errno == EAGAIN) {
				continue;
			}
			call_deferred("emit_signal", "line_error", gpio_errno_message("lecture des fronts", errno));
			break;
		}
		const size_t count = static_cast<size_t>(bytes) / sizeof(events[0]);
		for (size_t i = 0; i < count; i++) {
			const bool rising = events[i].id == GPIO_V2_LINE_EVENT_RISING_EDGE;
			call_deferred("_emit_edge", rising, static_cast<int64_t>(events[i].timestamp_ns));
		}
	}
#endif
}

void GpioLine::_emit_edge(bool p_rising, int64_t p_timestamp_ns) {
	if (line_fd < 0) {
		return; // Ligne libérée entre-temps : on ignore l'événement en attente.
	}
	emit_signal("edge_detected", p_rising, p_timestamp_ns);
}

void GpioLine::_stop_thread() {
#ifdef __linux__
	if (edge_thread.joinable()) {
		running.store(false);
		if (wake_fd >= 0) {
			const uint64_t one = 1;
			ssize_t ignored = write(wake_fd, &one, sizeof(one));
			(void)ignored;
		}
		edge_thread.join();
	}
	if (wake_fd >= 0) {
		close(wake_fd);
		wake_fd = -1;
	}
#endif
}

bool GpioLine::is_valid() const {
	return line_fd >= 0;
}

int GpioLine::get_offset() const {
	return offset;
}

GpioLine::Direction GpioLine::get_direction() const {
	return direction;
}

bool GpioLine::is_active_low() const {
	return active_low;
}

bool GpioLine::has_edge_detection() const {
	return edges_enabled;
}

String GpioLine::get_chip_label() const {
	return chip_label;
}

String GpioLine::get_last_error() const {
	return last_error;
}

int GpioLine::get_value() {
	if (line_fd < 0) {
		last_error = gpio_u8("ligne non réservée ou déjà libérée");
		return -1;
	}
#ifdef __linux__
	struct gpio_v2_line_values values;
	memset(&values, 0, sizeof(values));
	values.mask = 1;
	if (ioctl(line_fd, GPIO_V2_LINE_GET_VALUES_IOCTL, &values) < 0) {
		last_error = gpio_errno_message("lecture de la ligne", errno);
		return -1;
	}
	return (values.bits & 1) ? 1 : 0;
#else
	last_error = gpio_unsupported_message();
	return -1;
#endif
}

Error GpioLine::set_value(bool p_value) {
	if (line_fd < 0) {
		last_error = gpio_u8("ligne non réservée ou déjà libérée");
		return ERR_UNCONFIGURED;
	}
	if (direction != DIRECTION_OUTPUT) {
		last_error = gpio_u8("écriture refusée : la ligne est une entrée");
		return ERR_INVALID_PARAMETER;
	}
#ifdef __linux__
	struct gpio_v2_line_values values;
	memset(&values, 0, sizeof(values));
	values.mask = 1;
	values.bits = p_value ? 1 : 0;
	if (ioctl(line_fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &values) < 0) {
		last_error = gpio_errno_message(gpio_u8("écriture de la ligne"), errno);
		return FAILED;
	}
	return OK;
#else
	(void)p_value;
	last_error = gpio_unsupported_message();
	return ERR_UNAVAILABLE;
#endif
}

void GpioLine::release() {
	_stop_thread();
#ifdef __linux__
	if (line_fd >= 0) {
		close(line_fd);
	}
#endif
	line_fd = -1;
	edges_enabled = false;
}

GpioLine::~GpioLine() {
	release();
}
