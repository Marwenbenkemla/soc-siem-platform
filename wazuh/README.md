# Wazuh : SIEM, supervision Windows et réponse active

Wazuh 4.14 est installé sur une seule VM (`wazuh`, 192.168.30.10, zone SOC) avec ses trois
composants : indexer, manager et dashboard. Il collecte les événements du serveur Windows
(agent, Sysmon, FIM), reçoit les alertes de Suricata via OPNsense, interroge VirusTotal, supprime
automatiquement les fichiers malveillants, détecte les comportements de ransomware et envoie
ses alertes importantes à Shuffle.

Fichiers de configuration de ce dossier et leur destination :

| Fichier | À copier vers |
|---|---|
| [`manager/ossec.conf`](manager/ossec.conf) | `/var/ossec/etc/ossec.conf` (VM Wazuh) |
| [`manager/local_rules.xml`](manager/local_rules.xml) | `/var/ossec/etc/rules/local_rules.xml` (VM Wazuh) |
| [`agent-windows/ossec-snippets.xml`](agent-windows/ossec-snippets.xml) | `C:\Program Files (x86)\ossec-agent\ossec.conf` (serveur Windows), à insérer |

## 1. Installer le serveur Wazuh

Sur la VM Ubuntu (voir les ressources dans [`../docs/architecture.md`](../docs/architecture.md)) :

```
curl -sO https://packages.wazuh.com/4.14/wazuh-install.sh && sudo bash ./wazuh-install.sh -a
```

L'option `-a` (all-in-one) installe l'indexer, le manager et le dashboard, génère les
certificats et configure leurs liaisons. **À la fin, l'assistant affiche l'identifiant et le mot
de passe de l'administrateur du dashboard : note-les dans un gestionnaire de mots de passe, sans
jamais les mettre dans le dépôt.**

Vérifie les trois services :

```
sudo systemctl status wazuh-indexer wazuh-manager wazuh-dashboard
```

Chacun doit être `active (running)`. Le dashboard est accessible depuis le réseau interne sur
`https://192.168.30.10`.

## 2. Déployer l'agent sur le serveur Windows

Sur le Windows Server (192.168.20.10, zone LAN), dans PowerShell en administrateur :

```
Invoke-WebRequest -Uri https://packages.wazuh.com/4.x/windows/wazuh-agent-4.14.5-1.msi -OutFile $env:tmp\wazuh-agent; msiexec.exe /i $env:tmp\wazuh-agent /q WAZUH_MANAGER='192.168.30.10' WAZUH_AGENT_GROUP='default' WAZUH_AGENT_NAME='winserver'
Get-Service wazuhsvc
```

Les trois paramètres donnent l'adresse du manager, le groupe et le nom de l'agent : il s'enrôle
tout seul. Le service `wazuhsvc` doit être `Running`. Dans le dashboard, l'agent `winserver`
apparaît dans la page **Endpoints**.

L'agent doit pouvoir joindre le manager (ports 1514 et 1515) à travers OPNsense : la règle
LAN du lab l'autorise.

## 3. Superviser Windows avec Sysmon

Sysmon enregistre des événements détaillés (ligne de commande, processus parent, empreintes
SHA256, connexions réseau, fichiers créés) que Wazuh analyse avec ses règles intégrées,
associées à MITRE ATT&CK.

**1. Installer Sysmon** avec un fichier de configuration (le lab utilise
`sysmonconfig-export.xml`), dans PowerShell en administrateur :

```
cd C:\Tools\Sysmon
.\Sysmon64.exe -accepteula -i .\sysmonconfig-export.xml
Get-Service sysmon64
```

Le service `sysmon64` doit être `Running`.

**2. Faire lire le journal Sysmon par l'agent.** Ajoute le premier bloc de
[`agent-windows/ossec-snippets.xml`](agent-windows/ossec-snippets.xml) dans le `ossec.conf` de
l'agent, puis relance-le avec `Restart-Service wazuhsvc`.

**3. Vérifier.** Dans le dashboard, **Threat Hunting > Events**, filtre sur l'agent `winserver`
et cherche `sysmon` : les alertes vont du niveau 3 (découverte) au niveau 15 (exécutable déposé
dans un dossier suspect).

## 4. Surveiller l'intégrité des fichiers (FIM)

Le module `syscheck` de l'agent détecte la création, la modification et la suppression de
fichiers, et calcule leurs empreintes (MD5, SHA1, SHA256). Par défaut, il contrôle les fichiers
critiques de Windows toutes les 12 heures (`frequency` à 43200 secondes), ce qui est trop lent
pour réagir à une attaque.

Le lab ajoute donc un dossier surveillé **en temps réel** : le bureau de l'administrateur,
qui sert de zone de test. Ajoute le second bloc de
[`agent-windows/ossec-snippets.xml`](agent-windows/ossec-snippets.xml) dans le bloc
`<syscheck>` existant, puis relance l'agent.

Pour tester, crée puis modifie un fichier `test.txt` sur ce bureau. Les deux événements
apparaissent dans **File Integrity Monitoring** pour l'agent `winserver`, avec l'utilisateur, la
taille et les empreintes.

## 5. Configurer le manager

Le fichier [`manager/ossec.conf`](manager/ossec.conf) est la configuration complète du manager
(Wazuh 4.14 sur Ubuntu 24.04), nettoyée de tout secret. Les blocs propres au projet se trouvent
**à la fin du fichier** :

| Bloc | Rôle |
|---|---|
| `integration` `virustotal` | Soumet à VirusTotal les alertes du FIM (`group` à `syscheck`) |
| `command` `remove-threat` | Déclare le script de suppression `remove-threat.exe`, fourni avec l'agent Windows |
| `active-response` | Lance `remove-threat` sur la machine concernée (`location` à `local`) pour la règle **87105** (détection positive de VirusTotal) |
| `integration` `shuffle` | Envoie au webhook de Shuffle les alertes de **niveau 10 et plus**, au format JSON |

**Valeurs à renseigner** (elles sont remplacées par des placeholders dans le fichier) :

| Placeholder | À remplacer par |
|---|---|
| `YOUR_VIRUSTOTAL_API_KEY` | Ta clé API VirusTotal |
| `YOUR_SHUFFLE_HOST` | L'adresse de Shuffle avec son port, par exemple `192.168.30.40:3001` |
| `YOUR_SHUFFLE_WEBHOOK_ID` | L'identifiant du webhook, copié depuis le nœud *Webhook* de ton workflow Shuffle |

Dans le lab, Shuffle reçoit le webhook en HTTP sur le port 3001 : l'URL est donc de la forme
`http://192.168.30.40:3001/api/v1/hooks/<identifiant>`. Remplace l'URL complète du placeholder
(`https://YOUR_SHUFFLE_HOST/...`) en fonction de ton installation.

**Appliquer** (sur la VM Wazuh, depuis le dossier `wazuh` du dépôt cloné) :

```
git clone https://github.com/Marwenbenkemla/soc-siem-platform.git
cd soc-siem-platform/wazuh
sudo cp /var/ossec/etc/ossec.conf /var/ossec/etc/ossec.conf.bak
sudo cp manager/ossec.conf /var/ossec/etc/ossec.conf
sudo nano /var/ossec/etc/ossec.conf
sudo /var/ossec/bin/wazuh-analysisd -t
sudo systemctl restart wazuh-manager
```

Le `nano` sert à remplacer les placeholders. La commande `wazuh-analysisd -t` teste la
configuration avant le redémarrage.

Ce fichier correspond aux valeurs par défaut de Wazuh 4.14 sur Ubuntu 24.04. Avec une autre
version, ne remplace pas le fichier : ajoute seulement les blocs de la fin (VirusTotal, `remove-threat`,
`active-response` et Shuffle) dans ton `ossec.conf`.

## 6. Règles personnalisées

Le fichier [`manager/local_rules.xml`](manager/local_rules.xml) se copie dans
`/var/ossec/etc/rules/local_rules.xml`, puis le manager est redémarré (comme ci-dessus).

| Règle | Niveau | Rôle |
|---|---|---|
| 100050 | 10 | Scan Nmap détecté par Suricata : règle fille de 86601 dont la signature contient `Nmap` |
| 100060 | 15 | Ransomware suspecté : au moins 10 modifications de fichiers (règle FIM 550) en 60 secondes, technique MITRE T1486 |
| 100092 | 12 | Journalise la suppression réussie d'un fichier par `remove-threat` |
| 100093 | 12 | Journalise l'échec de cette suppression |
| 100001 | 5 | Règle d'exemple fournie par Wazuh (échec sshd depuis 1.1.1.1), sans lien avec le projet : tu peux la supprimer |

Ces niveaux expliquent le seuil de 10 des webhooks Shuffle : le scan Nmap (10), la détection de
VirusTotal (12) et le ransomware (15) sont transmis, pas les alertes de bruit de fond.

Il n'y a **aucun décodeur personnalisé** : le fichier `local_decoder.xml` du lab ne contient que
le modèle par défaut. Les alertes de Suricata sont décodées par le décodeur JSON intégré.

## 7. VirusTotal et suppression automatique

La chaîne complète est : alerte FIM, consultation de VirusTotal, alerte de détection (règle 87105),
suppression automatique du fichier, journalisation (règle 100092).

**Test avec le fichier EICAR** (inoffensif, mais reconnu comme malveillant par tous les
antivirus) : télécharge-le sur le bureau de l'administrateur. Le FIM le détecte, VirusTotal le
confirme (66 moteurs dans le test du lab), puis `remove-threat` le supprime environ 5 secondes
plus tard. L'alerte 100092 conserve la trace de la suppression.

Le compte gratuit de VirusTotal a un quota limité : l'alerte « Public API request rate limit
reached » (règle 87101) indique qu'il est atteint.

## 8. Alertes réseau de Suricata

Les alertes de Suricata arrivent dans Wazuh par l'agent installé sur OPNsense : sa configuration
est décrite dans la section 6 de [`../opnsense/README.md`](../opnsense/README.md). Pour tester la
règle 100050, lance un scan Nmap depuis Kali vers le Windows Server : l'alerte « Scan Nmap
détecté » apparaît dans **Threat Hunting > Events** avec le niveau 10.

## 9. Secrets et durcissement

| Valeur | Où elle vit |
|---|---|
| Clé API VirusTotal | `ossec.conf` du manager, à ne jamais versionner |
| Identifiant du webhook Shuffle | `ossec.conf` du manager : il joue le rôle d'un secret, car toute personne qui peut joindre Shuffle et le connaît peut déclencher le workflow |
| Mot de passe admin du dashboard | Affiché à la fin de l'installation |

Dans le lab, l'enrôlement des agents ne demande **pas de mot de passe**
(`<use_password>no</use_password>`) : toute machine qui joint le port 1515 peut s'enregistrer.
En production, active le mot de passe d'enrôlement (`authd.pass`) et envoie les webhooks en
HTTPS.
