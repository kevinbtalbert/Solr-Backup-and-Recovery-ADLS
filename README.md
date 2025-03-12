# Solr-Backup-and-Recovery-ADLS
Backup and Recovery for Solr via ADLS on CDP Solr DH

## Backup

```bash
KNOX_USER="$1"
KNOX_PASS="$2"
SOLR_KNOX_URL="$3"
STORAGE_ACCOUNT="$4"
```

Usage: `bash backup-solr.sh` *(fill variables inline)*

Usage: `bash backup-solr-with-hard-commits.sh KNOX_USER KNOX_PASS SOLR_KNOX_URL STORAGE_ACCOUNT`

Usage: `bash backup-solr-no-hard-commits.sh KNOX_USER KNOX_PASS SOLR_KNOX_URL STORAGE_ACCOUNT`

Example: `bash backup-solr-with-hard-commits.sh my_knox_user my_knox_pass "https://my-solr-knox-url" my_storage_account`

![](/screenshots/usage-screenshot-backup.png)

## Restore

Usage: `bash restore-solr-from-adls.sh` *(fill variables inline)*

![](/screenshots/usage-screenshot-restore.png)

## Prerequisites

Azure xaccount role or similar app registration with a declared client ID/secret and Storage Blob Data Owner

Need Application (Client) ID, Tenant ID, Application (can be xaccount-app), Secret VALUE (only shown once when created and has time expiry)

### Add Permissions to Application for Storage Account

![](/screenshots/screenshot-1.png)

Add **Storage Blob Data Owner** to the Application being used. 

![](/screenshots/screenshot-2.png)

From App Registration, get **Application (client) ID** and **Directory (tenant) ID**

![](/screenshots/screenshot-3.png)

From the Client Secret page, save the Client Secret Value created (only shown once)

![](/screenshots/screenshot-4.png)

Identify and save Knox URL from Solr Datahub (follow Knox and use endpoint like example below):
`SOLR_KNOX_URL="https://<FQDN OF SOLR LEADER>/ktalbert-solr/cdp-proxy-api/solr"`

![](/screenshots/screenshot-knox.png)


## Changes to Cloudera Manager on Solr Datahub

### Add Config changes to Cloudera Manager and redeploy Solr following below guidance

Navigate: Cloudera Manager >> Solr >> Configuration

Search Java config and add to solr_java_opts property: `{{JAVA_GC_ARGS}} -Dsolr.hdfs.allow.location.override=true`

![](/screenshots/screenshot-5.png)

Search for **core-site.xml** and paste below to config (click **"View as XML"**):

```xml
<property>
   <name>fs.abfs.impl</name>
   <value>org.apache.hadoop.fs.azurebfs.AzureBlobFileSystem</value>
</property>
<property>
   <name>fs.azure.account.auth.type.STORAGE_BUCKET_NAME_HERE.dfs.core.windows.net</name>
   <value>OAuth</value>
</property>
<property>
   <name>fs.azure.account.oauth.provider.type.STORAGE_BUCKET_NAME_HERE.dfs.core.windows.net</name>
   <value>org.apache.hadoop.fs.azurebfs.oauth2.ClientCredsTokenProvider</value>
</property>
<property>
   <name>fs.azure.createRemoteFileSystemDuringInitialization</name>
   <value>true</value>
</property>
<property>
   <name>fs.azure.account.oauth2.client.id.STORAGE_BUCKET_NAME_HERE.dfs.core.windows.net</name>
   <value>YOUR_CLIENT_ID_HERE</value>
</property>
<property>
   <name>fs.azure.account.oauth2.client.secret.STORAGE_BUCKET_NAME_HERE.dfs.core.windows.net</name>
   <value>SECRET_VALUE_HERE</value>
</property>
<property>
   <name>fs.azure.account.oauth2.client.endpoint.STORAGE_BUCKET_NAME_HERE.dfs.core.windows.net</name>
   <value>https://login.microsoftonline.com/TENANT_ID_HERE/oauth2/token</value>
</property>
```

![](/screenshots/screenshot-6.png)

![](/screenshots/screenshot-7.png)

Restart Solr/Datahub and redeploy client configuration.

### Approach 1: Add/execute script from Solr leader node (or similar in environment)
This script HARD commits before backup, there is also one in the repo which does not commit before taking a backup.
[backup-solr.sh](backup-solr.sh) -- uses inline variables to run
[backup-solr-with-hard-commits.sh](backup-solr-with-hard-commits.sh) -- uses parameter syntax to run (same as backup-solr.sh other than this)
[backup-solr-no-hard-commits.sh](backup-solr-no-hard-commits.sh) -- uses parameter syntax to run (no hard commits)

There is also a script in the repo for recovering from ADLS:
[restore-solr-from-adls.sh](restore-solr-from-adls.sh)  --  uses inline variables to run


### Approach 2: Schedule using NiFi
WIP (will be posted soon)


### Why does this work?
We make use of the “backup” repository in the solr.xml file provisioned with the Datahub along with CM changes to avoid creating a new repository. This should only be done with the Datahub Solr since the Datalake Solr makes use of this for Audit log rolling etc.

`solrctl cluster --get-solrxml /tmp/solr.xml`

![](/screenshots/screenshot-cdp-datahub-solr-xml.png)

### Where can I find the backups?
Files are stored in ADLS in the assigned Storage bucket you selected: Backups >> solr-backups

![](/screenshots/screenshot-8.png)

![](/screenshots/screenshot-9.png)