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
- [Tester sur un Raspberry Pi : le banc de test](#tester-sur-un-raspberry-pi--le-banc-de-test)
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

1. Télécharger `godot-gpio-X.Y.Z.zip` depuis les
   [releases](https://github.com/nopalpite/godot-gpio/releases) et le décompresser à la
   racine du projet Godot : il contient `addons/gpio/`, bibliothèques compilées
   comprises (`addons/gpio/bin/*.so`, Linux x86_64 et arm64, debug et release).
   À défaut : l'artefact **`addon-gpio`** de la CI, ou une compilation locale (voir plus
   bas). Sans les bibliothèques, l'addon tourne en simulation.
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
| `debounce_ms` *(entrée)* | Durée de stabilité exigée avant de valider un changement, en ms. 20 ms convient à la plupart des boutons. 0 = fronts bruts. |
| `debounce_mode` *(entrée)* | `SAMPLED` (par défaut) : l'extension lit le niveau toutes les millisecondes, insensible aux parasites. `KERNEL` : anti-rebond du noyau, horodatage précis mais bloqué par les parasites (voir ci-dessous). |
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

**Pourquoi l'anti-rebond par échantillonnage est le mode par défaut.** Mesuré sur un
Pi 4 avec un bouton au bout de câbles longs et le seul tirage interne : environ
10 000 impulsions parasites par seconde, si brèves que le noyau ne voit que des fronts
montants, alors que 297 lectures du niveau sur 300 donnent la bonne valeur.
L'anti-rebond du noyau attend 20 ms *sans aucun front* : chaque impulsion le relance,
et le bouton reste « appuyé » indéfiniment. En mode `SAMPLED`, un thread de
l'extension lit le niveau toutes les millisecondes et le passe dans un intégrateur
(un compteur borné qui monte à 1 et descend à 0) : une lecture fausse isolée ne fait
que retarder d'un échantillon. C'est ce qui rend tolérantes les bibliothèques qui
lisent le niveau (RPi.GPIO, gpiozero) : le câblage bruité ne se voyait pas.

## Droits d'accès : le groupe `gpio`

Sur Raspberry Pi OS, `/dev/gpiochip*` appartient au groupe **`gpio`**. L'utilisateur qui
lance le jeu doit en faire partie (c'est le cas de l'utilisateur créé à l'installation) :

```bash
groups                          # doit contenir « gpio »
sudo usermod -aG gpio "$USER"   # sinon, puis se déconnecter / reconnecter
ls -l /dev/gpiochip*            # crw-rw---- root gpio ...
```

Pas besoin de root ni de démon. Si l'accès est refusé, chaque broche concernée signale
une erreur explicite, avec les vrais droits du fichier (« accès refusé (root:gpio,
droits 660) : l'utilisateur doit faire partie du groupe « gpio » ») et le jeu continue.

Sous **Ubuntu** (testé sur 26.04, Pi 4), la règle udev ne donne le groupe `gpio` qu'à la
puce principale (`gpiochip0`, `pinctrl-bcm2711`). La seconde puce, `gpiochip1`, est
l'extenseur du firmware (LED d'activité, caméra) : elle reste réservée à root, ce qui est
normal et sans incidence pour les broches du connecteur.

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
| Anti-rebond du noyau | logiciel, dans le noyau | logiciel, dans le noyau |

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

## Tester sur un Raspberry Pi : le banc de test

Le projet d'exemple contient un **banc de test** (`project/banc/`) qui exerce tout le
chemin matériel : puce, lignes, tirages, actif bas, drain ouvert, fronts, anti-rebond du
noyau, fuites de descripteurs et de threads, autoload `Gpio`, erreurs réelles (EBUSY...).

### Câblage : un seul fil

Le test automatique n'a besoin d'aucun composant : une sortie est reliée par un fil à une
entrée, et le Pi s'observe lui-même.

```
broche 16 (GPIO 23, sortie) ──┐
                              │  un fil femelle-femelle
broche 18 (GPIO 24, entrée) ──┘

broche 22 (GPIO 25) : reliée à RIEN (sert à tester les résistances de tirage)
```

D'autres broches se choisissent en ligne de commande ou dans l'interface :
`--sortie=N --entree=N --flottante=N` (`-1` pour ne pas tester les tirages),
`--puce=auto|pinctrl-rp1|gpiochip0|0`.

### Préparer le Pi

1. Raspberry Pi OS **64 bits**, utilisateur dans le groupe `gpio` (voir plus haut).
2. Télécharger Godot 4.7.2 **Linux arm64** (`Godot_v4.7.2-stable_linux.arm64.zip`) depuis
   les releases GitHub de Godot, le dézipper et le rendre exécutable (`chmod +x`).
3. Récupérer l'artefact **`projet-gpio`** de la dernière exécution de la CI (onglet
   *Actions* du dépôt) : c'est le dossier `project/` complet, bibliothèques comprises.
   Le dézipper, par exemple dans `~/projet-gpio`.
4. Importer le projet une première fois (deux fois si Godot plante en quittant le premier
   import : limite connue, voir plus bas) :

```bash
./godot --headless --path ~/projet-gpio --import
```

### Lancer le banc

```bash
# Avec écran : menu (test automatique ou moniteur GPIO)
./godot --path ~/projet-gpio res://banc/banc.tscn

# Sans écran, en SSH : code de sortie 0 = aucun échec
./godot --headless --path ~/projet-gpio res://banc/test_materiel.tscn
./godot --headless --path ~/projet-gpio res://banc/test_materiel.tscn -- --sortie=5 --entree=6
```

Le test dure une quinzaine de secondes. Chaque ligne est `OK`, `KO`, `IGNORÉ` ou `INFO`,
et un rapport texte est écrit dans
`~/.local/share/godot/app_userdata/GPIO - exemple/rapports/` : c'est ce fichier qu'il faut
transmettre en cas de problème. Le programme quitte volontairement avec des lignes encore
réservées : un code de sortie supérieur à 1 signalerait un plantage à la fermeture.

| Section | Ce qui est vérifié |
|---|---|
| Environnement | carte, noyau, groupe `gpio`, extension chargée, `list_chips()` |
| Puce GPIO | ouverture par label, nom, chemin et numéro ; `close()` ; `get_line_info()` ; `find_line()` |
| Sortie -> entrée | 40 écritures relues, relecture d'une sortie, infos des lignes, écriture refusée sur une entrée, `release()` |
| Modes de sortie | valeur initiale, actif bas en sortie et en entrée, drain ouvert, source ouverte |
| Tirages | pull-up et pull-down sur la broche flottante |
| Fronts | 20 fronts dans l'ordre, horodatages croissants, latence, filtres montant / descendant / aucun, actif bas |
| Anti-rebond | rafales filtrées (1 front ou aucun), changements lents tous transmis |
| Échantillonnage | `request_input_sampled()`, délai de validation, rafales, impulsions parasites ignorées, relâchement validé malgré 300 ms de parasites (comparé au noyau) |
| Robustesse | 100 réservations avec thread, ligne détruite avec des fronts en attente, pas de fuite de descripteurs ni de threads |
| Autoload `Gpio` | mode matériel, broche en double isolée, `set_pin` -> action Godot, `pulse`, `blink`, `shutdown()` |
| Erreurs | EBUSY, ligne hors limites, puce inexistante |

### Le moniteur GPIO

`res://banc/moniteur.tscn` affiche le connecteur 40 broches tel qu'il est sur la carte,
avec l'état de chaque GPIO en direct : gris = libre, bleu = entrée, orange = sortie
(allumée à 1), violet hachuré = ligne prise par un autre programme (par exemple les
GPIO 7 et 8 quand le SPI est activé), rouge = erreur.

Un clic sur une broche ouvre ses réglages : libre, entrée ou sortie, nom, tirage,
anti-rebond, actif bas, mode de sortie. Une sortie s'allume, s'éteint, envoie une
impulsion ou clignote ; une entrée affiche sa valeur, ses fronts, ses appuis et la durée
du dernier appui. Une entrée peut **commander une sortie** (liaison, éventuellement
inversée), sans écrire de code.

**Exporter la config** enregistre les broches réglées dans un `gpio_config.tres`
(`user://gpio_config.tres`, et `res://config/gpio_config_moniteur.tres` quand le projet
est lancé avec l'éditeur), directement utilisable par l'autoload `Gpio` d'un jeu.

Essai avec un vrai bouton et une vraie LED (câblage de la section « Câblage ») :

```bash
# Sur l'écran du Pi, ou en SSH vers sa session graphique Wayland :
./godot --path ~/projet-gpio --rendering-method gl_compatibility     res://banc/moniteur.tscn -- --exemple
```

`--exemple` règle le bouton sur GPIO 17 (broche 11, vers la masse, pull-up, actif bas,
anti-rebond 20 ms) et la LED sur GPIO 27 (broche 13, résistance de 330 Ω), et relie le
bouton à la LED. Sur Pi 4, Godot passe de lui-même en OpenGL ES ; `gl_compatibility`
est le moteur de rendu adapté au Pi.

Hors Raspberry Pi (Windows, CI), le banc ignore les tests matériel et se termine avec le
code 0 : la CI le lance ainsi à chaque push pour vérifier qu'il ne plante pas.

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
# Échantillonnage (robuste aux parasites) : 20 ms de stabilité, actif bas.
var bouton: GpioLine = chip.request_input_sampled(17, GpioChip.BIAS_PULL_UP, 20000, true)
# Ou fronts du noyau : chip.request_input(17, GpioChip.BIAS_PULL_UP, 20000, GpioChip.EDGE_BOTH, true)
bouton.edge_detected.connect(func(rising: bool, timestamp_ns: int) -> void: print(rising))
var led: GpioLine = chip.request_output(27, false)
led.set_value(true)
```

- `GpioChip` : `list_chips()` (statique), `is_supported()` (statique), `open(chip)`,
  `close()`, `get_label()`, `get_path()`, `get_line_count()`, `get_line_info(offset)`,
  `find_line("GPIO17")`, `request_input(...)`,
  `request_input_sampled(offset, bias, debounce_us, active_low, consumer, period_us)`,
  `request_output(...)`, `get_last_error()`.
- `GpioLine` : `get_value()` (0, 1 ou -1 en erreur ; valeur validée en mode
  échantillonné), `set_value(bool)`, `is_sampled()`, `release()`,
  signaux `edge_detected(rising, timestamp_ns)` et `line_error(message)`.

La ligne reste réservée tant que l'objet `GpioLine` existe ; `release()` (ou sa
destruction) arrête le thread (fronts ou échantillonnage) et ferme le descripteur.
En mode échantillonné, l'horodatage de `edge_detected` est l'instant de validation
(horloge monotone), pas celui du front électrique.

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

Le job « paquet » dépend du stockage d'artefacts GitHub : si son quota est plein (dépôt
privé), il échoue (les compilations et les tests, eux, n'en dépendent pas).

### Publier une release

Un tag `vX.Y.Z` poussé sur GitHub déclenche, après le lint, les compilations, les tests
et le paquet, la création d'une release avec :

- `godot-gpio-X.Y.Z.zip` : `addons/gpio/` avec les quatre bibliothèques (le job échoue
  s'il en manque une) et le README ;
- `projet-gpio-X.Y.Z.zip` : le projet d'exemple et le banc de test, à copier sur le Pi ;
- `SHA256SUMS.txt`, et des notes générées à partir des commits.

Le tag doit correspondre à la version de `project/addons/gpio/plugin.cfg`, sinon la
release est refusée. Une version avec suffixe (`1.1.0-rc1`) est publiée en préversion.

```sh
# 1. Mettre à jour version="1.1.0" dans project/addons/gpio/plugin.cfg, commiter, pousser.
# 2. Taguer ce commit et pousser le tag :
git tag -a v1.1.0 -m "godot-gpio 1.1.0"
git push origin v1.1.0
```

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
godot --headless --path project res://banc/test_materiel.tscn      # matériel ignoré hors Pi
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

Testé **sur un vrai Raspberry Pi 4** (Model B Rev 1.1, Ubuntu 26.04, noyau 7.0, Godot
4.7.2 arm64, bibliothèque debug), avec le banc de test : **89 OK, 0 KO**.

- puce `pinctrl-bcm2711` ouverte par label, nom, chemin et numéro ; `find_line()` ;
- écriture et relecture, valeur initiale, actif bas (entrée et sortie), drain ouvert,
  source ouverte, pull-up et pull-down ;
- fronts dans l'ordre et horodatés, filtres montant / descendant / aucun ; latence
  écriture -> signal Godot de 0,46 ms en moyenne, 6,9 ms au pire ;
- anti-rebond du noyau (rafales filtrées, changements lents transmis) ;
- anti-rebond par échantillonnage : validation en 10,6 ms pour 10 ms demandés,
  rafales filtrées, 300 ms d'impulsions parasites ignorées ; relâchement noyé dans
  ces parasites validé en 13 ms (311 ms avec l'anti-rebond du noyau) ; confirmé à la
  main avec un vrai bouton au bout de câbles longs ;
- 100 réservations avec thread sans fuite de descripteurs ni de threads, ligne détruite
  avec des fronts en attente, fermeture de Godot avec des lignes réservées ;
- autoload `Gpio` sur le matériel : actions, `pulse` (199 ms mesurées pour 200),
  `blink`, broche en double isolée, `shutdown()` ;
- erreurs réelles : EBUSY, ligne hors limites, puce inaccessible (EACCES).

Testé aussi :

- gdlint et gdformat (gdtoolkit 4.5.0) : aucun problème ;
- test headless du projet d'exemple et banc sous Godot 4.7.2 **Windows** (extension
  absente, mode simulation) et **Linux x86_64** en CI (extension chargée, builds gcc et
  zig, sans puce) ;
- compilation des quatre variantes (x86_64 / arm64, debug / release), en local depuis
  Windows avec zig et en CI.

**Pas encore testé** :

- **Raspberry Pi 5** (puce `pinctrl-rp1`) et Raspberry Pi OS ;
- bibliothèques **release** (il faut exporter le jeu avec les modèles d'export) ;
- le conseil « ajouter au groupe » du message d'accès refusé (l'utilisateur du Pi de test
  était déjà dans le groupe `gpio`) ;
- composants réels : bouton avec rebonds mécaniques, LED, module relais, longs fils.

