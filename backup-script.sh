#!/bin/bash
# ==============================================================================
#  Script de maintenance d'un VPS :
# - Backup des applications docker compose
# - Copie des backups vers le cloud avec rclone
# - Mise à jour du système et des applications
#
#  Exécution : quotidienne à 01h00 via cron
# ==============================================================================

set -uo pipefail

# ──────────────────────────────────────────────────────────────────────────────
#  CONFIGURATION — à adapter selon votre environnement
# ──────────────────────────────────────────────────────────────────────────────

CONTAINERS_DIR="/mnt/data/containers"       # Répertoire des apps docker compose
BACKUPS_DIR="/mnt/data/backups"             # Répertoire local des sauvegardes
LOG_DIR="/var/log/backup-script"            # Répertoire des logs
RETENTION_DAYS=7                            # Durée de rétention locale (jours)
RCLONE_REMOTE_NAME="swissbackup"            # Remote rclone (voir README intégré)
RCLONE_REMOTE_PATH="default"                # Remote bucket
RCLONE_FLAGS="--transfers=4 --checkers=8 --contimeout=60s --timeout=300s --retries=3"

# Choix du fichier de configuration rclone
# Le script s'exécute en sudo, il faut donc utiliser un fichier de configuration de l'utilisateur
RCLONE_CONFIG="/home/alexandre/.config/rclone/rclone.conf"
export RCLONE_CONFIG

# ──────────────────────────────────────────────────────────────────────────────
#  VARIABLES INTERNES
# ──────────────────────────────────────────────────────────────────────────────

DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="backup_${DATE}"
BACKUP_PATH="${BACKUPS_DIR}/${BACKUP_NAME}"
LOG_FILE="${LOG_DIR}/maintenance-$(date +%Y-%m-%d).log"
SCRIPT_START=$(date +%s)

declare -a BACKED_UP=()
declare -a UPDATED_APPS=()
ERRORS=0
WARNINGS=0

# ══════════════════════════════════════════════════════════════════════════════
#  FONCTIONS UTILITAIRES
# ══════════════════════════════════════════════════════════════════════════════

# ── Logging ───────────────────────────────────────────────────────────────────

_log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    local colored="[${ts}] [${level}] $*"
    local plain
    plain=$(printf "%b" "$colored" | sed 's/\x1B\[[0-9;]*m//g')

    printf "%b\n" "$colored"
    printf "%s\n" "$plain" >> "$LOG_FILE"
}

# Couleurs
b="\033[34m"
j="\033[33m"
r="\033[31m"
v="\033[32m"
n="\033[0m"

log_info()  { _log "${b}ℹ️ INFO ${n}" "$@"; }
log_ok()    { _log "${v}✅ OK   ${n}" "$@"; }
log_warn()  { _log "${j}⚠️ WARN ${n}" "${j}$@${n}"; WARNINGS=$((WARNINGS + 1)); }
log_error() { _log "${r}❌ ERROR${n}" "${r}$@${n}"; ERRORS=$((ERRORS + 1)); }
log_sep()   { _log "--------" "──────────────────────────────────────────────"; }


# ── Vérification des prérequis ────────────────────────────────────────────────

check_requirements() {
    log_info "Vérification des prérequis..."
    local missing=0

    for cmd in docker rclone rsync python3 tar; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Commande manquante : ${cmd}"
            missing=$((missing + 1))
        fi
    done

    if [ "$missing" -gt 0 ]; then
        log_error "${missing} prérequis manquant(s). Abandon."
        exit 1
    fi

    mkdir -p "$BACKUPS_DIR" "$LOG_DIR"
    log_ok "Prérequis OK."
}


# ── Obtenir le nom de projet docker compose ───────────────────────────────────

get_project_name() {
    local compose_file="$1"
    local app_dir; app_dir=$(dirname "$compose_file")

    # Priorité 1 : variable COMPOSE_PROJECT_NAME dans .env
    if [ -f "${app_dir}/.env" ]; then
        local env_name
        env_name=$(grep -E '^COMPOSE_PROJECT_NAME=' "${app_dir}/.env" \
                   | cut -d= -f2 | tr -d '"' | tr -d "'" | head -1)
        [ -n "$env_name" ] && { echo "$env_name"; return; }
    fi

    # Priorité 2 : champ "name" dans le fichier compose
    local compose_name
    compose_name=$(grep -E '^name:' "$compose_file" \
                   | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")
    [ -n "$compose_name" ] && { echo "$compose_name"; return; }

    # Priorité 3 : nom du répertoire (comportement docker compose par défaut)
    basename "$app_dir" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-_'
}


# ══════════════════════════════════════════════════════════════════════════════
#  ÉTAPE 1 — BACKUP DES APPLICATIONS DOCKER COMPOSE
# ══════════════════════════════════════════════════════════════════════════════

backup_app() {
    local compose_file="$1"
    local app_name="$2"
    local app_dir; app_dir=$(dirname "$compose_file")
    local app_backup="${BACKUP_PATH}/${app_name}"
    local step_errors=0

    log_info "┌─ Application : ${app_name}"
    mkdir -p "${app_backup}/volumes" "${app_backup}/images" "${app_backup}/files"

    # ── 1a. Arrêt propre des conteneurs ──────────────────────────────────────
    log_info "│  Arrêt des conteneurs..."
    if ! docker compose -f "$compose_file" stop 2>>"$LOG_FILE"; then
        log_warn "│  Impossible d'arrêter ${app_name} proprement (on continue)."
    fi

    # ── 1b. Copie complète du répertoire (fichiers, secrets, configs...) ──────
    log_info "│  Copie des fichiers de configuration et secrets..."
    if ! rsync -a --exclude='*.log' --exclude='__pycache__' \
            "${app_dir}/" "${app_backup}/files/" 2>>"$LOG_FILE"; then
        log_error "│  Échec de la copie des fichiers pour ${app_name}."
        step_errors=$((step_errors + 1))
    else
        log_ok "│  Fichiers copiés."
    fi

    # ── 1c. Backup des volumes ────────────────────────────────────────────────
    local project_name; project_name=$(get_project_name "$compose_file")
    local volumes
    volumes=$(docker compose -f "$compose_file" config --volumes 2>/dev/null || true)

    if [ -n "$volumes" ]; then
        log_info "│  Backup des volumes (projet : ${project_name})..."
        while IFS= read -r vol_short; do
            [ -z "$vol_short" ] && continue

            # Docker peut préfixer avec le nom de projet ou non (volumes externes)
            local vol_full="${project_name}_${vol_short}"
            if ! docker volume inspect "$vol_full" &>/dev/null 2>&1; then
                # Tentative sans préfixe (volume externe ou nom custom)
                if docker volume inspect "$vol_short" &>/dev/null 2>&1; then
                    vol_full="$vol_short"
                else
                    log_warn "│  Volume ${vol_full} introuvable, ignoré."
                    continue
                fi
            fi

            log_info "│    → Volume : ${vol_full}"
            if ! docker run --rm \
                    -v "${vol_full}:/volume_data:ro" \
                    -v "${app_backup}/volumes:/backup" \
                    alpine \
                    tar czf "/backup/${vol_full}.tar.gz" -C /volume_data . \
                    2>>"$LOG_FILE"; then
                log_warn "│    Échec du backup du volume ${vol_full}."
            else
                log_ok "│    + Volume ${vol_full} sauvegardé."
            fi
        done <<< "$volumes"
    else
        log_info "│  Aucun volume nommé déclaré."
    fi

    # ── 1d. Sauvegarde des images Docker ─────────────────────────────────────
    log_info "│  Sauvegarde des images..."
    local images_list
    images_list=$(docker compose -f "$compose_file" images --format json 2>/dev/null \
        | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    seen = set()
    for item in data:
        repo = item.get('Repository','').strip()
        tag  = item.get('Tag','latest').strip()
        if repo and repo != '<none>' and repo not in seen:
            seen.add(repo)
            print(f'{repo}:{tag}')
except Exception as e:
    pass
" 2>/dev/null || true)

    if [ -n "$images_list" ]; then
        local safe_name; safe_name=$(echo "$app_name" | tr '/' '_')
        if echo "$images_list" | xargs docker save 2>>"$LOG_FILE" \
                | gzip > "${app_backup}/images/${safe_name}_images.tar.gz"; then
            log_ok "│  Images sauvegardées."
        else
            log_warn "│  Échec partiel de la sauvegarde des images."
        fi
    else
        log_info "│  Aucune image en cours d'exécution détectée."
    fi

    # ── 1e. Export de la config réseau résolue ────────────────────────────────
    log_info "│  Export de la configuration réseau résolue..."
    docker compose -f "$compose_file" config \
        > "${app_backup}/compose_resolved.yml" 2>>"$LOG_FILE" || \
        log_warn "│  Impossible d'exporter la config résolue."

    # ── 1f. Redémarrage des conteneurs ────────────────────────────────────────
    log_info "│  Redémarrage des conteneurs..."
    if ! docker compose -f "$compose_file" start 2>>"$LOG_FILE"; then
        log_warn "│  Échec du redémarrage de ${app_name}."
    fi

    if [ "$step_errors" -eq 0 ]; then
        BACKED_UP+=("$app_name")
        log_ok "└─ ${app_name} → sauvegarde réussie."
    else
        log_error "└─ ${app_name} → sauvegarde terminée avec ${step_errors} erreur(s)."
    fi
}


backup_docker_apps() {
    log_sep
    log_info "ÉTAPE 1/4 — Backup des applications Docker Compose"
    log_sep

    if [ ! -d "$CONTAINERS_DIR" ]; then
        log_error "Répertoire des conteneurs introuvable : ${CONTAINERS_DIR}"
        return 1
    fi

    mkdir -p "$BACKUP_PATH"
    local app_count=0

    for app_dir in "${CONTAINERS_DIR}"/*/; do
        [ -d "$app_dir" ] || continue
        local app_name; app_name=$(basename "$app_dir")
        local compose_file=""

        for fname in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
            if [ -f "${app_dir}/${fname}" ]; then
                compose_file="${app_dir}/${fname}"
                break
            fi
        done

        if [ -z "$compose_file" ]; then
            log_warn "Aucun fichier compose dans ${app_dir}, répertoire ignoré."
            continue
        fi

        backup_app "$compose_file" "$app_name"
        app_count=$((app_count + 1))
    done

    if [ "$app_count" -eq 0 ]; then
        log_warn "Aucune application Docker Compose trouvée dans ${CONTAINERS_DIR}."
        return 0
    fi

    # ── Compression de l'archive finale ──────────────────────────────────────
    local archive="${BACKUPS_DIR}/${BACKUP_NAME}.tar.gz"
    log_info "Compression de l'archive : ${archive}..."
    if tar czf "$archive" -C "$BACKUPS_DIR" "$BACKUP_NAME" 2>>"$LOG_FILE"; then
        rm -rf "$BACKUP_PATH"
        local size; size=$(du -sh "$archive" | cut -f1)
        log_ok "Archive créée : ${archive} (${size})"
    else
        log_error "Échec de la compression — répertoire brut conservé dans ${BACKUP_PATH}."
    fi

    # ── Nettoyage des vieilles sauvegardes locales ────────────────────────────
    log_info "Nettoyage des sauvegardes de plus de ${RETENTION_DAYS} jours..."
    find "$BACKUPS_DIR" -name "backup_*.tar.gz" -mtime "+${RETENTION_DAYS}" \
        -exec rm -f {} \; 2>>"$LOG_FILE" || true

    log_ok "Étape 1 terminée. Applications sauvegardées : ${#BACKED_UP[@]}/${app_count}."
}


# ══════════════════════════════════════════════════════════════════════════════
#  ÉTAPE 2 — SYNCHRONISATION VERS OPENSTACK SWIFT (rclone)
# ══════════════════════════════════════════════════════════════════════════════

sync_to_swift() {
    log_sep
    log_info "ÉTAPE 2/4 — Synchronisation vers OpenStack Swift"
    log_sep

    # Définir le remote complet (ex: "swissbackup:default")
    local RCLONE_FULL_REMOTE="${RCLONE_REMOTE_NAME}:${RCLONE_REMOTE_PATH}"


    if ! command -v rclone &>/dev/null; then
        log_error "rclone n'est pas installé."
        log_error "Installez-le : curl https://rclone.org/install.sh | sudo bash"
        log_error "Puis configurez : rclone config  (voir README intégré en bas du script)"
        ERRORS=$((ERRORS + 1))
        return 1
    fi

    # Vérifier que le REMOTE (sans le chemin) est configuré
    if ! rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE_NAME}:"; then
        log_error "Remote rclone '${RCLONE_REMOTE_NAME}' non configuré."
        log_error "Lancez 'rclone config' pour le configurer. Voir README en bas du script."
        ERRORS=$((ERRORS + 1))
        return 1
    fi

    log_info "Synchronisation de ${BACKUPS_DIR} → ${RCLONE_FULL_REMOTE}..."
    if rclone sync "$BACKUPS_DIR" "$RCLONE_FULL_REMOTE" \
            $RCLONE_FLAGS \
            --log-file="$LOG_FILE" \
            --log-level=INFO \
            2>>"$LOG_FILE"; then
        log_ok "Synchronisation Swift réussie."
    else
        log_error "Échec de la synchronisation Swift."
        return 1
    fi
}


# ══════════════════════════════════════════════════════════════════════════════
#  ÉTAPE 3 — MISE À JOUR DU SYSTÈME
# ══════════════════════════════════════════════════════════════════════════════

update_system() {
    log_sep
    log_info "ÉTAPE 3/4 — Mise à jour du système Ubuntu"
    log_sep

    log_info "apt-get update..."
    if ! apt-get update -qq 2>>"$LOG_FILE"; then
        log_error "Échec de apt-get update."
        return 1
    fi

    log_info "apt-get upgrade (non-interactif)..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            2>>"$LOG_FILE"; then
        log_error "Échec de apt-get upgrade."
        return 1
    fi

    log_info "Nettoyage des paquets obsolètes..."
    apt-get autoremove -y 2>>"$LOG_FILE" || true
    apt-get autoclean  -y 2>>"$LOG_FILE" || true

    # Détection d'un redémarrage nécessaire (nouveau kernel, etc.)
    if [ -f /var/run/reboot-required ]; then
        log_warn "⚠ Redémarrage requis (mise à jour du kernel ou d'une lib critique)."
        if [ -f /var/run/reboot-required.pkgs ]; then
            log_warn "  Paquets concernés : $(cat /var/run/reboot-required.pkgs | tr '\n' ' ')"
        fi
    fi

    log_ok "Système mis à jour."
}


# ══════════════════════════════════════════════════════════════════════════════
#  ÉTAPE 4 — MISE À JOUR DES APPLICATIONS DOCKER
# ══════════════════════════════════════════════════════════════════════════════

update_docker_apps() {
    log_sep
    log_info "ÉTAPE 4/4 — Mise à jour des applications Docker"
    log_sep

    local app_count=0

    for app_dir in "${CONTAINERS_DIR}"/*/; do
        [ -d "$app_dir" ] || continue
        local app_name; app_name=$(basename "$app_dir")
        local compose_file=""

        for fname in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
            if [ -f "${app_dir}/${fname}" ]; then
                compose_file="${app_dir}/${fname}"
                break
            fi
        done

        [ -z "$compose_file" ] && continue
        app_count=$((app_count + 1))

        log_info "┌─ Mise à jour : ${app_name}"

        # Pull des nouvelles images
        log_info "│  Pull des images..."
        if ! docker compose -f "$compose_file" pull 2>>"$LOG_FILE"; then
            log_warn "└─ Échec du pull pour ${app_name}, passage à l'app suivante."
            continue
        fi

        # Redémarrage avec les nouvelles images
        log_info "│  Recréation des conteneurs..."
        if ! docker compose -f "$compose_file" up -d --remove-orphans 2>>"$LOG_FILE"; then
            log_warn "└─ Échec de la recréation des conteneurs pour ${app_name}."
            continue
        fi

        UPDATED_APPS+=("$app_name")
        log_ok "└─ ${app_name} mis à jour avec succès."
    done

    # Nettoyage des images inutilisées
    log_info "Suppression des images Docker orphelines..."
    docker image prune -f 2>>"$LOG_FILE" || true

    log_ok "Étape 4 terminée. Applications mises à jour : ${#UPDATED_APPS[@]}/${app_count}."
}


# ══════════════════════════════════════════════════════════════════════════════
#  RAPPORT FINAL
# ══════════════════════════════════════════════════════════════════════════════

print_summary() {
    local elapsed=$(( $(date +%s) - SCRIPT_START ))
    local minutes=$(( elapsed / 60 ))
    local seconds=$(( elapsed % 60 ))

    log_sep
    log_info "RÉSUMÉ DE MAINTENANCE"
    log_sep
    log_info "Durée totale          : ${minutes}m ${seconds}s"
    log_info "Apps sauvegardées     : ${#BACKED_UP[@]}  — ${BACKED_UP[*]:-aucune}"
    log_info "Apps mises à jour     : ${#UPDATED_APPS[@]} — ${UPDATED_APPS[*]:-aucune}"
    log_info "Avertissements        : ${WARNINGS}"
    log_info "Erreurs               : ${ERRORS}"
    log_info "Logs                  : ${LOG_FILE}"
    log_sep

    if [ "$ERRORS" -gt 0 ]; then
        log_error "MAINTENANCE TERMINÉE AVEC ${ERRORS} ERREUR(S). Vérifiez les logs !"
        exit 1
    else
        log_ok "MAINTENANCE TERMINÉE AVEC SUCCÈS ✓"
    fi
}


# ══════════════════════════════════════════════════════════════════════════════
#  POINT D'ENTRÉE
# ══════════════════════════════════════════════════════════════════════════════

main() {
    mkdir -p "$LOG_DIR"
    log_sep
    log_info "VPS MAINTENANCE — $(date '+%d/%m/%Y %H:%M:%S') — PID $$"
    log_sep

    check_requirements

    backup_docker_apps  || log_error "L'étape de backup a échoué."
    sync_to_swift       || log_error "La synchronisation Swift a échoué."
    update_system       || log_error "La mise à jour système a échoué."
    update_docker_apps  || log_error "La mise à jour Docker a échoué."

    print_summary
}

main "$@"
