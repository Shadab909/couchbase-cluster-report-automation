#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# SAFETY CHECKS
# -----------------------------------------------------------------------------
# sets error handling policy throughout the script
# -e -> exit immediately if a command exits with a non-zero status (error).
# -u -> treat unset variables as an error and exit immediately.
# -o pipefail -> ensures that if any command in a pipeline fails, the whole pipe fails.
set -euo pipefail

# -----------------------------------------------------------------------------
# TIME AND DATE SETUP
# -----------------------------------------------------------------------------
# Default period is set to "ist_morning"
PERIOD="ist_morning"

# Get today's date (Year-Month-Day) and the current hour (00-23)
TODAY=$(date +%Y-%m-%d)
HOUR=$(date +%H)

# Hour is of form (01, 02, 03 ..). But numbers starting with 0 is considered octal in bash 
# and we want normal decimal number so "10#$Variable" turns variable into decimal form 
# ie 01 -> 1 or 02 -> 2. This prevents math errors later.
HOUR=$((10#$HOUR))

# Check if the time is between 7 AM (inclusive) and 4 PM (exclusive).
# If so, switch the period to "est_morning".
# C style if block comparison
if (( 7 <= HOUR && HOUR < 16 )); then
    PERIOD="est_morning"
fi 

# -----------------------------------------------------------------------------
# FILE AND DIRECTORY PATHS
# -----------------------------------------------------------------------------
# Handle files and folder
WDIR="/opt/scripts/DailyReport"
DATA_DIR="$WDIR/DailyClusterData"
CSV_DATA_DIR="${DATA_DIR}/${TODAY}"

# Define the filenames for the output data
PERIOD_WISE_FILE="${PERIOD}_cluster_data.csv"
CSV_DATA_FILE="${CSV_DATA_DIR}/${PERIOD_WISE_FILE}"
HTML_FILE="$WDIR/temp.html"

# "! -d" means if directory in variable does not exist. Similarly -f signifies file checking.
if [ ! -d "$CSV_DATA_DIR" ]; then
    # mkdir with "-p" flag creates all parent directories in path if they don't exist
    mkdir -p "$CSV_DATA_DIR"
fi 

# Files is an array with mentioned variables as indexed values
FILES=($HTML_FILE $CSV_DATA_FILE)

# We can loop over values in an array like -> "${my_Array[@]}", this will spit out all the values.
# This loop clears the files if they exist or creates empty ones if they don't.
for file in "${FILES[@]}"; do
    echo "Preparing file :$file"
    # ": >" is a shortcut that truncates a file (empties it) to length 0.
    : > "$file"
done

# Ensure the directories and files have the correct permissions (read/write/execute for owner, read/execute for others)
chmod -R 755 "$DATA_DIR" "$CSV_DATA_DIR" "$CSV_DATA_FILE" 

# Initialize the CSV file with the Header Row
echo "date,period,cluster,HOSTNAME,HEALTH,DISK_UTIL,MEM_UTIL,SWAP_UTIL,CB_UPTIME,CB_SERVICE" > "$CSV_DATA_FILE" 

# -----------------------------------------------------------------------------
# DATA COLLECTION (MAIN LOOP)
# -----------------------------------------------------------------------------
CLUSTER_CONFIG="$WDIR/cluster-config.json"

# jq is a command-line JSON processor. 
# '.clusters | length' counts how many objects are inside the "clusters" array in the config file.
cluster_count=$(jq '.clusters | length' "$CLUSTER_CONFIG") 

# Loop through each cluster defined in the config file
for ((i=0;i<cluster_count;i++)); do
    
    # Extract credentials and details for the current cluster using the index ($i)
    username=$(jq -r --argjson idx "$i" '.clusters[$idx].clusterusername' "$CLUSTER_CONFIG")
    password=$(jq -r --argjson idx "$i" '.clusters[$idx].clusterpassword' "$CLUSTER_CONFIG")
    url=$(jq -r --argjson idx "$i" '.clusters[$idx].clusterurl' "$CLUSTER_CONFIG")
    clustername=$(jq -r --argjson idx "$i" '.clusters[$idx].clustername' "$CLUSTER_CONFIG")

    echo "Finding all hosts for ${clustername} cluster at ${url}"
    
    # 1. First API Call: Get the list of all nodes (servers) in the cluster
    # -sS: Silent but show errors. --connect-timeout: Fail if connection takes too long.
    resp=$(curl -sS --connect-timeout 5 --max-time 10 -u "$username:$password" "$url/pools/nodes")
    
    # Check if curl failed ($? is not 0) or if the response is empty (-z)
    if [[ $? -ne 0 || -z "$resp" ]]; then
        echo "${TODAY},${PERIOD},${clustername},Error,,,," >> "$CSV_DATA_FILE"
        echo "curl failed or empty response for $url">&2
        continue # Skip to the next cluster
    fi [4]

    # Extract the list of hostnames from the JSON response
    url_list=$(jq -r '.nodes[].hostname' <<<"$resp")

    if [[ -z "$url_list" ]]; then
        echo "No hostname found in pools/nodes for $url"
        continue
    fi

    # Load the list of URLs into a bash array named 'url_list_array'
    mapfile -t url_list_array <<< "$url_list"

    # Loop through each specific host (server) in the current cluster
    for full_host in "${url_list_array[@]}"; do

        echo "Finding health metrics for ${full_host} in ${clustername} cluster"

        # 2. Second API Call: Get detailed stats for this specific node
        node_json=$(curl -sS --connect-timeout 5 --max-time 10 -u "$username:$password" "http://${full_host}/nodes/self")
        
        # Clean up the server name (remove port numbers and domain parts)
        servername_fqdn=$(echo "$full_host" | cut -d':' -f1)
        servername=$(echo "$servername_fqdn" | cut -d'.' -f1)

        # Error handling for the node-specific call
        if [[ $? -ne 0 || -z "$node_json" ]]; then
            echo "${TODAY},${PERIOD},${clustername},${servername},Failure,-,-,-,-,-" >> "$CSV_DATA_FILE"
            echo "curl failed or empty response for http://${full_host}/pools/nodes" >&2
            continue
        fi 

        # ---------------------------------------------------------------------
        # PARSING METRICS WITH JQ
        # ---------------------------------------------------------------------
        status=$(jq -r '.status' <<< "$node_json")

        # Map internal Couchbase service names (kv, n1ql) to human-readable names (Data, Query)
        services=$(jq -r '.services 
                    | map({
                        kv : "Data",
                        index: "Index",
                        n1ql: "Query",
                        fts: "Search",
                        cbas: "Analytics",
                        eventing: "Eventing"
                    }[.] // . ) | join("+")' <<< "$node_json") 

        # Extract Raw Numbers
        # We use 'tonumber' to ensure jq treats them as numbers.
        # ${variable%\r} removes any carriage return characters that might sneak in.
        mem_total=$(jq -r '(.memoryTotal | tonumber)' <<< "$node_json")
        mem_total="${mem_total%\r}"
        mem_free=$(jq -r '(.memoryFree | tonumber)' <<< "$node_json")
        mem_free="${mem_free%\r}"
        
        swap_total=$(jq -r '(.systemStats.swap_total | tonumber)' <<< "$node_json")
        swap_total="${swap_total%\r}"
        swap_used=$(jq -r '(.systemStats.swap_used | tonumber)' <<< "$node_json")
        swap_used="${swap_used%\r}"
        
        # Calculate Uptime in Days (seconds / 86400)
        uptime=$(jq -r '"\(.uptime | tonumber /86400 | floor) days(s)"' <<< "$node_json")
        
        # Get Disk usage specifically for the /opt/appdata path
        disk_pct=$(jq '.availableStorage.hdd[] | select(.path=="/opt/appdata") | .usagePercent' <<< "$node_json")

        # Calculate Memory Percentage: ((Total - Free) * 100) / Total
        mem_pct=$(
            echo "$node_json" | jq -r '
            ((.systemStats.mem_total // .memoryTotal) | tonumber) as $t |
            ((.systemStats.mem_free // .memoryFree) | tonumber) as $f |
            if $t > 0 then ((($t-$f)*100/$t) | floor) else 0 end'
        )

        # Calculate Swap Percentage: (Used * 100) / Total
        swap_pct=$(
            echo "$node_json" | jq -r '
            (.systemStats.swap_total | tonumber) as $t |
            (.systemStats.swap_used | tonumber) as $u |
            if $t > 0 then (($u*100/$t) | floor) else 0 end'
        ) 

        # Add percentage signs
        mem_pct="${mem_pct}%"
        swap_pct="${swap_pct}%"
        disk_pct="${disk_pct}%"

        # Append the calculated row to the CSV file
        echo "${TODAY},${PERIOD},${clustername},${servername},${status},${disk_pct},${mem_pct},${swap_pct},${uptime},${services}" \
        >> "$CSV_DATA_FILE"

    done

    # Add a blank line between clusters in the CSV for readability
    echo " " >> "$CSV_DATA_FILE"

done

echo "CSV Data Prepared"

# -----------------------------------------------------------------------------
# HTML REPORT GENERATION
# -----------------------------------------------------------------------------

# Create the HTML header and CSS styles.
# using 'cat <<HTML_HDR' allows us to paste a large block of text into the file until we write 'HTML_HDR' again.
cat >"$HTML_FILE" <<'HTML_HDR'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<style>
body{font-family: Arial,Helvetica,sans-serif; font-size:13px; color:#222;}
table{border-collapse:collapse; width:100%; max-width:1000px;}
th,td{border:1px solid #ddd; padding:8px; text-align:left; vertical-align:top;}
th{background:#004080; color:#fff; padding-top:10px; padding-bottom:10px;}
tr:nth-child(even) {background:#f9f9f9;}
tr:hover{background:#f1f1f1;}
small{color:#555;}
caption{
font-family: Arial,Helvetica,sans-serif;
font-size:14px;
font-weight:bold;
background:#004080;
color:#fff;
text-align:left;
vertical-align:center;
}
</style>
</head>
<body>
<p>Auto-Generated Report. Please do not reply.<p>
<p>Generated At: <!--DATE--><p>
<br>
<p>Hi Team,<br><br>Please find the latest health metrics of all Couchbase Platform PROD & COB clusters.-
<p>
HTML_HDR

# Replace the <!--DATE--> placeholder with the actual date/time in Toronto (EST) time.
sed -i "s/<!--DATE-->/$(TZ=America/Toronto date +'%Y-%m-%d %I:%M %p %Z')/" "$HTML_FILE" 


# -----------------------------------------------------------------------------
# FUNCTION: Convert CSV to HTML Table
# -----------------------------------------------------------------------------
append_csv_table(){
    local CSV_FILE="$1"
    local TABLE_TITLE="$2:-"
    local tmp_tbl
    
    # Create a temporary file to build the table
    tmp_tbl="$(mktemp $WDIR/csv_table.XXXXXX)"

    {
        printf '<table>\n'
        
        # If a title is provided, create a Table Caption
        if [[ -n "$TABLE_TITLE" ]]; then
            # Escape HTML special characters (&, <, >, ", ') to prevent broken HTML
            esc_title=$(printf '%s' "$TABLE_TITLE" | awk '
                {
                    s=$0
                    gsub(/&/, "&amp;",s)
                    gsub(/</, "&lt;",s)
                    gsub(/>/, "&gt;",s)
                    gsub(/"/, "&quot;",s)
                    gsub(/\x27/, "&#39;",s)
                    print s
                }')
            
            printf '<caption>%s</caption>\n' "$esc_title"
        fi 

        # Process the Header Row (first line of CSV)
        head -n1 "$CSV_FILE" | awk '
        BEGIN {FS=","}
        function esc(s){
        gsub(/&/,"&amp;",s)
        gsub(/</,"&lt;",s)
        gsub(/>/,"&gt;",s)
        gsub(/"/,"&quot;",s)
        return s
        }
        {
        printf "<thead>\n<tr>"
        for(i=4;i<=NF;i++){
             v=$i; gsub(/^[\t]+|[\t]+$/,"",v)
             printf "<th>%s</th>", esc(v)
             }
             print "</tr>\n</thead>"
        }' 

        # Process the Body Rows (highlighting issues)
        printf '<tbody>\n'
        tail -n +2 "$CSV_FILE" | awk '
        BEGIN {
            FS=","; OFS=",";
            warn="#ffff00" # Yellow background for warnings

            # Define Thresholds for alerting
            disk_col=6; disk_t=75   # Alert if Disk > 75%
            ram_col=7; ram_t=80     # Alert if RAM > 80%
            swap_col=8; swap_t=0    # Alert if Swap > 0%
            up_col=9; up_t=30       # Alert if Uptime > 30 days
        }
        function esc(s){
        gsub(/&/,"&amp;",s)
        gsub(/</,"&lt;",s)
        gsub(/>/,"&gt;",s)
        gsub(/"/,"&quot;",s)
        return s
        }
        # Function to clean numbers for comparison
        function num(s,n){
        gsub(/[\r]/,"",s)
        if(match(s,/+(\.+)?/)) n=substr(s,RSTART,RLENGTH); else n=0
        return n+0
        }
        # Function to print Cell (td) with or without warning color
        function td(val,hit){
        if(hit) printf "<td style=\"background:%s\">%s</td>",warn,esc(val); else printf "<td>%s</td>",esc(val);
        }
        {
        printf "<tr>"
        for(i=4;i<=NF;i++){
            v=$i
            hit=0
            # Check thresholds
            if(i==disk_col && num(v) >= disk_t) hit=1
            if(i==ram_col && num(v) >= ram_t) hit=1
            if(i==swap_col && num(v) > swap_t) hit=1
            if(i==up_col && num(v) >= up_t) hit=1
            td(v,hit)
        }
        print "</tr>"
        }' 
        
        printf '</tbody>\n</table>\n'
        printf '<br>'
    } >"$tmp_tbl"

    # Insert the generated table into the main HTML file
    # It attempts to insert it *before* the </body> tag.
    if grep -qi '</body>' "$HTML_FILE"; then
        awk -v tbl="$tmp_tbl" '
            BEGIN{
                while ((getline line < tbl) > 0) {t[++n] = line}
                close(tbl)
            }
            {
            if(!inserted && tolower($0) ~ /<\/body>/){
                for(i=1;i<=n;i++) print t[i]
                print $0
                inserted=1
            } else {
                print $0
            }
            }' "$HTML_FILE" > "${HTML_FILE}.tmp" && mv "${HTML_FILE}.tmp" "$HTML_FILE"
    else
        cat "$tmp_tbl" >> "$HTML_FILE"
    fi 

    rm -f "$tmp_tbl"
    return 0
}

# -----------------------------------------------------------------------------
# SPLITTING DATA AND BUILDING REPORT
# -----------------------------------------------------------------------------
# This awk block reads the big CSV file and splits it into smaller files
# named cluster_1.csv, cluster_2.csv based on the cluster name column.

mapfile -t cluster_csv_files << (
    awk '
    NF == 0 { file++; next }

    NR == 1 { header = $0; next }
        {
            if(!(file in seen)) {
                fname = sprintf("cluster_%d.csv",file)
                print fname
                print header > fname
                seen[file] = fname
            }
            print >> seen[file]
        }' "$CSV_DATA_FILE"
) 

# Loop through the split files and append them as tables to the HTML report
for i in "${!cluster_csv_files[@]}"; do
    f="${cluster_csv_files[$i]}"
    clustername=$(jq -r --argjson idx "$i" '.clusters[$idx].clustername' "$CLUSTER_CONFIG")
    append_csv_table "$f" "${clustername} Cluster"
done 

echo "</body></html>" >> "$HTML_FILE"

# -----------------------------------------------------------------------------
# EMAIL NOTIFICATION LOGIC
# -----------------------------------------------------------------------------
ERROR="0"
FROM="report@couchbase"

if [[ $PERIOD == "ist_morning" ]]; then
    # Its IST-TIME (Indian Standard Time)
    
    SUBJECT="Couchbase Platform PROD & COB Cluster Health Report : $TODAY"
    
    RECEPIENT=""
    #RECEPIENT="dummy" # Commented out placeholder
    
    # Send the email using sendmail. 
    # We pipe the HTML content directly into the sendmail command.
    {
    printf 'FROM: %s\n' "$FROM"
    printf 'To: %s\n' "$RECEPIENT"
    printf 'Subject: %s\n' "$SUBJECT"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: text/html; charset="UTF-8"\n'
    printf '\n'
    cat "$HTML_FILE"
    } | sendmail -t -oi
    
    if [[ $? -eq 0 ]]; then
        echo "IST Email sent to $RECEPIENT."
    else
        ERROR="1"
        echo "Failed to send IST mail." >&2
    fi

else
    # Its EST-TIME (Eastern Standard Time)

    SUBJECT="Couchbase Platform PROD & COB Cluster Health Report : $TODAY"
    
    # Email Leaders
    RECEPIENT="dummy"
    CC="dummy"
    
    {
    printf 'FROM: %s\n' "$FROM"
    printf 'To: %s\n' "$RECEPIENT"
    printf 'Cc: %s\n' "$CC"
    printf 'Subject: %s\n' "$SUBJECT"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: text/html; charset="UTF-8"\n'
    printf '\n'
    cat "$HTML_FILE"
    } | sendmail -t -oi
    
    if [[ $? -eq 0 ]]; then
        echo "EST Leaders Email sent to $RECEPIENT."
    else
        ERROR="1"
        echo "Failed to send EST Leaders mail." >&2
    fi 
    
    # Email PS & L2 Support
    RECEPIENT="dummy"
    CC="dummy"
    
    {
    printf 'FROM: %s\n' "$FROM"
    printf 'To: %s\n' "$RECEPIENT"
    printf 'Cc: %s\n' "$CC"
    printf 'Subject: %s\n' "$SUBJECT"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: text/html; charset="UTF-8"\n'
    printf '\n'
    cat "$HTML_FILE"
    } | sendmail -t -oi
    
    if [[ $? -eq 0 ]]; then
        echo "EST PS&L2 Email sent to $RECEPIENT"
    else
        ERROR="1"
        echo "Failed to send EST PS&L2 mail." >&2
    fi 
fi

# -----------------------------------------------------------------------------
# CLEANUP AND EXIT
# -----------------------------------------------------------------------------
# Remove the temporary HTML file and the split CSV files to keep the folder clean

rm -f "$HTML_FILE"
rm -f cluster_*.csv

if [[ $ERROR == "0" ]]; then
    exit 0 # Success
else
    exit 3 # Failure code
fi 