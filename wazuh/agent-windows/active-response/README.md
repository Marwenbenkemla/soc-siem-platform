# Réponse active : isolation réseau d'un hôte Windows

`isolate-host.cmd` est le point d'entrée appelé par Wazuh ; il lance `isolate-host.ps1`, qui isole la machine
avec le pare-feu Windows. Appelé par Shuffle (nœud `wazuh_isolate_host`) lors d'une alerte ransomware.

## Fonctionnement

- Deux règles de blocage sont créées : `WazuhIsolation_In` et `WazuhIsolation_Out`. Elles bloquent tout le trafic
  sauf l'adresse du manager Wazuh (`$AllowedIPs` en tête du script, `192.168.30.10` dans le lab), qui reste joignable.
- **Isoler** : commande de réponse active `add` (appel API avec `"command": "!isolate-host.cmd"`).
- **Lever l'isolation** : commande `delete`, ou argument `release` dans `arguments` de l'appel API.
- Tout est journalisé dans `C:\Program Files (x86)\ossec-agent\active-response\active-responses.log`.

## Installation sur l'agent Windows

1. Copier les deux fichiers dans `C:\Program Files (x86)\ossec-agent\active-response\bin\`.
2. Adapter `$AllowedIPs` (et `$LogFile` si besoin) en tête de `isolate-host.ps1`.
3. Côté manager, la commande `isolate-host.cmd` doit être déclarée dans `ossec.conf` (`<command>`)
   et l'API Wazuh doit autoriser l'appel `PUT /active-response`.
4. Test depuis le manager ou l'API, puis vérification des deux règles dans le pare-feu Windows Defender.

Pour lever l'isolation à la main, supprimer les règles : `netsh advfirewall firewall delete rule name=WazuhIsolation_In`
et `name=WazuhIsolation_Out`.
