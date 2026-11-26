// Une ligne GPIO réservée auprès du noyau (entrée ou sortie).
//
// Une entrée peut être surveillée de deux façons :
// - fronts du noyau (request_input) : chaque front électrique réveille le thread,
//   l'anti-rebond éventuel est fait par le noyau ;
// - échantillonnage (request_input_sampled) : le thread lit le niveau à intervalle
//   fixe et ne valide un changement qu'après une durée stable. Insensible aux
//   impulsions parasites très brèves (câbles longs, tirage interne faible), qui
//   bloquent l'anti-rebond du noyau en le relançant sans fin.
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
	bool sampled = false;
	int sample_period_us = 1000;
	int sample_target = 1; // Nombre d'échantillons concordants pour valider un changement.
	std::atomic<int> stable_value{ -1 };
	bool active_low = false;
	String chip_label;
	String last_error;

	std::thread edge_thread;
	std::atomic<bool> running{ false };

	void _edge_loop();
	void _sample_loop();
	int _read_raw();
	Error _start_thread(void (GpioLine::*p_loop)());
	void _stop_thread();
	void _emit_edge(bool p_rising, int64_t p_timestamp_ns);

protected:
	static void _bind_methods();

public:
	// Appelé uniquement par GpioChip, juste après la réservation.
	Error setup(int p_line_fd, int p_offset, Direction p_direction, bool p_edges, bool p_active_low,
			const String &p_chip_label);
	// Variante échantillonnée : lit la ligne toutes les p_period_us et valide un
	// changement après p_debounce_us de niveau stable.
	Error setup_sampled(int p_line_fd, int p_offset, bool p_active_low, const String &p_chip_label, int p_debounce_us,
			int p_period_us);

	bool is_valid() const;
	int get_offset() const;
	Direction get_direction() const;
	bool is_active_low() const;
	bool has_edge_detection() const;
	bool is_sampled() const;
	String get_chip_label() const;
	String get_last_error() const;

	// Valeur logique (tient compte de l'actif bas) : 0 ou 1, -1 en cas d'erreur.
	// Pour une ligne échantillonnée, c'est la valeur validée (après anti-rebond).
	int get_value();
	Error set_value(bool p_value);
	void release();

	~GpioLine();
};

} // namespace godot

VARIANT_ENUM_CAST(GpioLine::Direction);
