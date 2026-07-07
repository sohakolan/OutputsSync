# Mode réseau local (room bidirectionnelle)

Étend le fan-out d'OutputsSync au-delà de la machine : plusieurs Mac forment un
**salon** (nom + **code PIN**) sur le LAN. L'UI présente un modèle **source →
enceintes** : le **créateur du salon est la source** (il capte son son système via
le driver loopback et le met), les autres Mac sont des **enceintes** qui le jouent
localement — le tout **synchronisé** grâce à une **horloge commune**. Le transport
sous-jacent reste un maillage pair-à-pair (une connexion par paire).

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

## Destinations unifiées (côté source)

Pour la **source**, l'UI présente **une seule liste d'enceintes** = mes sorties
locales + les Mac du salon. Cocher une enceinte y envoie mon son :
- **sortie locale** → fan-out local (moteur `SyncEngine`) ;
- **Mac distant** → `requestPlay` : le Mac ouvre un récepteur sur **sa propre**
  sortie et me renvoie un `subscribe` ; je lui diffuse mon son, aligné par
  l'horloge commune. Le volume/délai que je règle pour lui est envoyé via
  `streamSettings` et appliqué **chez lui**.

Une **enceinte** (invité) n'a qu'un seul réglage : **sur quelle sortie locale**
jouer le son de la source (déplacement à chaud via `setListenOutput`).

## Re-synchronisation (`resync`)

Le bouton **Sync** re-prime chaque chemin audio pour le re-verrouiller sur
l'horloge commune : la source renvoie `stopPlay`+`requestPlay` à chaque enceinte
distante (elle recrée un flux neuf), et une enceinte re-prime son propre
`PlayoutBuffer`. Utile après une dérive, un rebranchement ou un changement de
sortie. Aucun état d'horloge n'est remis à zéro — seul le playout est ré-ancré.

## Rôles

- **Créer** un salon → tu es la **source** et le **maître d'horloge** (`master=1`).
  **PIN optionnel** : sans PIN (`pin=0`), le salon est ouvert ; le handshake exige
  alors un PIN vide.
- **Rejoindre** (depuis la liste du lobby) → tu deviens une **enceinte** : tu te
  connectes aux peers (PIN si requis), tu synchronises ton horloge sur la source,
  et tu joues son son sur ta sortie locale quand elle t'ajoute.
- Une enceinte **n'a pas besoin du driver loopback** ; seule la **source** en a
  besoin (pour capter son son système). Le transport reste bidirectionnel
  (`toggleListen` existe encore côté moteur), mais l'UI n'expose que le modèle
  source → enceintes.

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
| `UI/RoomView.swift` | UX source → enceintes : lobby/PIN, liste d'enceintes (source), sortie d'écoute (invité), bouton Sync |

## Permissions (macOS 15+)

`Info.plist` : `NSLocalNetworkUsageDescription` + `NSBonjourServices`
(`_outputssync._tcp`). Première utilisation → prompt système « réseau local ».
