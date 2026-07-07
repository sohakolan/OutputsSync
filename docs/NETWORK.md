# Mode réseau local (room bidirectionnelle)

Étend le fan-out d'OutputsSync au-delà de la machine : plusieurs Mac forment une
**room** (nom + **code PIN**) sur le LAN ; n'importe quel peer peut **émettre**
son son système (capté par le driver loopback) et **s'abonner** au flux d'un autre
peer pour le jouer localement — le tout **synchronisé** grâce à une **horloge
commune**.

```
   Mac A (émet + reçoit)                 Mac B (émet + reçoit)
   ┌───────────────────┐                 ┌───────────────────┐
   │ loopback ─▶ capture│──── UDP audio ─▶│ playout ─▶ sortie  │
   │ playout  ◀────────────── UDP audio ─│ capture ◀─ loopback │
   └───────────────────┘   Bonjour/mDNS  └───────────────────┘
                      TCP contrôle (PIN) + UDP horloge
```

## Synchronisation : deux couches

Pour que plusieurs Mac jouent **le même sample au même instant physique** :

1. **Horloge commune (offset).** Le **créateur de la room = maître d'horloge**.
   Protocole type NTP sur UDP (ping/pong horodatés, filtrage par RTT minimal) →
   chaque peer connaît son `offset` (heure-room − heure-locale), précision
   sub-ms sur LAN. L'émetteur horodate chaque paquet avec l'**heure-room de
   capture** ; le récepteur calcule un **instant de présentation = capture +
   délai de playout** et le convertit en heure locale pour programmer la sortie.
   Tous partagent le même instant de présentation → sorties alignées.

2. **Verrou anti-dérive (débit).** L'horloge du DAC n'avance pas exactement
   comme l'horloge CPU. Un **resampler** piloté par un contrôleur (DLL/PI) sur
   l'écart au timeline garde chaque sortie verrouillée sur la cible dans la durée.

Couche 1 = *où viser*, couche 2 = *comment tenir la cible*.

## Latence

Paquets courts (~2,7 ms, sous la MTU) + **délai de playout adaptatif** =
plancher + marge fonction du jitter mesuré. Objectif : ~30–80 ms un-sens sur LAN
calme, resserré automatiquement quand le réseau est stable.

## Codec

**PCM Float32 bit-perfect par défaut** : sur un LAN, c'est à la fois la meilleure
qualité (sans perte) et la latence la plus basse (zéro encodage). **Opus**
(profil basse latence) en option pour un Wi-Fi saturé.

## Canaux réseau

- **Bonjour** `_outputssync._tcp` : découverte, TXT = `room`, `peer` (UUID),
  `name`, `master` (0/1), `pin` (0/1 = room protégée), `clk` (port UDP horloge).
  Le **lobby** browse **toutes** les rooms (liste + nb de Mac + cadenas PIN) ;
  une fois dans une room, on filtre sur son nom pour le maillage.
- **TCP contrôle** (maillage complet, une connexion par paire) : handshake **PIN**,
  puis :
  - `subscribe`/`unsubscribe` (récepteur → émetteur) : « envoie-moi ton son sur ce port ».
  - `requestPlay`/`stopPlay` (émetteur → récepteur) : « joue mon son / arrête ».
  - `streamSettings` (émetteur → récepteur) : volume/délai de mon son chez lui.
- **UDP** : pings de synchro d'horloge (RTT-min) **et** paquets audio.

## Destinations unifiées

Dans une room, l'UI présente **une seule liste de destinations** = mes sorties
locales + les Mac de la room. Cocher une destination y envoie mon son :
- **sortie locale** → fan-out local (moteur `SyncEngine`) ;
- **Mac distant** → `requestPlay` : le Mac ouvre un récepteur sur **ses propres**
  sorties et me renvoie un `subscribe` ; je lui diffuse mon son, aligné par
  l'horloge commune. Le volume/délai que je règle pour lui est envoyé via
  `streamSettings` et appliqué **chez lui**.

Le bouton casque d'une ligne Mac fait l'inverse : j'**écoute** son son (il sort
sur ma sortie locale choisie).

## Rôles

- **Créer** une room → tu deviens **maître d'horloge** (`master=1`). **PIN
  optionnel** : sans PIN (`pin=0`), la room est ouverte ; le handshake exige
  alors un PIN vide.
- **Rejoindre** (depuis la liste du lobby) → tu te connectes aux peers de la room
  (PIN si requis), tu synchronises ton horloge sur le maître, tu peux émettre
  vers et/ou écouter n'importe quel peer.
- Un Mac qui **écoute / reçoit seulement n'a pas besoin du driver loopback** ;
  seul un Mac qui **émet** en a besoin (pour capter son son système).

## Discipline temps-réel

Aucun IOProc audio ne fait d'alloc / lock / syscall :
- **Émission** : l'IOProc de capture copie dans un **ring SPSC lock-free** ; un
  thread réseau draine et fait `NWConnection.send`.
- **Réception** : la queue réseau écrit dans le **PlayoutBuffer** préalloué ;
  l'IOProc de sortie lit + resample. Jamais de réseau dans le thread audio.

## Modules

| Fichier | Rôle |
|---|---|
| `Network/AudioPacket.swift` | Entête (seq, heure-room capture) + payload PCM |
| `Network/AtomicScalars.swift` | Scalaires partagés lock-free (offset, playRate…) |
| `Network/ClockSync.swift` | NTP-like UDP : offset maître/client, mapping horloge-room |
| `Network/RoomDiscovery.swift` | Bonjour advertise + browse, filtrage room |
| `Network/ControlChannel.swift` | TCP : PIN, capacités, subscribe, teardown |
| `Network/NetworkSource.swift` | Capture loopback → horodatage → send |
| `Network/PlayoutBuffer.swift` | Buffer par instant de présentation + resampler DLL |
| `Network/NetworkSink.swift` | `NetworkStream` (réception+playout) + `OutputMixer` (1 IOProc/sortie, mixe les flux) |
| `Network/RoomManager.swift` | `@MainActor`, orchestration + état publié |
| `Network/NetTest.swift` | Vérif headless (`--nettest`) : horloge, PIN, Bonjour, paquet, playout |
| `UI/RoomView.swift` | Liste peers, PIN, toggles émettre/écouter, volume/délai |

## Permissions (macOS 15+)

`Info.plist` : `NSLocalNetworkUsageDescription` + `NSBonjourServices`
(`_outputssync._tcp`). Première utilisation → prompt système « réseau local ».
