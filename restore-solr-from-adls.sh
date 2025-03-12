#!/bin/bash
# Secure Solr Restore Script using Knox Authentication (Base64-Encoded Credentials)

# Configuration
SOLR_KNOX_URL="https://SOLR_LEADER_NODE_FQDN.cloudera.site/ktalbert-solr/cdp-proxy-api/solr"
BACKUP_DIR="abfs://backups@STORAGE_ACCOUNT_HERE.dfs.core.windows.net/solr-backups"
LOG_FILE="/tmp/solr_backup.log"

# Knox Workload Credentials (Replace with actual workload user & password)
KNOX_USER="username"
KNOX_PASS="enterpasswordhere"

# Base64-encode the credentials
AUTH_HEADER="Authorization: Basic $(echo -n "${KNOX_USER}:${KNOX_PASS}" | base64)"

# Ensure log file exists
if [ ! -f "$LOG_FILE" ]; then
  touch "$LOG_FILE"
  if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Cannot create log file at $LOG_FILE. Exiting."
    exit 1
  fi
fi

# Log function
log() {
  local msg="$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" | tee -a "$LOG_FILE"
}

log "[INFO] Starting Solr collections restore script."

# 1. List Available Backups in ADLS
log "[INFO] Listing available backups in ADLS..."
backup_files=$(hdfs dfs -ls "$BACKUP_DIR" | awk '{print $NF}' | grep -E ".*_backup_[0-9]{14}$")

if [[ -z "$backup_files" ]]; then
  log "[ERROR] No backup files found in ADLS. Exiting."
  exit 2
fi

log "[INFO] Found backups: "
echo "$backup_files" | tee -a "$LOG_FILE"

# 2. Prompt User for Restore Action
echo "Would you like to restore (A)ll backups or (S)elect specific ones? [A/S]: "
read -r restore_option

if [[ "$restore_option" == "S" || "$restore_option" == "s" ]]; then
  echo "Enter the backup names you want to restore (comma-separated, e.g., sample_collection_1_backup_20250312020925): "
  read -r selected_backups
  selected_backups=($(echo "$selected_backups" | tr ',' ' '))
else
  selected_backups=($(echo "$backup_files"))
fi

# 3. Loop Through Each Selected Backup and Restore
for backup_path in "${selected_backups[@]}"; do
  backup_name=$(basename "$backup_path")
  collection_name=$(echo "$backup_name" | sed 's/_backup_[0-9]\{14\}$//')

  log "[INFO] Restoring collection: $collection_name from backup: $backup_name"

  # Verify if the backup path exists in ADLS
  hdfs dfs -test -d "${BACKUP_DIR}/${backup_name}"
  if [ $? -ne 0 ]; then
    log "[ERROR] Backup path ${BACKUP_DIR}/${backup_name} does not exist. Skipping restore."
    continue
  fi

  # 3a. Call Solr Collections API to Restore the Collection via Knox
  response_json=$(curl -kL -X GET "${SOLR_KNOX_URL}/admin/collections?action=RESTORE&name=${backup_name}&collection=${collection_name}&location=${BACKUP_DIR}&repository=backup&wt=json" -H "$AUTH_HEADER" -sS)

  if [ $? -ne 0 ] || [[ -z "$response_json" ]]; then
    log "[ERROR] Restore API call failed for collection $collection_name (no response)."
    continue  # move to next collection
  fi

  # Check Solr API Response for Success
  status_val=$(echo "$response_json" | jq -r '.responseHeader.status' 2>/dev/null)
  if [[ "$status_val" == "0" ]]; then
    log "[INFO] Restore successful for $collection_name from backup: $backup_name"
  else
    log "[ERROR] Restore failed for $collection_name. Response: $response_json"
  fi
done

log "[INFO] Solr restore script completed."
