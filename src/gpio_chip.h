// Une puce GPIO du noyau Linux (/dev/gpiochipN), ouverte par label, nom,
// chemin ou numéro. Elle sert à réserver des lignes (GpioLine).
//
// Hors Linux, ou si la puce est introuvable, aucune méthode ne plante :
// elles renvoient une erreur et get_last_error() donne un message lisible.

#pragma once

#include "gpio_line.h"

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace godot {

class GpioChip : public RefCounted {
	GDCLASS(GpioChip, RefCounted)

public:
	enum Bias {
		BIAS_AS_IS, // Ne touche pas au réglage actuel.
		BIAS_DISABLED, // Aucune résistance de tirage.
		BIAS_PULL_UP,
		BIAS_PULL_DOWN,
	};

	enum Edge {
		EDGE_NONE,
		EDGE_RISING,
		EDGE_FALLING,
		EDGE_BOTH,
	};

	enum Drive {
		DRIVE_PUSH_PULL,
		DRIVE_OPEN_DRAIN,
		DRIVE_OPEN_SOURCE,
	};

private:
	int chip_fd = -1;
	String path;
	String name;
	String label;
	int line_count = 0;
	String last_error;

	Ref<GpioLine> _request(int p_offset, uint64_t p_flags, int p_debounce_us, bool p_has_output_value,
			bool p_output_value, const String &p_consumer, bool p_edges, bool p_active_low);
	String _describe_line_user(int p_offset);

protected:
	static void _bind_methods();

public:
	// true si cette build sait parler à l'API GPIO du noyau (Linux).
	static bool is_supported();
	// Liste des puces visibles : path, name, label, lines (et error si inaccessible).
	static TypedArray<Dictionary> list_chips();

	// p_chip : label (« pinctrl-rp1 »), nom (« gpiochip0 »), chemin (« /dev/gpiochip4 »)
	// ou numéro (« 4 »).
	Error open(const String &p_chip);
	void close();
	bool is_open() const;

	String get_path() const;
	String get_name() const;
	String get_label() const;
	int get_line_count() const;
	String get_last_error() const;

	// name, consumer, used, direction, active_low, bias, edge, debounce_us.
	Dictionary get_line_info(int p_offset);
	// Cherche une ligne par son nom (« GPIO17 »...). Renvoie -1 si absente.
	int find_line(const String &p_line_name);

	Ref<GpioLine> request_input(int p_offset, Bias p_bias = BIAS_AS_IS, int p_debounce_us = 0,
			Edge p_edges = EDGE_BOTH, bool p_active_low = false, const String &p_consumer = "godot");
	Ref<GpioLine> request_output(int p_offset, bool p_initial_value = false, bool p_active_low = false,
			Drive p_drive = DRIVE_PUSH_PULL, const String &p_consumer = "godot");

	~GpioChip();
};

} // namespace godot

VARIANT_ENUM_CAST(GpioChip::Bias);
VARIANT_ENUM_CAST(GpioChip::Edge);
VARIANT_ENUM_CAST(GpioChip::Drive);
