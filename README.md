# Automated Couchbase Cluster Health Reporting Pipeline

Production-grade Bash automation that collects health metrics across multiple Couchbase clusters and generates structured HTML reports for operational monitoring.

This automation reduced manual cluster reporting effort from **~2 hours to ~5 minutes** and runs in production via **AutoSys scheduling**, ensuring reliable and consistent reporting across environments.

---

## Overview

This project automates the collection, transformation, and reporting of Couchbase cluster health metrics across multiple environments.

The script:
- Fetches node-level metrics via Couchbase REST APIs  
- Parses JSON responses using `jq`  
- Generates CSV and formatted HTML reports  
- Highlights threshold breaches (disk, RAM, swap, uptime)  
- Sends automated email reports to stakeholders  
- Runs via **AutoSys scheduled jobs** in production  

Designed for reliability, observability, and unattended execution.

---

## Key Features

- Multi-cluster health metric collection  
- REST API integration with Couchbase nodes  
- Defensive Bash scripting (`set -euo pipefail`)  
- Timeout-protected API calls  
- JSON parsing using `jq`  
- CSV → HTML report generation  
- Threshold-based anomaly highlighting  
- Timezone-aware reporting logic  
- Automated email delivery via sendmail  
- **AutoSys job scheduling integration**
- Cron-compatible execution  
- Production-safe file and permission handling  

---

## Tech Stack

- Bash scripting  
- jq  
- curl  
- awk / sed  
- sendmail  
- Linux  
- AutoSys Scheduler  
- Couchbase REST APIs  

---

## Impact

- Reduced manual reporting time from **2 hours → 5 minutes**
- Eliminated manual cluster checks
- Standardized health reporting
- Enabled proactive monitoring
- Improved operational reliability

---

## Architecture Flow

1. Read cluster configuration  
2. Query Couchbase REST APIs  
3. Parse metrics using jq  
4. Generate CSV dataset  
5. Convert CSV → HTML report  
6. Highlight threshold breaches  
7. Email report to stakeholders  
8. Cleanup temp files  

---

## Configuration File

The script reads cluster details from:

### Example format

```json
{
  "clusters": [
    {
      "clusterusername": "username1",
      "clusterpassword": "password1",
      "clusterurl": "http://cluster1:8091",
      "clustername": "Cluster-A"
    },
    {
      "clusterusername": "username2",
      "clusterpassword": "password2",
      "clusterurl": "http://cluster2:8091",
      "clustername": "Cluster-B"
    }
  ]
}
```

## Execution

### Run manually:

```bash
bash cluster_report.sh
```

### Run via cron (example: every day at 7 AM):

```bash
0 7 * * * /path/to/cluster_report.sh
```
