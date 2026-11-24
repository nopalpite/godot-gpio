# godot-gpio

Addon Godot 4.7 pour piloter les GPIO d'un Raspberry Pi **directement depuis Godot**,
sans OSC, sans démon et sans root : boutons physiques, LED, gyrophare, relais.

- **Couche 1, GDExtension C++** (`src/`) : parle à l'API GPIO v2 du noyau Linux
  (`/dev/gpiochipN`, ioctl de `linux/gpio.h`). Pas de libgpiod, pas de `pigpiod` ni de
  `rgpiod`. Les fronts sont surveillés dans un thread dédié et remontent en signal Godot
  sur le thread principal.
- **Couche 2, GDScript** (`project/addons/gpio/`) : des broches **nommées** dans une
  ressource de config, un autoload `Gpio`, et un **mode simulation** automatique sur PC.

Cible : **Raspberry Pi OS 64 bits** (Bookworm ou plus récent), **Pi 4 et Pi 5**.

## Sommaire

- [Utilisation dans un jeu](#utilisation-dans-un-jeu)
- [Installation](#installation)
- [Configuration des broches](#configuration-des-broches)
- [Câblage](#câblage)
- [Droits d'accès : le groupe `gpio`](#droits-daccès--le-groupe-gpio)
- [Différences entre Pi 4 et Pi 5](#différences-entre-pi-4-et-pi-5)
- [Mode simulation et panneau de diagnostic](#mode-simulation-et-panneau-de-diagnostic)
- [Erreurs : ne jamais planter](#erreurs--ne-jamais-planter)
- [API](#api)
- [Compiler la GDExtension](#compiler-la-gdextension)
- [Hors périmètre de la V1 et pistes](#hors-périmètre-de-la-v1-et-pistes)
- [Ce qui a été testé, et ce qui ne l'a pas été](#ce-qui-a-été-testé-et-ce-qui-ne-la-pas-été)

## Utilisation dans un jeu

Le jeu ne voit que des **noms** de broches et des **actions** Godot :

```gdscript
func _unhandled_input(event: InputEvent) -> void:
	# Clavier, OSC ou bouton GPIO : c'est la même action.
	if event.is_action_pressed(&"bouton_rouge"):
		Gpio.set_pin(&"led", true)
	elif event.is_action_released(&"bouton_rouge"):
		Gpio.set_pin(&"led", false)
		Gpio.blink(&"gyrophare", 0.4, 3)  # 3 clignotements de 0,4 s
```

Autres usages courants :

```gdscript
Gpio.pulse(&"relais_porte", 0.5)     # colle le relais 0,5 s
Gpio.pin_changed.connect(_on_pin)    # func _on_pin(name: StringName, value: bool)
if Gpio.get_pin(&"capteur"):         # lecture instantanée
	...
```

## Installation

1. Copier le dossier `addons/gpio/` dans `res://addons/` du projet.
   Les bibliothèques compilées (`addons/gpio/bin/*.so`) viennent de l'artefact
   **`addon-gpio`** de la CI GitHub (ou d'une compilation locale, voir plus bas).
   Sans elles, l'addon tourne en simulation.
2. *Projet → Paramètres du projet → Extensions* : activer **GPIO**. Le plugin ajoute
   l'autoload `Gpio` et le réglage `gpio/config_path` (par défaut
   `res://config/gpio_config.tres`).
   Sans le plugin, on peut déclarer l'autoload à la main :
   `Gpio="*res://addons/gpio/gpio.gd"` dans la section `[autoload]` de `project.godot`.
3. Créer la config : *Nouvelle ressource → GpioConfig*, enregistrée dans
   `res://config/gpio_config.tres`, et y ajouter des `GpioPin`.
4. Déclarer dans l'InputMap les actions utilisées par les entrées (sinon l'autoload les
   crée au démarrage, avec un avertissement).
5. Export : préréglage **Linux**, architecture **arm64** pour le Pi. Godot embarque le
   `.so` correspondant tout seul grâce à `gpio.gdextension`.

Le dossier `project/` de ce dépôt est un projet d'exemple complet : un bouton (GPIO17)
allume une LED (GPIO27) et, au relâchement, le gyrophare (GPIO22) clignote trois fois.

## Configuration des broches

Chaque `GpioPin` décrit une broche :

| Champ | Rôle |
|---|---|
| `name` | Nom utilisé par le jeu (`&"led"`). Unique. |
| `chip` | Puce : label (`pinctrl-rp1`), nom (`gpiochip0`), chemin ou numéro. Vide = `default_chip` de la config. |
| `line` | Numéro de ligne = **numéro BCM** (GPIO17 → 17), pas le numéro physique de la broche. |
| `direction` | `INPUT` ou `OUTPUT`. |
| `active_low` | Inverse la logique (1 = niveau électrique bas). |
| `bias` *(entrée)* | `PULL_UP`, `PULL_DOWN`, `NONE` (résistance externe), `AS_IS`. |
| `debounce_ms` *(entrée)* | Anti-rebond **fait par le noyau**, en ms. 20 ms convient à la plupart des boutons. |
| `action` *(entrée)* | Action Godot déclenchée en pressed / released. |
| `sim_key` *(entrée)* | Touche qui simule l'entrée en mode simulation. |
| `initial_value` *(sortie)* | Valeur au démarrage. |

`GpioConfig` regroupe les broches et quelques réglages : `default_chip` (`auto` par
défaut), `simulation` (`AUTO`, `ALWAYS`, `NEVER`), `consumer` (nom visible dans
`gpioinfo`) et `reset_outputs_on_exit` (éteint les sorties en quittant, activé par défaut).

Avec la config `auto`, l'addon essaie dans l'ordre `pinctrl-rp1` (Pi 5),
`pinctrl-bcm2711` (Pi 4), `pinctrl-bcm2835` (Pi 3 et plus anciens), puis la puce 0.

## Câblage

Les GPIO du Pi sont en **3,3 V** et ne tolèrent **pas** le 5 V. Une broche ne fournit
que quelques mA : jamais de moteur, de relais ou de gyrophare en direct.

**Bouton** (le cas le plus simple, aucune résistance externe) : entre la broche et la
masse, avec `bias = PULL_UP` et `active_low = true`. Appuyé = 1.

```
GPIO17 (broche 11) ──┐
                     ⏚ bouton
GND    (broche 9)  ──┘
```

**LED** : broche → résistance 220 à 330 Ω → anode de la LED, cathode → masse.

```
GPIO27 (broche 13) ── 330 Ω ──▶|── GND (broche 14)
```

**Relais, gyrophare, charge en 12 ou 24 V** : passer par un module relais avec entrée
compatible 3,3 V (de préférence optocouplé) ou un transistor / MOSFET de commande avec
diode de roue libre sur les charges inductives. Beaucoup de modules relais sont actifs
à l'état bas : cocher `active_low` pour garder « 1 = allumé » dans le jeu.

**Longs fils (bornes d'expo)** : préférer une résistance de tirage externe plus forte
(4,7 kΩ vers 3,3 V) que le tirage interne (environ 50 kΩ), garder l'anti-rebond, et
idéalement un optocoupleur si les boutons sont loin du Pi.

## Droits d'accès : le groupe `gpio`

Sur Raspberry Pi OS, `/dev/gpiochip*` appartient au groupe **`gpio`**. L'utilisateur qui
lance le jeu doit en faire partie (c'est le cas de l'utilisateur créé à l'installation) :

```bash
groups                          # doit contenir « gpio »
sudo usermod -aG gpio "$USER"   # sinon, puis se déconnecter / reconnecter
ls -l /dev/gpiochip*            # crw-rw---- root gpio ...
```

Pas besoin de root ni de démon. Si l'accès est refusé, chaque broche concernée signale
une erreur explicite (« accès refusé : l'utilisateur doit faire partie du groupe
« gpio » ») et le jeu continue.

Outils utiles pour vérifier le câblage (paquet `gpiod`, sans rapport avec l'addon) :
`gpiodetect` (liste des puces), `gpioinfo` (état des lignes ; celles de Godot
apparaissent avec le consumer `godot`).

## Différences entre Pi 4 et Pi 5

| | Pi 4 | Pi 5 |
|---|---|---|
| Contrôleur du connecteur 40 broches | SoC BCM2711 | puce d'E/S **RP1** |
| Label de la puce | `pinctrl-bcm2711` | `pinctrl-rp1` |
| Numéro de la puce | `gpiochip0` | `gpiochip0` sur les noyaux récents, `gpiochip4` sur les premiers noyaux Bookworm |
| Numéros de lignes | BCM 0 à 27 sur le connecteur | identiques (BCM 0 à 27) |
| Anti-rebond | logiciel, dans le noyau | logiciel, dans le noyau |

Le numéro de la puce du Pi 5 a changé d'une version de noyau à l'autre : c'est pour ça
que l'addon ouvre les puces **par leur label**. Avec `default_chip = "auto"`, la même
config fonctionne sur Pi 4 et Pi 5 sans modification.

Les anciennes bibliothèques basées sur `/dev/gpiomem` ou sur les registres du BCM
(WiringPi, pigpio, RPi.GPIO) ne fonctionnent pas sur le Pi 5. L'API GPIO du noyau, elle,
marche sur les deux.

## Mode simulation et panneau de diagnostic

Avec `simulation = AUTO`, l'autoload passe en simulation quand la GDExtension n'est pas
chargée (Windows, macOS, Linux sans le `.so`) ou quand la machine n'a aucune puce GPIO.
Le mode est affiché au démarrage : `[Gpio] Mode simulation (...)`.

En simulation :

- les entrées se déclenchent avec leur `sim_key` (touche maintenue = bouton appuyé) ou
  par code : `Gpio.simulate_input(&"bouton", true)` ;
- les sorties gardent leur état en mémoire, `pin_changed` est émis comme sur le Pi ;
- `Gpio.describe()` donne un résumé texte de toutes les broches.

`GpioDebugPanel` (`addons/gpio/gpio_debug_panel.gd`) est un `PanelContainer` autonome :
mode, valeur de chaque broche (pastille verte), bouton « Appuyer » pour simuler une
entrée à la souris, interrupteur pour chaque sortie, et liste des erreurs. Il fonctionne
aussi sur le Pi (pratique pour tester une LED ou un relais sur place).

Pour le brancher sur l'overlay F12 du template, il suffit de l'instancier dans
`DebugOverlay` :

```gdscript
var panel := GpioDebugPanel.new()
add_child(panel)
```

> L'éditeur Godot sous Windows affiche au chargement
> `No GDExtension library found for current OS and architecture (windows.x86_64)`.
> C'est attendu : l'extension n'existe que pour Linux, l'addon passe en simulation.

## Erreurs : ne jamais planter

- Puce introuvable, ligne déjà prise, accès refusé, numéro hors limites : la broche
  passe en erreur (`push_error` + signal `pin_error(name, message)`), les autres
  broches continuent de fonctionner.
- `set_pin` sur une broche inconnue, en erreur ou sur une entrée : renvoie `false`,
  sans exception.
- `Gpio.get_errors()` liste toutes les erreurs ; le panneau de diagnostic les affiche.
- Côté C++, hors Linux ou sans puce, chaque méthode renvoie un code d'erreur Godot et
  `get_last_error()` donne le message.

Exemple de message : `réservation de la ligne 17 de pinctrl-rp1 : ligne déjà réservée
par un autre programme ou une autre broche (errno 16) (utilisée par « python3 »)`.

## API

### Autoload `Gpio` (`GpioService`)

| Membre | Description |
|---|---|
| `signal pin_changed(pin_name, value)` | Changement de valeur logique (entrées et sorties). |
| `signal pin_error(pin_name, message)` | Broche impossible à ouvrir ou à piloter. |
| `signal configured` | Config (re)chargée. |
| `set_pin(name, value) -> bool` | Écrit une sortie (annule blink / pulse en cours). |
| `get_pin(name) -> bool` | Valeur logique. Pour une entrée réelle, relit la ligne. |
| `toggle_pin(name) -> bool` | Inverse une sortie, renvoie la nouvelle valeur. |
| `blink(name, period = 0.5, count = 3)` | `count` allumages de `period` secondes, puis éteint. `count <= 0` : sans fin. |
| `pulse(name, duration = 0.2)` | Allume puis éteint après `duration` secondes. |
| `stop_effect(name)` | Arrête blink / pulse sans changer la valeur. |
| `simulate_input(name, value)` | Injecte une valeur sur une entrée (simulation, tests). |
| `is_simulated()`, `has_pin(name)`, `get_pin_names()` | État général. |
| `get_pin_error(name)`, `get_errors()`, `get_status()`, `describe()` | Diagnostic. |
| `setup(config)` / `shutdown()` | Reconfigure / libère tout (appelé seul au démarrage et en quittant). |

`blink` et `pulse` utilisent des `Timer` Godot (process mode *Always* : ils continuent
pendant une pause du jeu). Leur précision est celle d'une frame, largement suffisante
pour un voyant ou un relais, pas pour générer un signal.

### GDExtension (`GpioChip`, `GpioLine`)

Accessible directement si besoin (dans ce cas, tester `ClassDB.class_exists(&"GpioChip")`
car la classe n'existe pas hors Linux) :

```gdscript
var chip := GpioChip.new()
if chip.open("pinctrl-rp1") != OK:
	push_error(chip.get_last_error())
var bouton: GpioLine = chip.request_input(17, GpioChip.BIAS_PULL_UP, 20000, GpioChip.EDGE_BOTH, true)
bouton.edge_detected.connect(func(rising: bool, timestamp_ns: int) -> void: print(rising))
var led: GpioLine = chip.request_output(27, false)
led.set_value(true)
```

- `GpioChip` : `list_chips()` (statique), `is_supported()` (statique), `open(chip)`,
  `close()`, `get_label()`, `get_path()`, `get_line_count()`, `get_line_info(offset)`,
  `find_line("GPIO17")`, `request_input(...)`, `request_output(...)`, `get_last_error()`.
- `GpioLine` : `get_value()` (0, 1 ou -1 en erreur), `set_value(bool)`, `release()`,
  signaux `edge_detected(rising, timestamp_ns)` et `line_error(message)`.

La ligne reste réservée tant que l'objet `GpioLine` existe ; `release()` (ou sa
destruction) arrête le thread des fronts et ferme le descripteur.

## Compiler la GDExtension

godot-cpp est un sous-module (version 10.0.0, `api_version=4.7`) :

```bash
git submodule update --init
pip install scons
```

**Sur le Pi** (ou n'importe quel Linux avec gcc et les en-têtes du noyau) :

```bash
scons platform=linux arch=arm64 target=template_release
scons platform=linux arch=arm64 target=template_debug
```

**Compilation croisée** (Linux, Windows ou macOS) avec [zig](https://ziglang.org), qui
embarque les en-têtes du noyau et une glibc ciblable (2.28 ici) :

```bash
pip install ziglang
ZIG="$(python -c 'import os, ziglang; print(os.path.join(os.path.dirname(ziglang.__file__), "zig"))')"
scons platform=linux arch=arm64  target=template_release zig="$ZIG"
scons platform=linux arch=x86_64 target=template_debug   zig="$ZIG"
```

Les `.so` sont écrits dans `project/addons/gpio/bin/`.
La première compilation de godot-cpp prend plusieurs minutes ; les suivantes sont rapides.

La CI GitHub (`.github/workflows/build.yml`) lance gdlint / gdformat, compile les quatre
variantes avec zig (x86_64 et arm64, debug et release), lance le test du projet
d'exemple en headless sous Godot Linux avec l'extension chargée (sans puce GPIO), une
fois compilée avec gcc et une fois avec zig, puis publie l'artefact `addon-gpio` prêt à
copier.

Le job « paquet » dépend du stockage d'artefacts GitHub de l'organisation : si son quota
est plein, il échoue (les compilations et les tests, eux, n'en dépendent pas).

### Builds zig et builds gcc

Les deux chaînes produisent une extension fonctionnelle (testées toutes les deux en CI).
Particularité de zig : son runtime n'exécute pas les destructeurs statiques au
déchargement de la bibliothèque, ce que fait `crtbeginS.o` avec gcc. Sans correctif,
Godot plantait en quittant. `src/register_types.cpp` appelle donc `__cxa_finalize` pour
les builds zig (macro `GPIO_ZIG_RUNTIME`, posée par le SConstruct).

### Limite connue : plantage en quittant le premier import

Avec l'extension chargée, Godot 4.7.2 sous Linux plante en quittant le **tout premier**
import d'un projet (`godot --headless --import` sur un projet sans dossier `.godot`).
L'import est alors déjà terminé ; le second import, l'ouverture de l'éditeur et le jeu
sont propres (constaté en CI, avec gcc comme avec zig ; un import témoin sans
l'extension ne plante pas). La cause exacte n'est pas encore identifiée : la pile est
dans le nettoyage de fin de Godot, pas dans le code de l'extension. La CI tolère ce
premier plantage et exige que le second import réussisse.

### Tests

```bash
godot --headless --path project --import
godot --headless --path project res://tests/test_simulation.tscn   # code de sortie 0 = OK
```

## Hors périmètre de la V1 et pistes

- **PWM** (variation de LED, servomoteurs) : pas en V1. Piste : le PWM matériel via
  `/sys/class/pwm` (overlay `dtoverlay=pwm` ou `pwm-2chan` dans `config.txt`, puis
  `export`, `period`, `duty_cycle`, `enable`). Le PWM logiciel depuis Godot serait trop
  irrégulier.
- I²C, SPI, UART : non couverts.
- Lecture groupée de plusieurs lignes en une seule requête (l'API v2 le permet) : chaque
  broche est aujourd'hui une requête séparée, ce qui suffit pour quelques dizaines de
  boutons.
- Branchement du panneau de diagnostic dans l'overlay F12 du template, et éventuellement
  déclaration des broches dans `app_config.tres`.

## Ce qui a été testé, et ce qui ne l'a pas été

Testé lors de la création :

- gdlint et gdformat (gdtoolkit 4.5.0) : aucun problème ;
- projet d'exemple et test headless avec Godot 4.7.2 **Windows** (extension absente) :
  mode simulation, actions, touches de simulation, `set_pin` / `pulse` / `blink`,
  broches inconnues, mode `NEVER` sans matériel (erreurs lisibles, aucun plantage) ;
- même test avec Godot 4.7.2 **Linux x86_64** en CI, **extension chargée** (builds gcc et
  zig) : `is_supported()`, `list_chips()` (vide sur le runner), erreurs d'ouverture et de
  réservation lisibles et bien encodées, bascule automatique en simulation faute de
  puce, mode `NEVER` (chaque broche en erreur, le reste continue), sortie propre ;
- compilation des quatre variantes (x86_64 / arm64, debug / release), en local depuis
  Windows avec zig et en CI ; binaires inspectés (architecture ELF, symbole
  `gpio_library_init` exporté, libc++ liée statiquement, glibc 2.17 maximum requise) ;
- sources de l'extension compilées sans avertissement en `-Wall -Wextra`, y compris la
  variante « hors Linux » (stubs).

**Pas testé sur un vrai Raspberry Pi** (aucun Pi disponible) :

- ouverture des puces `pinctrl-rp1` / `pinctrl-bcm2711`, réservation des lignes, lecture
  et écriture, biais, actif bas, anti-rebond noyau, fronts et thread de surveillance
  (aucune puce GPIO sur les machines de test, le code ioctl n'a donc jamais été exercé) ;
- droits du groupe `gpio` et messages d'erreur réels (EACCES, EBUSY) ;
- chargement du `.so` **arm64** par Godot (seul le x86_64 a été chargé), export arm64.

Premier essai conseillé sur le Pi : lancer le projet d'exemple avec le panneau de
diagnostic, vérifier « GPIO : matériel », puis `gpioinfo` pour voir les lignes `godot`.
