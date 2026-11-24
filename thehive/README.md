# TheHive 5 — gestion des alertes et des incidents

TheHive centralise les alertes créées par Shuffle, les observables (IP, hash) et les cases d'investigation.
Il est déployé avec Docker Compose sur la VM **thehivecortex** (zone SOC, `192.168.30.30`), à côté de Cortex.

| Élément | Valeur |
|---|---|
| Version | TheHive 5.7.3 (affiché 5.7.3-1 dans l'interface) |
| Profil de départ | StrangeBee `prod1-thehive` (dépôt officiel `StrangeBeeCorp/docker`), limites mémoire réduites |
| Conteneurs | `cassandra`, `elasticsearch`, `thehive`, `nginx` |
| Port utilisé par la plateforme | `9000` (interface web + API, appelée par Shuffle) ; `443` (Nginx) disponible |
| VM | 6 049 Mo de RAM, 2 CPU, 40 Go (partagés avec Cortex) |

## Contenu du dossier

Ce dossier est la **racine de déploiement** : on y lance `docker compose`. L'arborescence reprend celle du profil officiel.

```
thehive/
├── docker-compose.yml
├── .env.example                          # modèle du .env (versions, UID/GID, mot de passe Elasticsearch)
├── nginx/templates/default.conf.template # reverse proxy HTTPS vers TheHive
└── thehive/config/
    ├── application.conf                  # Cassandra, stockage local, modules Cortex et MISP
    ├── index.conf.template               # index Elasticsearch (mot de passe à renseigner)
    └── secret.conf.template              # clé secrète de l'application (à générer)
```

Les fichiers réels `.env`, `thehive/config/index.conf`, `thehive/config/secret.conf` et `nginx/certs/`
contiennent des secrets : ils sont générés à l'installation et **jamais publiés** (voir `.gitignore`).
`logback.xml` du profil officiel est facultatif (personnalisation des journaux).

## Déploiement

Prérequis : VM Ubuntu Server 24.04 avec Docker et le plugin Docker Compose.
Ne pas utiliser le script `init.sh` de la branche principale du dépôt officiel : elle déploie désormais
TheHive 6 et non la 5.7.3 de ce lab. Les commandes ci-dessous font la même initialisation, avec les versions de `.env.example`.
À lancer depuis ce dossier :

```bash
# 1. Dossiers de données
mkdir -p cassandra/data cassandra/logs elasticsearch/data elasticsearch/logs \
         thehive/data/files thehive/logs nginx/certs

# 2. Fichier .env (UID/GID de l'utilisateur courant + mot de passe Elasticsearch aléatoire)
ES_PASS=$(head -c 8192 /dev/urandom | LC_CTYPE=C tr -dc '[:alnum:]' | head -c 64)
cp .env.example .env
sed -i "s/^UID=.*/UID=$(id -u)/; s/^GID=.*/GID=$(id -g)/" .env
sed -i "s/YOUR_ELASTICSEARCH_PASSWORD/$ES_PASS/" .env

# 3. Configuration secrète de TheHive
sed -e "s/###CHANGEME_ELASTICSEARCH_PASSWORD###/$ES_PASS/" \
    thehive/config/index.conf.template > thehive/config/index.conf
echo "play.http.secret.key=\"$(head -c 8192 /dev/urandom | LC_CTYPE=C tr -dc '[:alnum:]' | head -c 64)\"" \
    > thehive/config/secret.conf
chmod 600 thehive/config/secret.conf

# 4. Certificat auto-signé pour Nginx
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout nginx/certs/server.key -out nginx/certs/server.crt -subj "/CN=thehive"
chmod 600 nginx/certs/server.key

# 5. Propriété des dossiers (même UID/GID que le .env), puis démarrage
sudo chown -R "$(id -u):$(id -g)" cassandra elasticsearch thehive nginx
sudo docker compose up -d
sudo docker compose ps
```

Attendre que Cassandra et Elasticsearch soient `healthy` (plusieurs minutes), TheHive démarre ensuite.
Ouvrir `http://<IP_VM>:9000` : première connexion avec le compte administrateur par défaut
(`admin@thehive.local`), à changer immédiatement.

## Configuration après installation

- **Utilisateur analyste** : le compte admin de la plateforme n'a pas accès aux Cases. Créer un utilisateur
  avec le profil `analyst` dans l'organisation (`admin` par défaut dans le lab).
- **Clé API** : générer une clé pour l'utilisateur utilisé par Shuffle (ne jamais la publier).
- **Cortex** : déclarer le serveur Cortex, voir `../cortex/README.md`.

## Points d'attention

- Limites mémoire strictes (Cassandra 2 Go, Elasticsearch 2 Go, TheHive 2,5 Go). Sur une VM trop petite,
  l'OOM killer arrête des processus Java en boucle et peut corrompre Cassandra.
- `play.http.context` vaut `/` : l'API est à `http://<IP>:9000/api/v1/...` (pas de préfixe `/thehive`).
  Le `healthcheck` du compose interroge `/thehive/api/status` ; à adapter si TheHive apparaît `unhealthy`.
- Les identifiants Cassandra sont ceux par défaut (`cassandra`/`cassandra`) : à changer hors lab.
- Les dossiers de données doivent appartenir à l'UID/GID du `.env`, sinon Elasticsearch ou Cassandra refusent de démarrer.
