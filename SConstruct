#!/usr/bin/env python
# Compilation de la GDExtension GPIO.
#
# Exemples :
#   scons platform=linux arch=arm64 target=template_release          (sur le Pi, avec gcc)
#   scons platform=linux arch=x86_64 target=template_debug
#   scons platform=linux arch=arm64 zig=/chemin/vers/zig              (compilation croisée,
#                                                                      même depuis Windows)
#
# Les bibliothèques sont écrites dans project/addons/gpio/bin/.

import os
import sys

EnsureSConsVersion(4, 0)

# --- Option « zig » : compilation croisée Linux avec `zig cc` / `zig c++`. ---------------
# zig embarque les en-têtes du noyau (linux/gpio.h) et une glibc ciblable : on vise
# glibc 2.28 pour rester compatible avec toutes les versions récentes de Raspberry Pi OS.
ZIG_TRIPLES = {
    "x86_64": "x86_64-linux-gnu.2.28",
    "arm64": "aarch64-linux-gnu.2.28",
}
zig = ARGUMENTS.pop("zig", "")
if zig:
    # Ces options doivent être fixées avant que godot-cpp ne lise les arguments :
    # drapeaux de type clang, pas de -static-libstdc++ (zig lie déjà libc++ statiquement)
    # et pas de LTO (inutile ici, et plus fragile en compilation croisée).
    ARGUMENTS.setdefault("platform", "linux")
    ARGUMENTS.setdefault("use_llvm", "yes")
    ARGUMENTS.setdefault("use_static_cpp", "no")
    ARGUMENTS.setdefault("lto", "none")

env = SConscript("godot-cpp/SConstruct", {"api_version": "4.7"})

if env["platform"] != "linux":
    print("Attention : seule la plateforme linux est prévue. Les autres compilent une version")
    print("« non prise en charge » de l'extension (aucune broche, erreurs explicites).")

if zig:
    if env["arch"] not in ZIG_TRIPLES:
        print("Architecture non prise en charge avec zig : " + env["arch"])
        Exit(1)
    triple = ZIG_TRIPLES[env["arch"]]
    zig_cmd = '"%s"' % zig if " " in zig else zig
    # SCons lance les commandes avec un environnement vide : zig a besoin de son cache.
    for var in ["ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR", "LOCALAPPDATA", "APPDATA", "HOME", "XDG_CACHE_HOME"]:
        if var in os.environ:
            env["ENV"][var] = os.environ[var]
    env["CC"] = "%s cc -target %s" % (zig_cmd, triple)
    env["CXX"] = "%s c++ -target %s" % (zig_cmd, triple)
    env["LINK"] = env["CXX"]
    env["SHLINK"] = env["CXX"]
    env["AR"] = "%s ar" % zig_cmd
    env["RANLIB"] = "%s ranlib" % zig_cmd
    env["OBJSUFFIX"] = ".o"
    env["SHOBJSUFFIX"] = ".pic.o"  # zig refuse l'extension « .os » au moment du lien.
    env["LIBPREFIX"] = "lib"
    env["LIBSUFFIX"] = ".a"
    env["SHLIBPREFIX"] = "lib"
    env["SHLIBSUFFIX"] = ".so"
    # -march=... : zig ne comprend pas « x86-64 » et la cible -target suffit (CPU de base).
    # -Wl,-R,'$ORIGIN' : les guillemets simples passeraient tels quels sous Windows.
    def _keep(flag):
        text = str(flag)
        return not (text.startswith("-march=") or text in ["-m64", "-m32"] or "ORIGIN" in text)

    env["CCFLAGS"] = [flag for flag in env["CCFLAGS"] if _keep(flag)]
    # zig active UBSan par défaut sans optimisation, ce que godot-cpp refuse.
    if env["optimize"] in ["none", "debug"]:
        env.Append(CCFLAGS=["-fno-sanitize=all"])
    env["LINKFLAGS"] = [flag for flag in env["LINKFLAGS"] if _keep(flag)]
    if sys.platform == "win32":
        # Hôte Windows : la commande d'archivage de godot-cpp dépasse la limite de longueur
        # de ligne. SCons passe alors par un fichier de réponse (@fichier), mais ne garde
        # que le premier mot de la commande : il faut un exécutable « d'un seul mot ».
        # On génère donc de petits scripts .cmd qui appellent zig.
        wrapper_dir = Dir("#.zig-wrappers").abspath
        os.makedirs(wrapper_dir, exist_ok=True)

        def _wrapper(name, args):
            path = os.path.join(wrapper_dir, name)
            content = '@"%s" %s %%*\r\n' % (zig, args)
            if not os.path.exists(path) or open(path).read() != content.replace("\r\n", "\n"):
                with open(path, "w", newline="") as handle:
                    handle.write(content)
            return '"%s"' % path if " " in path else path

        env["AR"] = _wrapper("zig-ar.cmd", "ar")
        env["SHLINK"] = _wrapper("zig-c++-%s.cmd" % env["arch"], "c++ -target %s" % triple)
        env["ARCOM"] = "${TEMPFILE('$AR rcs $TARGET $SOURCES', '$ARCOMSTR')}"
        env["SHLINKCOM"] = "${TEMPFILE('$SHLINK -o $TARGET -shared $SHLINKFLAGS $__SHLIBVERSIONFLAGS "
        env["SHLINKCOM"] += "$__RPATH $SOURCES $_LIBDIRFLAGS $_LIBFLAGS', '$SHLINKCOMSTR')}"
        env["TEMPFILEARGESCFUNC"] = lambda arg: str(arg).replace("\\", "/")
        env["MAXLINELENGTH"] = 8000

# Environnement propre à l'extension (ne force pas la recompilation de godot-cpp).
lib_env = env.Clone()
lib_env.Append(CPPPATH=["src/"])
if zig:
    # Active l'appel à __cxa_finalize au déchargement (voir src/register_types.cpp).
    lib_env.Append(CPPDEFINES=["GPIO_ZIG_RUNTIME"])
sources = Glob("src/*.cpp")

library = lib_env.SharedLibrary(
    "project/addons/gpio/bin/libgpio{}.so".format(env["suffix"]),
    source=sources,
)

lib_env.NoCache(library)
Default(library)
