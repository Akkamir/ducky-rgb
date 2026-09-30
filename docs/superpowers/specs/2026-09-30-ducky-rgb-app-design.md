# Ducky RGB v1 : application macOS + réglage persistant

Date : 2026-09-30. Statut : validé en conversation (sections 1 à 3), spec rédigée en autonomie sur délégation du user.

## 1. Objectif

Une application macOS native pour gérer l'éclairage du Ducky One 2 SF (DKON1967ST, ISO) flashé avec le firmware
QMK `hostrgb` : choisir et régler des effets, peindre des couleurs par touche, gérer une bibliothèque de presets.
Le réglage appliqué est stocké dans le clavier et survit à un débranchement, application fermée.

Critère de réussite : le user choisit un preset ou peint des touches dans l'application, quitte l'application,
débranche et rebranche le clavier ; le clavier affiche exactement le même éclairage.

Hors périmètre v1 : usages dynamiques pilotés par le Mac (texte défilant, statut des agents : restent dans la CLI),
emplacements multiples dans le clavier, layout ANSI, distribution signée Developer ID, simulation des animations
dans l'application.

## 2. Modèle de réglage (stocké dans le clavier)

Deux couches, plus une couche temporaire au-dessus :

1. **Mode hôte** (existant, protocole v1) : couleurs envoyées en continu par la CLI. Jamais sauvegardé. Prioritaire.
2. **Couche personnalisée** : pour chacune des 68 LEDs, une couleur RGB optionnelle. Une LED personnalisée affiche sa
   couleur, les autres laissent voir le fond.
3. **Fond** : un effet rgb_matrix de QMK avec teinte, saturation, luminosité (val), vitesse, allumé/éteint.

La luminosité (val) du fond s'applique aussi à la couche personnalisée : `couleur * val / 255`.
Fond éteint : les LEDs non personnalisées sont noires ; la couche personnalisée reste affichée.
Un preset « disposition fixe » = fond éteint + couche couvrant toutes les touches.

Stockage :
- fond : `rgb_matrix_config` natif QMK (eeconfig) ;
- couche : bloc de données utilisateur QMK (`EECONFIG_USER_DATA_SIZE`), format :
  `version (1) | masque 68 bits (9 octets) | 68 x RGB (204 octets) | somme (2)` = 216 octets.
  La somme est la somme 16 bits des octets précédents. Version ou somme invalide au démarrage : couche vide.
- backend : `EEPROM_DRIVER = wear_leveling`, `WEAR_LEVELING_DRIVER = embedded_flash`, EFL ChibiOS sur l'APROM de la
  NUC123 (secteurs de 512 o, écriture 4 o, déjà prévue par QMK pour la famille NUC123). Zone réservée : les derniers
  secteurs de l'APROM (taille de backing 2 Ko par défaut ; le firmware fait ~33 Ko sur 68 Ko). LDROM et CONFIG restent
  inaccessibles au driver (`NUC123_EFL_ACCESS_LDROM/CONFIG = FALSE`) : le bootloader ne peut pas être touché.

Effets inclus, avec identifiants stables exposés par le protocole (indépendants de l'énumération QMK) :

| Id | Effet QMK | Id | Effet QMK |
|---|---|---|---|
| 1 | SOLID_COLOR | 8 | PIXEL_RAIN |
| 2 | BREATHING | 9 | DIGITAL_RAIN (framebuffer) |
| 3 | GRADIENT_LEFT_RIGHT | 10 | SOLID_REACTIVE_SIMPLE (frappe) |
| 4 | CYCLE_ALL | 11 | SPLASH (frappe) |
| 5 | CYCLE_LEFT_RIGHT | 12 | MULTISPLASH (frappe) |
| 6 | RAINBOW_MOVING_CHEVRON | 13 | TYPING_HEATMAP (framebuffer + frappe) |
| 7 | HUE_WAVE | 14 | BAND_SAT |

## 3. Protocole raw HID v2

Paquets de 32 octets, usage page `0xFF60`, usage `0x61`. Requête : octet 0 = commande, arguments dès l'octet 1.
Réponse : octet 0 = commande, octet 1 = statut, charge utile dès l'octet 2.
Statuts : `0` OK, `1` commande inconnue, `2` argument invalide, `3` échec d'écriture flash.
Les commandes v1 (`0x01` à `0x04`) sont inchangées ; `PING` renvoie maintenant la version 2.

| Cmd | Nom | Requête | Réponse (charge utile) |
|---|---|---|---|
| 0x01 | PING | — | version, nb LEDs |
| 0x02 | MODE (hôte) | on | — |
| 0x03 | SET (hôte) | first, count≤9, RGB… | — |
| 0x04 | FILL (hôte) | R, G, B | — |
| 0x10 | GET_INFO | — | version, nb LEDs, nb effets, persistance (1/0) |
| 0x11 | GET_EFFECTS | first | first, count≤28, ids… |
| 0x12 | GET_STATE | — | enabled, effect_id, h, s, v, speed, host_mode, nb LEDs perso, dirty |
| 0x13 | SET_BASE | enabled, effect_id, h, s, v, speed | — |
| 0x14 | GET_OVERLAY | first | first, count≤7, (flags, R, G, B)… |
| 0x15 | SET_OVERLAY | first, count≤7, (flags, R, G, B)… | — |
| 0x16 | CLEAR_OVERLAY | — | — |
| 0x17 | SAVE | — | — |

`flags` bit 0 = LED personnalisée. `SET_BASE`, `SET_OVERLAY`, `CLEAR_OVERLAY` s'appliquent en RAM (fonctions
`*_noeeprom`) et positionnent `dirty` ; `SAVE` écrit le fond (`eeconfig_update_rgb_matrix`) et la couche
(`eeconfig_update_user_datablock`), puis remet `dirty` à 0. Les touches Fn d'éclairage (`RM_*`) sauvegardent le fond
nativement. `v` est plafonnée par `RGB_MATRIX_MAXIMUM_BRIGHTNESS` (200).

## 4. Application « Ducky RGB »

SwiftUI natif, macOS 14+, construite avec Swift Package Manager et empaquetée en `.app` par un script
(`app/scripts/bundle.sh`, signature ad hoc). Emplacement : `app/` dans le dépôt.

### Unités

| Unité | Cible | Rôle |
|---|---|---|
| `DuckyProtocol` | `DuckyCore` | Construction et décodage des paquets (fonctions pures) |
| `HIDTransport` (protocole Swift) + `IOKitHIDTransport` | `DuckyCore` | Connexion IOHIDManager (VID `445B`, PID `07AE`, usage page `FF60`), envoi/réception avec délai, réponses périmées ignorées, branchement/débranchement |
| `KeyboardClient` | `DuckyCore` | API métier au-dessus du transport : `info()`, `state()`, `setBase()`, `overlay()`, `setOverlay()`, `save()` |
| `KeyboardLayout` | `DuckyCore` | 68 touches : rectangle physique, légende AZERTY, index de LED |
| `Preset`, `PresetStore` | `DuckyCore` | Modèle `Codable` + stockage JSON dans `~/Library/Application Support/Ducky RGB/presets.json`, presets fournis |
| `LightingController` | `DuckyCore` | État observable : connexion, réglage courant, application en direct, sauvegarde automatique 2 s après la dernière modification, erreurs |
| Vues | `DuckyRGB` (exécutable) | Menu barre des menus, fenêtre (éditeur, presets, réglages) |

`LightingController` dépend de `HIDTransport` (protocole) : testable avec un faux transport.

### Barre des menus (`MenuBarExtra`, style fenêtre)
En-tête avec l'état (connecté · enregistré / modifications en cours / non détecté / firmware v1 à mettre à jour),
liste des presets (actif coché, clic = appliquer), interrupteur allumé/éteint, curseurs luminosité et vitesse,
sélecteur d'effet, « Ouvrir l'éditeur… », « Réglages… », « Quitter ».

### Fenêtre (barre latérale)
1. **Éditeur** : clavier dessiné à l'échelle avec légendes AZERTY et couleur affichée de chaque touche ; réglages du
   fond (effet, couleur, vitesse, luminosité, allumé) ; outils de couche (pinceau avec couleur, gomme, tout remplir,
   tout effacer ; clic ou glisser) ; « Enregistrer comme preset… ».
2. **Presets** : vignettes avec mini clavier ; presets fournis (Arc-en-ciel, Respiration blanche, Nuit rouge doux,
   Jeu ZQSD, Focus) et presets du user : appliquer, renommer, dupliquer, supprimer.
3. **Réglages** : lancement à l'ouverture de session (`SMAppService`), icône dans le Dock (politique d'activation),
   informations firmware.

### Comportements
- Chaque modification est envoyée immédiatement au clavier ; `SAVE` part 2 s après la dernière modification.
- Appliquer un preset : `SET_BASE`, puis `CLEAR_OVERLAY` + `SET_OVERLAY` des LEDs personnalisées, puis sauvegarde
  différée.
- À la connexion et à l'ouverture du menu ou de la fenêtre : `GET_STATE` + `GET_OVERLAY` pour se resynchroniser.
- Clavier absent : édition des presets possible, application désactivée.
- Firmware v1 : bannière « firmware à mettre à jour », contrôles désactivés.
- Mode hôte actif (CLI) : bannière « Contrôlé par la CLI » avec un bouton qui envoie `MODE 0`.
- Erreurs de statut : affichées dans l'en-tête, jamais silencieuses.

## 5. Risques

- **Wear leveling jamais utilisé sur NUC123 dans QMK** (aucun clavier NUC123 ne l'active). À valider sur le clavier :
  sauvegarde, débranchement, relecture. Repli : si l'écriture échoue, le statut `3` remonte et le clavier continue
  de fonctionner en RAM.
- Pendant un effacement de secteur, le CPU est suspendu : un bref gel de l'éclairage au moment d'une sauvegarde est
  possible (acceptable).
- Le driver EFL applique le masque AHBCLK `ISP_EN` (bit 2) au registre APBCLK, où le bit 2 est `TMR0_EN` : chaque arrêt
  du driver (fin de chaque écriture EEPROM) coupe l'horloge de TIMER0. Le rafraîchissement des LEDs utilise donc TIMER1.
  L'horloge ISP elle-même est active par défaut au reset (à confirmer sur le matériel).
- Flasher le firmware v2 nécessite le user (touche D au branchement).

## 6. Tests

- `swift test` : encodage/décodage de chaque commande, `PresetStore` (aller-retour JSON), `LightingController` avec
  faux transport (application en direct, sauvegarde différée unique après rafale, resynchronisation, erreurs).
- Firmware : compilation, taille, symboles ; commandes v2 testées d'abord avec la CLI Python étendue.
- Sur le clavier (au retour du user) : GET_INFO, effets un par un, couche, SAVE, débranchement/rebranchement
  application fermée ; puis l'application de bout en bout.
