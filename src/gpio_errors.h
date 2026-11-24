// Messages d'erreur lisibles (en français) à partir d'errno.

#pragma once

#include <godot_cpp/variant/string.hpp>

#include <cstring>

#ifdef __linux__
#include <cerrno>
#endif

namespace godot {

inline String gpio_unsupported_message() {
	return String("GPIO non pris en charge sur cette plateforme (Linux uniquement, API GPIO v2 du noyau)");
}

inline String gpio_errno_message(const String &p_context, int p_errno) {
	String detail;
#ifdef __linux__
	switch (p_errno) {
		case EACCES:
		case EPERM:
			detail = "accès refusé : l'utilisateur doit faire partie du groupe « gpio » "
					 "(sudo usermod -aG gpio $USER, puis se reconnecter)";
			break;
		case EBUSY:
			detail = "ligne déjà réservée par un autre programme ou une autre broche";
			break;
		case ENOENT:
		case ENODEV:
		case ENXIO:
			detail = "périphérique introuvable";
			break;
		case EINVAL:
			detail = "paramètre refusé par le noyau (numéro de ligne hors limites ou option non prise en charge)";
			break;
		case ENOTTY:
			detail = "ce fichier n'est pas une puce GPIO ou le noyau ne connaît pas l'API GPIO v2 (noyau 5.10 minimum)";
			break;
		default:
			detail = String(strerror(p_errno));
			break;
	}
#else
	detail = String(strerror(p_errno));
#endif
	return p_context + String(" : ") + detail + String(" (errno ") + itos(p_errno) + String(")");
}

} // namespace godot
