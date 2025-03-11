#!/bin/bash
# Secure Solr Backup Script using Knox Authentication (Base64-Encoded Credentials) with ABFS Support

# Configuration
SOLR_KNOX_URL="https://ktalbert-solr-leader0.kt-az-so.prep-j1tk.a3.cloudera.site/ktalbert-solr/cdp-proxy-api/solr"
BACKUP_DIR="abfs://backups@ktazsolrstor6290fce2.dfs.core.windows.net/solr-backups"
LOG_FILE="/tmp/solr_backup.log"

# Knox Workload Credentials (Replace with actual workload user & password)
KNOX_USER="ktalbert"
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

log "[INFO] Starting Solr collections backup script."

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
  
  # 3a. Trigger a Hard Commit to Ensure Latest Data is Flushed to Index
  log "[INFO] Committing collection $col before backup."
  commit_resp=$(curl -kL -X GET "${SOLR_KNOX_URL}/admin/collections?action=COMMIT&collection=${col}&wt=json" -H "$AUTH_HEADER" -s -o /dev/null -w "%{http_code}")
  if [[ "$commit_resp" != "200" ]]; then
    log "[WARN] Commit request for $col returned HTTP $commit_resp (proceeding with backup anyway)."
  fi

  # 3b. Construct a Unique Backup Name (Collection Name + Timestamp)
  timestamp=$(date '+%Y%m%d%H%M%S')
  backup_name="${col}_backup_${timestamp}"
  log "[INFO] Initiating backup for $col as snapshot '$backup_name'."

  # 3c. Call Solr Collections API to Backup the Collection via Knox, specifying the backup repository
  response_json=$(curl -kL -X GET "${SOLR_KNOX_URL}/admin/collections?action=BACKUP&name=${backup_name}&collection=${col}&repository=backup&location=${BACKUP_DIR}&wt=json" -H "$AUTH_HEADER" -sS)

  if [ $? -ne 0 ] || [[ -z "$response_json" ]]; then
    log "[ERROR] Backup API call failed for collection $col (no response)."
    continue  # move to next collection
  fi

  # Check Solr API Response for Success
  status_val=$(echo "$response_json" | jq -r '.responseHeader.status' 2>/dev/null)
  if [[ "$status_val" == "0" ]]; then
    log "[INFO] Backup successful for $col. Snapshot name: $backup_name"
  else
    log "[ERROR] Backup failed for $col. Response: $response_json"
  fi
done

log "[INFO] Solr backup script completed."
