# build/ — source + CI du tweak cherrytouch

Ce dossier contient la source du tweak et la CI qui le compile et le publie dans
le dépôt Sileo (racine de ce repo, servi par GitHub Pages sur
`https://cherrymodelsxa.github.io/cherry-repo/`).

## Contenu
- `cherrytouch-tweak.m` — source du tweak (dylib injectée dans backboardd par ElleKit).
- `cherrytouch.plist` — filtre ElleKit (n'injecte que dans `backboardd`).
- `control` — métadonnées du paquet. **Bumper `Version:` à chaque changement.**
- `mkrepo.py` — régénère `Packages` / `Packages.gz` / `Release` (miroir de l'outil local `repo_regen.py`).
- `.gitignore` — ignore les sorties de build (`pkg/`, `*.dylib`, `cherrytouch.deb`).

## Rebuild + publication (GitHub Actions macOS, pas besoin de Mac ni de Theos)
Le workflow `.github/workflows/build-cherrytouch.yml` reproduit le build on-device
éprouvé (`clang -dynamiclib -arch arm64` + frameworks + `ldid -S`, empaqueté dans
`/var/jb/usr/lib/TweakInject/`), en cross-compilation sur un runner macOS
(la seule différence est `-Wl,-undefined,dynamic_lookup`, car le SDK public est
fait de stubs sans les symboles privés — ils se résolvent à l'exécution dans
backboardd, comme sur l'appareil).

Pour mettre à jour le tweak :
1. Reporte la nouvelle source depuis Orqestra :
   `cp <orqestra>/cherry/device-daemon/cherrytouch-tweak.m build/cherrytouch-tweak.m`
   (le fichier de référence reste dans le repo Orqestra).
2. Incrémente `Version:` dans `build/control` (ex. 1.0.4 -> 1.0.5).
3. Commit + push sur `main` (ça ne déclenche RIEN tout seul : le workflow est manuel).
4. GitHub > Actions > **Build and publish cherrytouch** > **Run workflow** :
   - `publish = false` : build seul + artefact `.deb` à télécharger et inspecter.
   - `publish = true` : publie dans le dépôt Sileo (commit du `.deb` + index).

## Après publication : TESTER SUR UN SEUL IPHONE d'abord
Publier ne met rien à jour tout seul (Sileo est opt-in par appareil). Sur UN iPhone :
Sileo > Sources > rafraîchir > cherrytouch > Mettre à jour > **Respring**. Vérifie
que le pilotage, l'écran et la nouvelle fonction marchent, PUIS déploie à l'équipe.
Un `.deb` cassé peut mettre backboardd en boucle de respring : ne jamais pousser à
toute la flotte sans avoir validé un appareil.
