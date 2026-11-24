# Cortex — analyse et enrichissement des observables

Cortex exécute les analyseurs (AbuseIPDB, VirusTotal, Urlscan.io) demandés par TheHive ou par Shuffle.
Il tourne sur la même VM que TheHive (`192.168.30.30`), port **9001**.

| Élément | Valeur |
|---|---|
| Image | `thehiveproject/cortex:latest` (affiché en 4.0.0-1 dans TheHive) |
| Stockage | Elasticsearch 8.19.15 dédié, non exposé à l'extérieur ; sécurité xpack désactivée par défaut (variable `ELASTICSEARCH_SECURITY_ENABLED`, `false` par défaut) |
| Port | `9001` |
| Mémoire | Cortex 1000 Mo, Elasticsearch 1400 Mo (heap 1 Go) |

Pourquoi ce compose maison plutôt que le profil `prod1-cortex` : il est plus léger, ce qui compte
car la VM héberge déjà la pile TheHive.

## Déploiement

1. Créer le dossier de jobs sur l'hôte : `mkdir -p ~/cortex-standalone/jobs`. Le compose utilise le chemin
   absolu `/home/cortex/cortex-standalone/jobs` (utilisateur `cortex` du lab) : si ton utilisateur ou ton
   dossier diffère, modifier ce chemin aux deux endroits où il apparaît (`docker_job_directory` et le volume).
2. Copier `docker-compose.yml` dans `~/cortex-standalone/`.
3. Démarrer : `sudo docker compose up -d` puis `sudo docker compose ps`.
4. Ouvrir `http://<IP_VM>:9001`, lancer la mise à jour de la base (maintenance) et créer
   le compte super-administrateur (`Cortex Administrator`) : réservé à l'administration, pas aux analyses.

## Organisation et utilisateurs

1. L'organisation par défaut (`cortex`) ne sert qu'à gérer l'instance.
2. Créer l'organisation **RNE_SOC** pour les opérations du SOC.
3. Créer un utilisateur nominatif avec le rôle `orgadmin` dans RNE_SOC (gestion des analyseurs, lancement
   d'analyses, historique des jobs).
4. Se connecter avec ce compte et activer les analyseurs : **AbuseIPDB** (IP), **VirusTotal_GetReport**
   (hash, utilisé en 3.1 dans le workflow) et **Urlscan_io**. Leurs clés API se saisissent dans l'interface
   (jamais dans le dépôt).

## Lien avec TheHive

1. Dans Cortex (organisation RNE_SOC), générer la clé API d'un utilisateur (jamais publiée).
2. Dans le fichier `thehive/thehive/config/application.conf` de la VM, sous la ligne qui active
   `CortexModule`, déclarer le serveur (syntaxe standard de TheHive 5) :

```
cortex {
  servers = [
    {
      name = "cortex-local"
      url = "http://192.168.30.30:9001"
      auth { type = "bearer", key = "YOUR_CORTEX_API_KEY" }
    }
  ]
}
```

3. Redémarrer TheHive : `sudo docker compose restart thehive` (dossier `thehive/`).
4. L'écran « À propos » de TheHive affiche alors l'instance Cortex avec la mention **OK** et sa version.

Test de validation du lab : analyse du hash EICAR (VirusTotal) et de l'IP `8.8.8.8` (AbuseIPDB, Urlscan.io)
depuis un case TheHive, avec le même résultat dans l'historique des jobs de Cortex.

## Points d'attention

- Le montage de `/var/run/docker.sock` permet à Cortex de lancer les analyseurs dans des conteneurs :
  acceptable en lab, à restreindre en production.
- Permissions rencontrées en déploiement : accès refusé au socket Docker (utilisateur hors du groupe
  `docker`, ou droits du socket) et accès refusé au dossier des jobs (corrigé avec `chmod 777` en lab).
- Ne pas passer `ELASTICSEARCH_SECURITY_ENABLED` à `true` sans configurer aussi l'authentification d'Elasticsearch côté Cortex : le lab fonctionne avec la valeur par défaut `false`.
- Le dossier `es-data/` contient les données d'Elasticsearch : ne pas le versionner.
