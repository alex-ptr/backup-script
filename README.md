

============================================================================
# SCRIPT DE MAINTENANCE D'UN VPS
============================================================================

Structure attendue des répertoires
```
/mnt/data/containers/
├── app1/
│   ├── docker-compose.yml
│   ├── .env
│   └── secrets/          ← sous-répertoires inclus automatiquement
├── app2/
│   ├── docker-compose.yaml
│   └── config/
└── ...
/mnt/data/backups/
└── backup_20240115_010000.tar.gz
    ├── app1/
    │   ├── files/        ← copie exacte du répertoire docker compose
    │   ├── volumes/      ← dump tar.gz de chaque volume
    │   └── compose_resolved.yml
    └── app2/
        └── ...
```

## 1. INSTALLATION DU SCRIPT
```sh
sudo cp backup-script.sh /usr/local/bin/backup-script
sudo chmod +x /usr/local/bin/backup-script
```

## 2. SAUVEGARDE DES APPLICATIONS DOCKER
### 2.1 Configurer rclone
```sh
sudo rclone config
```
- Choisir "n" (new remote)
- Nom : swift  (ou le nom de votre choix — à reporter dans RCLONE_REMOTE_NAME)
- Type : openstack (option 45 environ, chercher "swift")
- Renseignez les paramètres selon votre fournisseur :

| RCLONE CONFIG | GENERIC | INFOMANIAK | NOTE |
| :--- | :--- | :--- | :--- |
| env_auth | false |  |  |
| user     | votre_utilisateur_openstack | SBI-... |  |
| key      | votre_mot_de_passe_ou_token | ... |  |
| auth     | https://auth.example.com/v3  ← URL d'auth Keystone | https://swiss-backup04.infomaniak.com/identity/v3 |  |
| tenant   | votre_projet_openstack | sb_project_SBI-... |  |
| domain   | Default | default | ← RCLONE_REMOTE_PATH |
| region   | GRA  (ex: OVH) | RegionOne |  |

Testez la connexion :
```sh
    rclone ls swift:nom-de-votre-conteneur-swift
```
### 2.2 Changer les variables dans le script
Mettre à jour les variables suivantes:
- RCLONE_REMOTE_NAME
- RCLONE_REMOTE_PATH

Le script s'exécutant en root et la configuration de rclone en utilisateur, il faut spécifier manuellement le fichier de configuration
RCLONE_CONFIG="/home/{current_user}/.config/rclone/rclone.conf"


## 3. Configurer les exécutions quotidiennes
```sh
sudo crontab -e
```
Puis ajoutez la ligne suivante :
```sh
0 1 * * * /usr/local/bin/backup-script >> /var/log/backup-script/cron.log 2>&1
```
## 4. ROTATION DES LOGS (logrotate) 
Créez un fichier log dans : /etc/logrotate.d/backup-script
Puis y ajoutez le contenu suivant :

```
/var/log/backup-script/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
```

## 5. RESTORATION
# Extraire l'archive
```sh
tar xzf /mnt/data/backups/backup_YYYYMMDD_HHMMSS.tar.gz -C /tmp/restore
```
# Restaurer les fichiers de l'app
```sh
rsync -a /tmp/restore/backup_*/mon_app/files/ /mnt/data/containers/mon_app/
```
# Restaurer un volume
```sh
docker volume create mon_projet_mon_volume
docker run --rm \
  -v mon_projet_mon_volume:/data \
  -v /tmp/restore/backup_*/mon_app/volumes:/backup:ro \
  alpine sh -c "tar xzf /backup/mon_projet_mon_volume.tar.gz -C /data"
```
# Relancer l'application
```sh
docker compose -f /mnt/data/containers/mon_app/docker-compose.yml up -d
```
