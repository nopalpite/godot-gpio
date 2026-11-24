#include "register_types.h"

#include "gpio_chip.h"
#include "gpio_line.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

#if defined(__linux__) && defined(GPIO_ZIG_RUNTIME)
// Uniquement pour une build zig (macro posée par SConstruct avec zig=...).
// Les destructeurs statiques (godot-cpp, libc++) sont enregistrés par __cxa_atexit avec
// le __dso_handle de cette bibliothèque. Avec gcc, crtbeginS.o les exécute au
// déchargement (dlclose) via __cxa_finalize. Le runtime de zig ne le fait pas : ils
// restaient dans la liste atexit et Godot plantait en quittant, dans du code déjà
// déchargé. On appelle donc __cxa_finalize nous-mêmes.
extern "C" {
extern void *__dso_handle;
void __cxa_finalize(void *p_dso);
}

__attribute__((destructor)) static void gpio_library_finalize() {
	__cxa_finalize(&__dso_handle);
}
#endif

void initialize_gpio_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(GpioLine);
	GDREGISTER_CLASS(GpioChip);
}

void uninitialize_gpio_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {
// Point d'entrée déclaré dans addons/gpio/gpio.gdextension.
GDExtensionBool GDE_EXPORT gpio_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_gpio_module);
	init_obj.register_terminator(uninitialize_gpio_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
