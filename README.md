# Homericc

Application iPhone et iPad (SwiftUI, iOS 26+) pour piloter son serveur multimédia auto-hébergé, chez soi comme à l'extérieur.

## Services pris en charge

| Service | Ce que fait Homericc |
|---|---|
| Radarr, Sonarr, Lidarr | Bibliothèque (tri, filtres), ajout depuis la recherche, surveillance, recherche manuelle, suppression |
| Seerr | Demandes en attente (approuver / refuser), recherche et nouvelles demandes |
| Prowlarr | État des indexeurs, test, recherche de releases et envoi au client |
| qBittorrent | Torrents en direct, vitesses, pause / reprise, suppression |
| Plex | Lectures en cours, ajouts récents |

Chaque service a une **adresse locale** (essayée en premier, délai court) et une **adresse distante**
(domaine, reverse proxy, Tailscale) utilisée quand la première ne répond pas. Le choix est oublié à chaque
changement de réseau. Les clés API, jetons et mots de passe sont rangés dans le trousseau.

## Compiler

Prérequis : Xcode 26 ou plus récent et [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
open Homericc.xcodeproj
```

Le projet Xcode est généré depuis `project.yml` et n'est pas versionné.
