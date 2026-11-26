# Shuffle — orchestration et automatisation (SOAR)

Shuffle reçoit les alertes Wazuh par webhook, les qualifie, les enrichit avec TheHive et Cortex, puis déclenche
la réponse (blocage OPNsense, isolation de l'hôte) et notifie l'analyste par Telegram.
Il est déployé avec Docker Compose sur une **VM distincte** de la zone SOC : `192.168.30.40`.

| Élément | Valeur |
|---|---|
| Conteneurs | `shuffle-frontend`, `shuffle-backend`, `shuffle-orborus`, `shuffle-opensearch` |
| Interface web | `http://192.168.30.40:3001` (HTTPS : `3443`) |
| API / webhooks | `5001` (backend) ; le webhook reçoit les alertes Wazuh |
| Workflow | `soc_automation` (28 nœuds, un seul workflow) |

## Contenu du dossier

```
shuffle/
├── docker-compose.yml
├── .env.example                  # modèle du .env (3 valeurs à renseigner)
└── workflows/soc_automation.json # export du workflow (sans secrets)
```

Les scripts d'isolation de l'hôte (réponse active Wazuh appelée par le workflow) sont dans
`wazuh/agent-windows/active-response/`.

## Déploiement

Prérequis : VM Ubuntu Server 24.04 avec Docker et le plugin Docker Compose. À lancer depuis ce dossier :

```bash
# 1. Dossiers de données (le volume OpenSearch est monté sur ./shuffle-database)
mkdir -p shuffle-database shuffle-apps shuffle-files
sudo chown -R 1000:1000 shuffle-database

# 2. Paramètre noyau requis par OpenSearch (persistant)
echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-opensearch.conf
sudo sysctl --system

# 3. Fichier .env avec une clé de chiffrement et un mot de passe OpenSearch aléatoires
cp .env.example .env
OS_PASS="Aa1!$(openssl rand -hex 16)"
sed -i "s/YOUR_RANDOM_ENCRYPTION_KEY/$(openssl rand -hex 32)/" .env
sed -i "s/YOUR_OPENSEARCH_PASSWORD/$OS_PASS/g" .env

# 4. Démarrage et vérification
sudo docker compose up -d
sudo docker compose ps
```

Les quatre conteneurs doivent être `Up`. Ouvrir `http://192.168.30.40:3001` et créer le compte administrateur
à la première connexion. **Conserver `SHUFFLE_ENCRYPTION_MODIFIER`** : s'il est perdu ou modifié, toutes les
authentifications des applications doivent être recréées.

## Import du workflow

1. Dans l'interface : *Workflows* → *Import* → choisir `workflows/soc_automation.json`.
2. Activer les applications utilisées si besoin : **Shuffle Tools**, **TheHive**, **http**, **Telegram_Bot**.
3. Compléter les connexions ci-dessous (aucun secret n'est contenu dans l'export).
4. Démarrer le déclencheur **Wazuh_alerts** (webhook), copier son URL et la placer dans le bloc
   `<integration>` du `ossec.conf` du manager Wazuh (`hook_url`, voir `wazuh/manager/ossec.conf`).

### Connexions à configurer

| Nœuds | À renseigner |
|---|---|
| TheHive (`Create_alert`, `add_observable`, `Create_case`, `Run_analyszer_*`, `get_reports_*`) | URL `http://192.168.30.30:9000` et clé API d'un utilisateur analyste de TheHive |
| `list_observables`, `http_1` (appels directs à l'API TheHive) | URL de l'API TheHive et en-tête `Authorization: Bearer <clé API>` |
| `opnsense_add_ip`, `opnsense_apply` | URL de l'API OPNsense, clé et secret d'API en authentification basique ; alias de blocage `soc_blocklist` |
| `wazuh_auth`, `wazuh_isolate_host` | URL de l'API du manager Wazuh (port 55000), identifiants d'un utilisateur API ; le jeton obtenu sert d'en-tête `Authorization: Bearer` |
| Telegram (`notif`, `ip_ok`, `ip_malveillante`, `fichier_*`, `ransomware_notif`, `notif_malware`) | Jeton du bot Telegram et `chat_id` de l'analyste |

> **Important** : l'export est nettoyé. Les URL, clés, jetons et `chat_id` sont vides ou remplacés par des
> placeholders (`YOUR_API_TOKEN`), et le corps (`body`) des nœuds TheHive et Telegram contient les modèles
> par défaut des applications (`${title}`, `${message}`, `${chat_id}`, ...). Après l'import, ces corps doivent
> être réécrits avec les champs produits par le nœud `detect_type` (`obs_type`, `obs_value`, `malware_confirmed`,
> `file`, `vt_positives`, `vt_total`, `alert_title`).

## Fonctionnement du workflow

1. **Réception** : webhook alimenté par l'intégration Wazuh (seules les alertes de sévérité élevée sont transmises).
2. **Déduplication** : empreinte SHA-256 (IP de l'agent, règle, description, SHA1 VirusTotal) comparée au cache
   Shuffle (`wazuh_dedup`) ; une alerte déjà vue arrête le traitement.
3. **Classification** (`detect_type`) : `ransomware`, `ip`, `hash`, malware déjà confirmé par VirusTotal, ou `other`.
4. **TheHive** : création de l'alerte, ajout de l'observable, promotion en case (modèle « Ransomware Response » pour le ransomware).
5. **Branches** :
   - **Ransomware** : authentification à l'API Wazuh, puis réponse active `!isolate-host.cmd` sur l'agent, puis notification Telegram.
   - **IP** : analyse AbuseIPDB via Cortex ; si l'IP est malveillante, ajout à l'alias `soc_blocklist` d'OPNsense, application de la configuration et notification ; sinon notification « IP ok ».
   - **Hash** : analyse VirusTotal via Cortex, extraction du nombre de moteurs « malicious » ; plus de 5 → « fichier malveillant », moins de 4 → « fichier ok ».
   - **Malware déjà confirmé** : notification seule, sans analyse (économise le quota VirusTotal).
   - **Autre** : notification simple.
6. **Temporisations** : nœuds d'attente (5 s, 50 s, 60 s) entre le lancement d'une analyse Cortex et la lecture de son rapport.

## Points d'attention

- Le backend et Orborus montent `/var/run/docker.sock` pour lancer les applications dans des conteneurs :
  acceptable en lab, à restreindre en production.
- Les images sont en `latest` : relever les versions utilisées si le lab doit être reproduit à l'identique.
- Le mot de passe OpenSearch doit respecter la politique de complexité d'OpenSearch (majuscule, minuscule, chiffre, caractère spécial).
- `SHUFFLE_APP_REPLICAS=3` et `SHUFFLE_ORBORUS_EXECUTION_CONCURRENCY=5` sont les valeurs par défaut : à baisser sur une VM à faible RAM.
