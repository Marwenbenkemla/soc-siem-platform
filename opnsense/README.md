# OPNsense : pare-feu, segmentation et IDS Suricata

OPNsense 26.1.6 assure le routage, le filtrage entre les zones (LAN, DMZ, SOC) et la détection
d'intrusion avec Suricata. Il alimente Wazuh avec les alertes Suricata et reçoit de Shuffle
les adresses IP à bloquer.

Le fichier [`config-OPNsense-public-clean.xml`](config-OPNsense-public-clean.xml) est un export
de la configuration réelle du lab. Les valeurs sensibles (mots de passe, clés API, certificat,
adresses IP) y sont remplacées par `[REDACTED]` : **il sert de référence et ne peut pas être
importé tel quel**. Ce document en reprend les réglages utiles.

## 1. Interfaces

À configurer dans **Interfaces > Assignments**. L'ordre des adaptateurs VirtualBox doit
correspondre (voir [`../docs/architecture.md`](../docs/architecture.md)).

| Rôle | Interface | Zone | Adresse OPNsense | Remarque |
|---|---|---|---|---|
| WAN | em0 | NAT VirtualBox | DHCP (10.0.2.15/24) | « Block private networks » et « Block bogon networks » activés |
| LAN | em1 | Systèmes supervisés | 192.168.20.1/24 | |
| OPT1 | em2 | DMZ (réservée) | 192.168.10.1/24 | Activée, aucune règle |
| OPT2 | em3 | SOC | 192.168.30.1/24 | |

Si ton WAN se trouve derrière un autre routeur (adresse privée), désactive
« Block private networks » sur le WAN.

Le NAT sortant est en mode automatique. Le DHCP est assuré par dnsmasq sur LAN, OPT1 et OPT2
(plages à adapter), et le DNS par Unbound.

## 2. Règles de pare-feu

OPNsense évalue les règles dans l'ordre et applique la première qui correspond (option
« quick »). Le blocage doit donc être placé **avant** la règle d'autorisation.

| Interface | Ordre | Action | Source | Destination |
|---|---|---|---|---|
| LAN | 1 | Pass | réseau LAN | any |
| OPT2 (SOC) | 1 | **Block** | alias `soc_blocklist` | any |
| OPT2 (SOC) | 2 | Pass | réseau OPT2 | any |
| WAN, OPT1 | | aucune règle | | tout le trafic entrant est refusé par défaut |

Le blocage s'applique à l'entrée de l'interface OPT2, car c'est là que se trouve la machine
d'attaque du lab. Pour bloquer aussi des adresses venant du LAN ou du WAN, ajoute la même règle
sur ces interfaces.

## 3. Alias `soc_blocklist`

Dans **Firewall > Aliases**, crée un alias :

| Champ | Valeur |
|---|---|
| Name | `soc_blocklist` |
| Type | Host(s) |
| Content | vide |
| Enabled | oui |

L'alias reste vide : c'est Shuffle qui y ajoute les adresses à bloquer, via l'API (voir
section 4).

## 4. Utilisateur et API pour Shuffle

1. Dans **System > Access > Users**, crée un utilisateur dédié (le lab utilise `shuffle`).
2. Génère-lui une clé API (icône clé de la liste des utilisateurs) : OPNsense télécharge un
   fichier contenant `key` et `secret`.
3. Dans Shuffle, enregistre ces deux valeurs comme variables secrètes. Elles ne doivent
   jamais apparaître dans un fichier du dépôt : utilise `<OPNSENSE_API_KEY>` et
   `<OPNSENSE_API_SECRET>`.

Le workflow Shuffle fait deux appels `POST` : le premier ajoute l'adresse à l'alias, le second
recharge les alias pour que le blocage soit appliqué immédiatement. Dans le lab, `OPNSENSE_URL`
vaut `http://192.168.30.1` (adresse d'OPNsense dans la zone SOC).

```
# 1. Bloquer une IP
curl -k -u "<OPNSENSE_API_KEY>:<OPNSENSE_API_SECRET>" -X POST \
  -H "Content-Type: application/json" -d '{"address":"203.0.113.10"}' \
  $OPNSENSE_URL/api/firewall/alias_util/add/soc_blocklist

# 2. Appliquer la configuration
curl -k -u "<OPNSENSE_API_KEY>:<OPNSENSE_API_SECRET>" -X POST \
  $OPNSENSE_URL/api/firewall/alias/reconfigure

# Débloquer une IP
curl -k -u "<OPNSENSE_API_KEY>:<OPNSENSE_API_SECRET>" -X POST \
  -H "Content-Type: application/json" -d '{"address":"203.0.113.10"}' \
  $OPNSENSE_URL/api/firewall/alias_util/delete/soc_blocklist
```

## 5. Suricata (IDS)

À configurer dans **Services > Intrusion Detection > Administration**.

| Paramètre | Valeur |
|---|---|
| Enabled | oui |
| Capture mode | PCAP live mode (IDS) : détection seule, Suricata ne bloque rien |
| Pattern matcher | Default |
| Interfaces | LAN et WAN |
| Promiscuous mode | non |
| Home networks | tes sous-réseaux internes |
| EVE syslog output | facultatif : Wazuh lit directement le fichier `eve.json` |
| Syslog alerts | désactivé |
| Log payload | désactivé |
| Rotation des journaux d'alertes | hebdomadaire, 4 fichiers conservés |

Suricata écrit ses alertes dans `/var/log/suricata/eve.json`. L'agent Wazuh d'OPNsense lit ce
fichier (voir section 6).

**Jeux de règles activés** (onglet *Download*) :

- abuse.ch : feodotracker, sslblacklist, sslipblacklist, threatfox, urlhaus
- Emerging Threats : attack_response, dns, dos, exploit, exploit_kit, ftp, hunting, icmp,
  icmp_info, ja3, malware, netbios, remote_access, rpc, scan, shellcode, snmp, sql,
  user_agents, web_client, web_server, web_specific_apps

**Règles activées individuellement** (action `alert`) : SID 2000005, 2000536, 2000537, 2000538,
2000540, 2000543, 2000544, 2000545, 2000546.

Une tâche planifiée `ids update` (mise à jour des règles) existe mais est désactivée dans le lab.
Active-la, ou lance la mise à jour à la main depuis l'onglet *Download*.

## 6. Agent Wazuh sur OPNsense

L'agent Wazuh d'OPNsense envoie les alertes de Suricata au Wazuh Manager (192.168.30.10, zone
SOC). La chaîne complète est : Suricata, `eve.json`, agent Wazuh, décodeur, Dashboard.

Prérequis : l'agent est installé sur OPNsense et enregistré auprès du manager (voir la
documentation Wazuh pour FreeBSD).

**1. Démarrage automatique de l'agent** (shell d'OPNsense) :

```
sysrc wazuh_agent_enable=YES
service wazuh-agent restart
service wazuh-agent status
```

Le statut doit afficher cinq modules `running` : `wazuh-modulesd`, `wazuh-logcollector`,
`wazuh-syscheckd`, `wazuh-agentd` et `wazuh-execd`. C'est `wazuh-logcollector` qui lit les
journaux locaux.

**2. Surveillance du journal de Suricata.** Dans le fichier `ossec.conf` de l'agent
(`/var/ossec/etc/ossec.conf`), ajoute ce bloc, puis relance l'agent avec
`service wazuh-agent restart` :

```
<localfile>
  <log_format>json</log_format>
  <location>/var/log/suricata/eve.json</location>
</localfile>
```

Aucun décodeur personnalisé n'est nécessaire : le décodeur JSON de Wazuh extrait tous les
champs (signature, IP source et destination, ports).

**3. Vérification.**

- Sur le manager, injecte une ligne EVE réelle dans `/var/ossec/bin/wazuh-logtest`. Le décodeur
  `json` doit s'appliquer et la règle **86601** (groupe `suricata`, niveau 3) doit se déclencher.
- Lance un scan Nmap depuis Kali vers le Windows Server. L'alerte « ET SCAN Possible Nmap
  User-Agent Observed » apparaît dans **Services > Intrusion Detection > Alerts** d'OPNsense, puis dans
  **Threat Hunting > Events** du Dashboard Wazuh, filtré sur l'agent OPNsense.

## 7. Points à durcir avant un déploiement réel

Le lab est volontairement simple. Pour un usage en entreprise :

- **Interface web en HTTPS.** Elle est en HTTP dans le lab (Shuffle appelle `http://192.168.30.1`) :
  la clé API circule alors en clair. Active HTTPS dans **System > Settings > Administration**.
- **Privilèges de l'utilisateur API.** Dans le lab, `shuffle` a tous les droits (`page-all`).
  Limite-le aux seuls droits nécessaires à la gestion des alias.
- **Règles trop larges.** LAN et SOC peuvent joindre n'importe quelle destination. Restreins
  les flux à ceux de la table « Flux principaux » de `architecture.md`.
- **SSH.** Il est activé pour le groupe `admins` : désactive-le s'il ne sert pas, ou limite-le
  à l'authentification par clé.
