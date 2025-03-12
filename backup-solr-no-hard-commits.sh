#!/bin/bash
# Secure Solr Backup Script using Knox Authentication (Base64-Encoded Credentials)
# This version DOES NOT perform a hard commit before backing up.

# Check for required parameters
if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <KNOX_USER> <KNOX_PASS> <KNOX_URL> <STORAGE_ACCOUNT>"
  exit 1
fi

# Assign parameters to variables
KNOX_USER="$1"
KNOX_PASS="$2"
SOLR_KNOX_URL="$3"
STORAGE_ACCOUNT="$4"

# Derived Variables
BACKUP_DIR="abfs://backups@${STORAGE_ACCOUNT}.dfs.core.windows.net/solr-backups"
LOG_FILE="/tmp/solr_backup.log"

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

log "[INFO] Starting Solr collections backup script (No Hard Commit)."

# 1. Ensure Backup Directory Exists in ADLS
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

# 2. Retrieve List of Collections Using Knox Authentication
log "[INFO] Fetching list of collections from Solr via Knox..."
collections_json=$(curl -kL -X GET "${SOLR_KNOX_URL}/admin/collections?action=LIST&wt=json" -H "$AUTH_HEADER" -sS)

# Log Raw Solr Response for Debugging
log "[DEBUG] Raw response from Solr: $collections_json"

# Parse Collection Names from JSON (requires jq installed)
collections=$(echo "$collections_json" | jq -r '.collections[]' 2>/dev/null)

# Fallback to grep if jq fails
if [[ -z "$collections" ]]; then
  collections=$(echo "$collections_json" | grep -oP '"collections":\s*\[\K[^]]*' | tr -d '"' | tr ',' '\n')
fi

if [[ -z "$collections" ]]; then
  log "[ERROR] No collections found or failed to parse the collections list. Raw response: $collections_json"
  exit 4
fi
log "[INFO] Found collections: $collections"

# 3. Loop Through Each Collection and Perform Backup
for col in $collections; do
  log "[INFO] --- Backing up collection: $col ---"

  # 3a. Construct a Unique Backup Name (Collection Name + Timestamp)
  timestamp=$(date '+%Y%m%d%H%M%S')
  backup_name="${col}_backup_${timestamp}"
  log "[INFO] Initiating backup for $col as snapshot '$backup_name' (async mode)."

  # 3b. Call Solr Collections API to Backup the Collection in Async Mode
  response_json=$(curl -kL -X GET "${SOLR_KNOX_URL}/admin/collections?action=BACKUP&name=${backup_name}&collection=${col}&repository=backup&location=${BACKUP_DIR}&async=${backup_name}&wt=json" -H "$AUTH_HEADER" -sS)

  if [ $? -ne 0 ] || [[ -z "$response_json" ]]; then
    log "[ERROR] Backup API call failed for collection $col (no response)."
    continue  # move to next collection
  fi

  # Extract the async request ID
  async_request_id="$backup_name"

  # Polling for Backup Status
  log "[INFO] Polling backup status for $col..."
  while true; do
    status_resp=$(curl -kL -X GET "${SOLR_KNOX_URL}/admin/collections?action=REQUESTSTATUS&requestid=${async_request_id}&wt=json" -H "$AUTH_HEADER" -sS)

    if [ $? -ne 0 ] || [[ -z "$status_resp" ]]; then
      log "[ERROR] Failed to get backup status for $col. Response: $status_resp"
      break
    fi

    status=$(echo "$status_resp" | jq -r '.status.state' 2>/dev/null)

    case "$status" in
      "completed")
        log "[INFO] Backup completed for $col. Snapshot name: $backup_name"
        break
        ;;
      "failed")
        log "[ERROR] Backup failed for $col. Response: $status_resp"
        break
        ;;
      "running")
        log "[INFO] Backup in progress for $col... (waiting 10s)"
        sleep 10
        ;;
      *)
        log "[ERROR] Unexpected status for $col: $status"
        break
        ;;
    esac
  done
done

log "[INFO] Solr backup script completed."
