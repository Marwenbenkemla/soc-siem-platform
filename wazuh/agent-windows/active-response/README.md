# Réponse active : isolation réseau d'un hôte Windows

`isolate-host.cmd` est le point d'entrée appelé par Wazuh ; il lance `isolate-host.ps1` (même dossier), qui isole
la machine avec le pare-feu Windows. Il est appelé par Shuffle (nœud `wazuh_isolate_host`) lors d'une alerte ransomware.

## Fonctionnement

- Deux règles de blocage sont créées : `WazuhIsolation_In` et `WazuhIsolation_Out`. Elles bloquent tout le trafic
  sauf l'adresse du manager Wazuh (`$AllowedIPs` en tête du script, `192.168.30.10` dans le lab), qui reste joignable
  pour garder le contrôle à distance de la machine.
- **Isoler** : commande de réponse active `add` (cas normal d'un appel API avec `"command": "!isolate-host.cmd"`).
- **Lever l'isolation** : commande `delete`, ou argument `release` dans `arguments` de l'appel API.
- Tout est journalisé dans `C:\Program Files (x86)\ossec-agent\active-response\active-responses.log`.

## Installation sur l'agent Windows

1. Copier les deux fichiers dans `C:\Program Files (x86)\ossec-agent\active-response\bin\`.
2. Adapter `$AllowedIPs` (et `$LogFile` si besoin) en tête de `isolate-host.ps1`.
3. Aucune déclaration `<command>` n'est nécessaire dans le `ossec.conf` du manager : le préfixe `!` de
   `"command": "!isolate-host.cmd"` demande à Wazuh d'exécuter directement le script présent dans
   `active-response\bin` de l'agent. L'utilisateur de l'API Wazuh doit en revanche avoir le droit d'appeler
   `PUT /active-response`.
4. Tester depuis l'API (ou le workflow Shuffle), puis vérifier les deux règles dans le pare-feu Windows Defender
   et les lignes `ISOLATION ACTIVE` dans `active-responses.log`.

Pour lever l'isolation à la main sur la machine : `netsh advfirewall firewall delete rule name=WazuhIsolation_In`
et `netsh advfirewall firewall delete rule name=WazuhIsolation_Out`.
