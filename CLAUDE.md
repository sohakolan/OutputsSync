# CLAUDE.md — OutputsSync

Instructions spécifiques à ce projet. Se combinent avec les règles génériques du
`CLAUDE.md` parent (dossier `lab/`).

## Release = toujours aussi Homebrew

**À chaque release, mettre à jour le cask Homebrew — ce n'est pas optionnel.**

Une release n'est terminée que quand le tap est à jour et vérifié. Le flux complet :

1. Bump la version dans `scripts/bundle.sh` (`CFBundleVersion` + `CFBundleShortVersionString`).
2. Commit + push sur `main`.
3. `./scripts/bundle.sh` (build `.app`), puis construire `OutputsSync.dmg`
   (bundle renommé `OutputsSync.app` + symlink `/Applications`, volume `OutputsSync`).
4. `gh release create vX.Y.Z … OutputsSync.dmg` (Latest).
5. **Homebrew** — dans le tap `sohakolan/homebrew-outputssync`, bumper
   `Casks/outputssync.rb` : `version` + `sha256` du DMG publié (l'URL utilise
   `#{version}`), commit + push.
6. Vérifier : `brew fetch --cask sohakolan/outputssync/outputssync` (télécharge le
   DMG et valide le checksum). Sans cette étape, les utilisateurs `brew` restent
   bloqués sur l'ancienne version.

Détails/liens : voir la mémoire projet `outputssync-published-links`.
