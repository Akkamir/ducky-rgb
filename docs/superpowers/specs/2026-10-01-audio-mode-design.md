# Mode audio : égaliseur piloté par le son du système

Date : 2026-10-01. Statut : validé en conversation (silence = B, interaction avec les presets = B, approche 1).

## 1. Objectif

Un « Mode audio » dans l'application Ducky RGB : quand il est armé et que le Mac joue du son (casque compris),
le clavier affiche un égaliseur 15 bandes ; pendant les silences, le clavier revient à l'éclairage de repos (le
réglage sauvegardé). Le rendu est celui validé sur le clavier avec le prototype `experiments/audio` : eq-smooth,
5 palettes.

Critère de réussite : le user arme « Mode audio » dans le menu, lance de la musique, l'égaliseur s'affiche ; la
musique s'arrête, l'éclairage de repos revient au bout de 3 s ; il désarme le mode, l'éclairage de repos revient.

## 2. Comportement

- **Armé / désarmé** : interrupteur dans le menu de la barre des menus, mémorisé (réarmé au lancement suivant).
- **Silence** : son sous -80 dBFS (RMS) pendant 3 s -> fin du direct, retour à l'éclairage de repos. Le son revient ->
  égaliseur immédiatement.
- **Presets et modifications pendant le mode audio** : ils changent l'éclairage de repos (sauvegarde différée comme
  d'habitude). Pendant la musique, l'égaliseur reste par-dessus.
- **Éditeur** : tant que la fenêtre d'éditeur est la fenêtre active, le mode audio est en pause (l'éclairage de repos
  est visible pour éditer) ; il reprend quand elle ne l'est plus.
- **Palette** : classic, ocean, sunset, neon, fire ; choisie dans le menu, mémorisée.
- **Rien n'est écrit en flash** par le mode audio : les images passent par le mode hôte (commandes 0x02-0x03).
- **Quitter l'application** : fin du direct avant de quitter (le clavier revient à l'éclairage de repos).
- **Clavier débranché puis rebranché** : le direct reprend (le mode hôte est ré-activé à la première image).
- **Changement de sortie audio** (casque branché/débranché) : la capture est relancée sur la nouvelle sortie.
- **Autorisation refusée ou échec de capture** : état « Échec » avec le message, le mode reste désarmable.

## 3. Rendu (repris du prototype, validé sur le clavier)

- Analyse : fenêtre de 2048 échantillons (Hann), FFT, 15 bandes log de 40 Hz à 16 kHz, niveau en dB par bande,
  gain automatique (plafond = max des bandes, décroît de 0,15 dB par image), plage de 45 dB, lissage : montée
  immédiate, descente `0,85 * ancien + 0,15 * nouveau`.
- Égaliseur : colonne = bande selon la position physique de la touche ; hauteur = niveau * 5 rangées ; la LED du
  sommet s'allume partiellement (eq-smooth) ; couleur selon la rangée (palette, rangée du haut en premier).
- Palettes (haut -> bas) :
  classic `ff0000 ff7800 e6e600 50ff00 00ff3c`, ocean `f0faff 78ebff 00d2ff 0096ff 005aff`,
  sunset `ffeb78 ff9600 ff3c5a ff00b4 aa00ff`, neon `a0ffff ff78e6 ff00c8 8c00ff 006eff`,
  fire `fffadc ffe650 ffb400 ff6e00 ff2800`.
- Cadence : ~30 images/s (tick de 33 ms), une seule image en attente (les images en retard sont remplacées).

## 4. Architecture

Dans `DuckyCore` :

| Unité | Rôle |
|---|---|
| `SpectrumAnalyzer` | tampon circulaire thread-safe d'échantillons mono ; `analyze()` -> 15 niveaux lissés 0...1 + RMS en dB |
| `EqualiserPalette`, `EqualiserRenderer` | palettes ; niveaux + palette -> 68 couleurs (géométrie de `KeyboardLayout`) |
| `AudioCapture` (protocole), `SystemAudioTap` | capture du son système via tap Core Audio (macOS 14.2+), relance sur changement de sortie |
| `AudioMode` (`@MainActor @Observable`) | armé, pause, statut, palette ; tick 30 Hz : analyse -> image ou retour au repos |
| `LightingController` (ajouts) | `showLiveFrame(_:)` (mode hôte + image, coalescée, sans sauvegarde), `endLiveFrames()` ; le bandeau « CLI » ignore notre propre direct |
| `KeyboardClient` (ajout) | `sendHostFrame(_:)` : 68 couleurs en rapports de 9 |

Toutes les écritures HID passent par la file série du `LightingController` (le transport n'accepte pas d'échanges
concurrents).

Application : section « Mode audio » dans le menu (interrupteur, palette, statut) ; pause pendant que l'éditeur est la
fenêtre active ; fin du direct avant de quitter ; `NSAudioCaptureUsageDescription` dans l'Info.plist ; cible macOS
14.2.

## 5. Tests

- `SpectrumAnalyzer` : une sinusoïde de 1 kHz domine la bande qui contient 1 kHz ; le silence donne un RMS
  sous -80 dB ; après un son fort puis du silence, les niveaux décroissent progressivement.
- `EqualiserRenderer` : niveaux nuls -> tout noir ; niveaux pleins -> chaque touche à la couleur de sa rangée ;
  demi-hauteur -> rangées basses allumées, rangée à la limite partielle.
- `KeyboardClient.sendHostFrame` : 8 rapports de 9 LEDs max, couleurs reçues par le clavier simulé.
- `LightingController` : `showLiveFrame` active le mode hôte une fois puis envoie les images ; `endLiveFrames` le
  désactive ; aucune sauvegarde déclenchée ; le bandeau CLI reste faux pendant notre direct ; après reconnexion le
  mode hôte est ré-activé.
- `AudioMode` (fausse capture, horloge injectée) : son -> images ; 3 s de silence -> retour au repos ; pause ->
  retour au repos ; désarmer -> capture arrêtée et retour au repos ; échec de capture -> statut `failed`.
- Manuel sur le clavier : autorisation, musique au casque, silence, éditeur, quitter.
