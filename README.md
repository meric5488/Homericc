# Homericc

Application Mac (SwiftUI, macOS 26+) pour piloter son serveur multimédia auto-hébergé, chez soi comme à l'extérieur.
Les services se configurent dans **Réglages** (⌘,).

## Services pris en charge

| Service | Ce que fait Homericc |
|---|---|
| Recherche | Un seul champ pour films, séries, artistes et albums : ajout direct ou demande via Seerr |
| Calendrier | Sorties à venir : épisodes (Sonarr), films (Radarr), albums (Lidarr), demandes Seerr |
| Barre des menus | Résumé (vitesses, téléchargements, demandes, lectures), notifications, icône du Dock facultative |
| Radarr, Sonarr, Lidarr | Bibliothèque (tri, filtres), ajout depuis la recherche, surveillance, recherche manuelle, suppression |
| Seerr | Demandes en attente (approuver / refuser), recherche et nouvelles demandes |
| Prowlarr | État des indexeurs, test, recherche de releases et envoi au client |
| qBittorrent | Tableau triable (taille, ratio en vert au-delà de 20, date…), sélection multiple pour reprendre, mettre en pause ou supprimer |
| Plex | Bibliothèques, « À suivre », fiches avec saisons et épisodes, **lecture intégrée** (reprise, progression renvoyée à Plex), lectures en cours |
| Résumés | En français : TMDB via Seerr, ou traduction sur l'appareil |

Chaque service a une **adresse locale** (essayée en premier, délai court) et une **adresse distante**
(domaine, reverse proxy, Tailscale) utilisée quand la première ne répond pas. Le choix est oublié à chaque
changement de réseau. Les clés API, jetons et mots de passe sont rangés dans le trousseau du Mac.

## Compiler

Prérequis : Xcode 26 ou plus récent et [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
./build.sh              # compile
INSTALL=1 ./build.sh    # compile, installe dans /Applications et relance
```

Sans certificat, l'app est signée ad hoc et macOS redemande l'accès au trousseau après chaque mise à jour.
Pour l'éviter, crée une fois un certificat local : `./scripts/setup-signing.sh` (demande ton mot de passe).

Le projet Xcode est généré depuis `project.yml` et n'est pas versionné.
