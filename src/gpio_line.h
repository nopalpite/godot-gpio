// Une ligne GPIO réservée auprès du noyau (entrée ou sortie).
//
// Une instance est créée par GpioChip.request_input() ou request_output().
// Elle garde le descripteur de fichier renvoyé par GPIO_V2_GET_LINE_IOCTL :
// tant qu'elle vit, la ligne reste réservée. release() (ou la destruction de
// l'objet) arrête le thread des fronts et libère le descripteur.

#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/string.hpp>

#include <atomic>
#include <cstdint>
#include <thread>

namespace godot {

class GpioLine : public RefCounted {
	GDCLASS(GpioLine, RefCounted)

public:
	enum Direction {
		DIRECTION_INPUT,
		DIRECTION_OUTPUT,
	};

private:
	int line_fd = -1;
	int wake_fd = -1;
	int offset = -1;
	Direction direction = DIRECTION_INPUT;
	bool edges_enabled = false;
	bool active_low = false;
	String chip_label;
	String last_error;

	std::thread edge_thread;
	std::atomic<bool> running{ false };

	void _edge_loop();
	void _stop_thread();
	void _emit_edge(bool p_rising, int64_t p_timestamp_ns);

protected:
	static void _bind_methods();

public:
	// Appelé uniquement par GpioChip, juste après la réservation.
	Error setup(int p_line_fd, int p_offset, Direction p_direction, bool p_edges, bool p_active_low,
			const String &p_chip_label);

	bool is_valid() const;
	int get_offset() const;
	Direction get_direction() const;
	bool is_active_low() const;
	bool has_edge_detection() const;
	String get_chip_label() const;
	String get_last_error() const;

	// Valeur logique (tient compte de l'actif bas) : 0 ou 1, -1 en cas d'erreur.
	int get_value();
	Error set_value(bool p_value);
	void release();

	~GpioLine();
};

} // namespace godot

VARIANT_ENUM_CAST(GpioLine::Direction);
