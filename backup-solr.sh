#!/bin/bash
# Bash script to back up all Solr collections to Azure Data Lake Storage (ADLS)

# Configuration
SOLR_URL="https://ktalbert-solr-leader0.kt-az-so.prep-j1tk.a3.cloudera.site/ktalbert-solr/cdp-proxy/solr"  # Base URL for Solr on this node
BACKUP_DIR="abfs://backups@ktazsolrstor6290fce2.dfs.core.windows.net/solr-backups"  # Updated ADLS path
LOG_FILE="/var/log/solr_backup.log"    # Log file for recording backup actions

# Ensure log file exists (create it if missing)
if [ ! -f "$LOG_FILE" ]; then
  touch "$LOG_FILE"
  if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Cannot create log file at $LOG_FILE. Exiting."
    exit 1
  fi
fi

# Log a message (echo to console and log file)
log() {
  local msg="$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" | tee -a "$LOG_FILE"
}

log "[INFO] Starting Solr collections backup script."

# 1. Ensure the backup directory exists in ADLS
log "[INFO] Checking if backup directory exists: $BACKUP_DIR"
hdfs dfs -test -d "$BACKUP_DIR"
if [ $? -ne 0 ]; then
  log "[INFO] Backup directory does not exist. Creating it..."
  hdfs dfs -mkdir -p "$BACKUP_DIR"
  if [ $? -ne 0 ]; then
    log "[ERROR] Failed to create backup directory in ADLS. Exiting."
    exit 2
  fi
  log "[INFO] Backup directory created successfully."
else
  log "[INFO] Backup directory already exists."
fi

# 2. Retrieve list of all collections
log "[INFO] Fetching list of collections from Solr..."
collections_json=$(curl -sS "${SOLR_URL}/admin/collections?action=LIST&wt=json")
if [ $? -ne 0 ] || [[ -z "$collections_json" ]]; then
  log "[ERROR] Failed to retrieve collections list from Solr."
  exit 3
fi

# Parse collection names from JSON (requires jq installed)
collections=$(echo "$collections_json" | jq -r '.collections[]' 2>/dev/null)
if [[ -z "$collections" ]]; then
  log "[ERROR] No collections found or failed to parse the collections list."
  exit 4
fi
log "[INFO] Found collections: $collections"

# 3. Loop through each collection and perform backup
for col in $collections; do
  log "[INFO] --- Backing up collection: $col ---"
  
  # 3a. Trigger a hard commit to ensure latest data is flushed to index
  log "[INFO] Committing collection $col before backup."
  commit_resp=$(curl -s -o /dev/null -w "%{http_code}" "${SOLR_URL}/${col}/update?commit=true")
  if [[ "$commit_resp" != "200" ]]; then
    log "[WARN] Commit request for $col returned HTTP $commit_resp (proceeding with backup anyway)."
  fi

  # 3b. Construct a unique backup name (collection name + timestamp)
  timestamp=$(date '+%Y%m%d%H%M%S')
  backup_name="${col}_backup_${timestamp}"
  log "[INFO] Initiating backup for $col as snapshot '$backup_name'."

  # 3c. Call Solr Collections API to backup the collection
  response_json=$(curl -sS "${SOLR_URL}/admin/collections?action=BACKUP&name=${backup_name}&collection=${col}&location=${BACKUP_DIR}&wt=json")
  if [ $? -ne 0 ] || [[ -z "$response_json" ]]; then
    log "[ERROR] Backup API call failed for collection $col (no response)."
    continue  # move to next collection
  fi

  # Check Solr API response for success
  status_val=$(echo "$response_json" | jq -r '.responseHeader.status' 2>/dev/null)
  if [[ "$status_val" != "0" ]]; then
    # If jq failed (not installed), try a text search for status":0
    if [[ -z "$status_val" ]] && echo "$response_json" | grep -q '"status":[[:space:]]*0'; then
      status_val="0"
    fi
  fi

  if [[ "$status_val" == "0" ]]; then
    log "[INFO] Backup successful for $col. Snapshot name: $backup_name"
  else
    log "[ERROR] Backup failed for $col. Response: $response_json"
  fi
done

log "[INFO] Solr backup script completed."
