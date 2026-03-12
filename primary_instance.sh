#!/bin/bash
set -euo pipefail

# ----------------------------
# On my honor, as an Aggie, I have neither given nor received unauthorized assistance on this assignment.
# I further affirm that I have not and will not provide this code to any person, platform, or repository,
# without the express written permission of Dr. Gomillion.
# I understand that any violation of these standards will have serious repercussions.
# ----------------------------

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

touch /root/1-script-started

# ----------------------------
# Progress Logging (clean STEP banners + status lines only)
# ----------------------------

ProgressLog="/var/log/user-data-progress.log"
touch "$ProgressLog"
chmod 644 "$ProgressLog"

TotalSteps=8
CurrentStep=0

NextStep() {
  CurrentStep=$((CurrentStep+1))
  Percent=$((CurrentStep*100/TotalSteps))
  {
    echo ""
    echo "=================================================="
    echo "STEP $CurrentStep of $TotalSteps  [$Percent%]"
    echo "$1"
    echo "=================================================="
  } | tee -a "$ProgressLog"
}

LogStatus() {
  echo "Status: $1" | tee -a "$ProgressLog"
}

# ----------------------------
# SSH Watcher: smooth ASCII bar + STEP X/8 + label + spinner (no blinking)
# Usage after SSH: watchud
# Auto-exits at STEP 8 with 10s countdown
# ----------------------------

cat > /usr/local/bin/watch-userdata-progress <<'EOF'
#!/bin/bash
set -u

ProgressLog="/var/log/user-data-progress.log"
TotalBarWidth=24
RefreshSeconds=0.5

if [ ! -f "$ProgressLog" ]; then
  echo "Progress log not found: $ProgressLog"
  exit 1
fi

# Colors only when output is a real terminal
if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_CYAN=$'\033[36m'
  C_YELLOW=$'\033[33m'
  C_GREEN=$'\033[32m'
else
  C_RESET=""
  C_DIM=""
  C_BOLD=""
  C_CYAN=""
  C_YELLOW=""
  C_GREEN=""
fi

Cols=$(tput cols 2>/dev/null || echo 120)

DrawBar() {
  local Percent="$1"
  local Filled=$((Percent * TotalBarWidth / 100))
  local Empty=$((TotalBarWidth - Filled))

  printf "["
  if [ "$Filled" -gt 0 ]; then
    printf "%s" "${C_CYAN}"
    printf "%0.s#" $(seq 1 "$Filled")
    printf "%s" "${C_RESET}"
  fi
  if [ "$Empty" -gt 0 ]; then
    printf "%s" "${C_DIM}"
    printf "%0.s-" $(seq 1 "$Empty")
    printf "%s" "${C_RESET}"
  fi
  printf "] %s%%" "$Percent"
}

GetLatestStepLine() {
  grep -E "STEP [0-9]+ of [0-9]+  \[[0-9]+%\]" "$ProgressLog" 2>/dev/null | tail -n 1 || true
}

GetLatestPercent() {
  local line
  line="$(GetLatestStepLine)"
  if [ -n "$line" ]; then
    echo "$line" | sed -n 's/.*\[\([0-9]\+\)%\].*/\1/p'
  else
    echo "0"
  fi
}

GetLatestStepNumbers() {
  local line
  line="$(GetLatestStepLine)"
  if [ -n "$line" ]; then
    echo "$line" | sed -n 's/STEP \([0-9]\+\) of \([0-9]\+\).*/\1 \2/p'
  else
    echo "0 0"
  fi
}

GetLatestLabel() {
  awk '/STEP [0-9]+ of [0-9]+  \[[0-9]+%\]/{getline; print}' "$ProgressLog" 2>/dev/null | tail -n 1 || true
}

RenderLine() {
  local Percent="$1"
  local StepNow="$2"
  local StepTotal="$3"
  local Label="$4"
  local Frame="$5"

  local Bar StepText Text
  Bar="$(DrawBar "$Percent")"

  if [ "${StepTotal:-0}" -gt 0 ]; then
    StepText="${C_GREEN}STEP ${StepNow}/${StepTotal}${C_RESET}"
  else
    StepText=""
  fi

  Text="${C_BOLD}Deploying${C_RESET} ${Bar}  ${StepText}  ${C_YELLOW}${Label}${C_RESET}  ${Frame}"

  # Print one line, padded to terminal width to overwrite previous content (no flicker)
  printf "\r%-*s" "$Cols" "$Text"
}

echo ""
echo "${C_BOLD}Watching EC2 user-data progress${C_RESET} (Ctrl+C to stop)"
echo ""

# Show some context
tail -n 20 "$ProgressLog" 2>/dev/null || true

LastLineCount=$(wc -l < "$ProgressLog" 2>/dev/null || echo 0)

TargetPercent="$(GetLatestPercent)"
ShownPercent="$TargetPercent"
read -r StepNow StepTotal <<<"$(GetLatestStepNumbers)"
CurrentLabel="$(GetLatestLabel)"
[ -z "${CurrentLabel:-}" ] && CurrentLabel="Starting..."

i=0
frames='|/-\'

while true; do
  CurrentLineCount=$(wc -l < "$ProgressLog" 2>/dev/null || echo "$LastLineCount")

  # Only print STEP banner lines from newly appended log content.
  # Suppressing Status: lines and separators prevents them from pushing
  # the dashboard bar to a new line each refresh cycle (multiline stacking).
  if [ "$CurrentLineCount" -gt "$LastLineCount" ]; then
    NewLines=$(sed -n "$((LastLineCount+1)),${CurrentLineCount}p" "$ProgressLog" 2>/dev/null || true)
    if echo "$NewLines" | grep -qE "^STEP [0-9]+ of [0-9]+"; then
      printf "\r%-*s\n" "$Cols" " "
      echo "$NewLines" | grep -E "^(={10,}|STEP [0-9]+ of [0-9]+)" || true
    fi
    LastLineCount="$CurrentLineCount"
  fi

  # Update targets from log
  NewTarget="$(GetLatestPercent)"
  [ -n "${NewTarget:-}" ] && TargetPercent="$NewTarget"

  read -r NewStepNow NewStepTotal <<<"$(GetLatestStepNumbers)"
  [ -n "${NewStepNow:-}" ] && StepNow="$NewStepNow"
  [ -n "${NewStepTotal:-}" ] && StepTotal="$NewStepTotal"

  NewLabel="$(GetLatestLabel)"
  [ -n "${NewLabel:-}" ] && CurrentLabel="$NewLabel"

  # Smooth-fill toward the target
  if [ "$ShownPercent" -lt "$TargetPercent" ]; then
    ShownPercent=$((ShownPercent+1))
  elif [ "$ShownPercent" -gt "$TargetPercent" ]; then
    ShownPercent="$TargetPercent"
  fi

  # Completion check — STEP 8 of 8
  if tail -n 50 "$ProgressLog" 2>/dev/null | grep -q "STEP 8 of 8"; then
    RenderLine 100 8 8 "$CurrentLabel" ""
    printf "\n\n${C_GREEN}Bootstrap complete — PRIMARY is ready for Phase 2.${C_RESET}\nReturning to prompt in 10 seconds...\n"
    for count in 10 9 8 7 6 5 4 3 2 1; do
      printf "\r  Closing in %s second(s)...  " "$count"
      sleep 1
    done
    printf "\r%-*s\n" "$Cols" " "
    echo "Done."
    exit 0
  fi

  frame="${frames:i%4:1}"
  RenderLine "$ShownPercent" "$StepNow" "$StepTotal" "$CurrentLabel" "$frame"

  i=$((i+1))
  sleep "$RefreshSeconds"
done
EOF

chmod 755 /usr/local/bin/watch-userdata-progress

# ----------------------------
# Create watchud command
# ----------------------------

cat > /usr/local/bin/watchud <<'EOF'
#!/bin/bash
exec /usr/local/bin/watch-userdata-progress
EOF
chmod 755 /usr/local/bin/watchud

if [ -f /home/ubuntu/.bashrc ] && ! grep -q "alias watchud=" /home/ubuntu/.bashrc 2>/dev/null; then
  echo "" >> /home/ubuntu/.bashrc
  echo "alias watchud='/usr/local/bin/watchud'" >> /home/ubuntu/.bashrc
fi
chown ubuntu:ubuntu /home/ubuntu/.bashrc 2>/dev/null || true

# ----------------------------
# STEP 1: System prep
# ----------------------------

NextStep "System preparation and package updates"
LogStatus "Updating packages (apt update/upgrade)"
apt update
apt upgrade -y
LogStatus "Installing prerequisites (curl, unzip, wget)"
apt install apt-transport-https curl unzip wget -y
LogStatus "Prerequisites installed"

# ----------------------------
# STEP 2: Install MariaDB 11.8
# ----------------------------

NextStep "Installing MariaDB 11.8"
LogStatus "Adding MariaDB repo key and sources"
mkdir -p /etc/apt/keyrings
curl -o /etc/apt/keyrings/mariadb-keyring.pgp 'https://mariadb.org/mariadb_release_signing_key.pgp'

cat > /etc/apt/sources.list.d/mariadb.sources <<'EOF'
X-Repolib-Name: MariaDB
Types: deb
URIs: https://mirrors.accretive-networks.net/mariadb/repo/11.8/ubuntu
Suites: noble
Components: main main/debug
Signed-By: /etc/apt/keyrings/mariadb-keyring.pgp
EOF

LogStatus "Installing MariaDB server"
apt update
apt install mariadb-server -y

LogStatus "Enabling and starting MariaDB service"
systemctl enable mariadb
systemctl start mariadb
touch /root/3-mariadb-installed

systemctl is-active --quiet mariadb || { echo "ERROR: MariaDB did not start"; exit 1; }
LogStatus "MariaDB is running"

# ----------------------------
# STEP 3: Configure MariaDB for PRIMARY role
# ----------------------------

NextStep "Configuring MariaDB as PRIMARY (server-id=1)"
LogStatus "Locating MariaDB config file"

CNFFILE=""
for f in /etc/mysql/mariadb.conf.d/50-server.cnf \
          /etc/mysql/my.cnf \
          /etc/my.cnf; do
  [ -f "$f" ] && CNFFILE="$f" && break
done

if [ -z "$CNFFILE" ]; then
  echo "ERROR: Could not find MariaDB config file"
  exit 1
fi

LogStatus "Applying PRIMARY config to $CNFFILE"

# Comment out skip-networking if present
sed -i 's/^skip-networking/#skip-networking/' "$CNFFILE"

# Set bind-address to 0.0.0.0 (accept connections from replicas)
if grep -q "^bind-address" "$CNFFILE"; then
  sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' "$CNFFILE"
else
  echo "bind-address = 0.0.0.0" >> "$CNFFILE"
fi

# Set server-id = 1 (unique to Primary)
if grep -q "^server-id" "$CNFFILE"; then
  sed -i 's/^server-id.*/server-id = 1/' "$CNFFILE"
else
  echo "server-id = 1" >> "$CNFFILE"
fi

# Enable binary logging (required for replication)
if ! grep -q "^log_bin" "$CNFFILE"; then
  echo "log_bin = /var/log/mysql/mysql-bin.log" >> "$CNFFILE"
fi

# Set binlog format to MIXED per Dr. Gomillion's instruction
# Mixed handles both DDL (statement-based) and DML (row-based) correctly
if ! grep -q "^binlog_format" "$CNFFILE"; then
  echo "binlog_format = mixed" >> "$CNFFILE"
fi

# Allow trigger/function creation when binary logging is enabled
# Without this, any non-SUPER user gets ERROR 1419 on CREATE TRIGGER
if ! grep -q "^log_bin_trust_function_creators" "$CNFFILE"; then
  echo "log_bin_trust_function_creators = 1" >> "$CNFFILE"
fi

LogStatus "Restarting MariaDB with PRIMARY config"
systemctl restart mariadb
systemctl is-active --quiet mariadb || { echo "ERROR: MariaDB failed to restart"; exit 1; }
LogStatus "PRIMARY config applied (server-id=1, bin-log enabled, read-write)"

# ----------------------------
# STEP 4: Create Linux user mbennett
# ----------------------------

NextStep "Creating unprivileged Linux user (mbennett)"
LogStatus "Creating Linux user (mbennett)"
if id "mbennett" &>/dev/null; then
  echo "Linux user mbennett already exists"
else
  useradd -m -s /bin/bash "mbennett"
  echo "Created Linux user mbennett"
fi
LogStatus "Linux user step completed"

# ----------------------------
# STEP 5: Download and unzip data
# ----------------------------

NextStep "Downloading and unzipping source data"
LogStatus "Downloading dataset zip"
sudo -u "mbennett" wget -O "/home/mbennett/313007119.zip" "https://622.gomillion.org/data/313007119.zip"

if [ ! -s "/home/mbennett/313007119.zip" ]; then
  echo "ERROR: Download failed or zip is empty"
  exit 1
fi

LogStatus "Unzipping dataset"
sudo -u "mbennett" unzip -o "/home/mbennett/313007119.zip" -d "/home/mbennett"

for f in customers.csv orders.csv orderlines.csv products.csv; do
  [ ! -f "/home/mbennett/$f" ] && echo "ERROR: Missing $f after unzip" && exit 1
done
LogStatus "Dataset downloaded and verified"

# ----------------------------
# STEP 6: Generate etl.sql
# ----------------------------

NextStep "Generating etl.sql"
LogStatus "Writing etl.sql to disk"

cat > "/home/mbennett/etl.sql" <<'ETLEOF'
DROP DATABASE IF EXISTS POS;
CREATE DATABASE POS;
USE POS;

CREATE TABLE City
(
  zip   DECIMAL(5) ZEROFILL NOT NULL,
  city  VARCHAR(32)         NOT NULL,
  state VARCHAR(4)          NOT NULL,
  PRIMARY KEY (zip)
) ENGINE=InnoDB;

CREATE TABLE Customer
(
  id        SERIAL       NOT NULL,
  firstName VARCHAR(32)  NOT NULL,
  lastName  VARCHAR(30)  NOT NULL,
  email     VARCHAR(128) NULL,
  address1  VARCHAR(100) NULL,
  address2  VARCHAR(50)  NULL,
  phone     VARCHAR(32)  NULL,
  birthdate DATE         NULL,
  zip       DECIMAL(5) ZEROFILL NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_customer_city
    FOREIGN KEY (zip) REFERENCES City(zip)
) ENGINE=InnoDB;

CREATE TABLE Product
(
  id                SERIAL         NOT NULL,
  name              VARCHAR(128)   NOT NULL,
  currentPrice      DECIMAL(6,2)   NOT NULL,
  availableQuantity INT            NOT NULL,
  PRIMARY KEY (id)
) ENGINE=InnoDB;

CREATE TABLE `Order`
(
  id          SERIAL       NOT NULL,
  datePlaced  DATE         NULL,
  dateShipped DATE         NULL,
  customer_id BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_order_customer
    FOREIGN KEY (customer_id) REFERENCES Customer(id)
) ENGINE=InnoDB;

CREATE TABLE Orderline
(
  order_id   BIGINT UNSIGNED NOT NULL,
  product_id BIGINT UNSIGNED NOT NULL,
  quantity   INT             NOT NULL,
  PRIMARY KEY (order_id, product_id),
  CONSTRAINT fk_orderline_order
    FOREIGN KEY (order_id) REFERENCES `Order`(id),
  CONSTRAINT fk_orderline_product
    FOREIGN KEY (product_id) REFERENCES Product(id)
) ENGINE=InnoDB;

CREATE TABLE PriceHistory
(
  id         SERIAL       NOT NULL,
  oldPrice   DECIMAL(6,2) NULL,
  newPrice   DECIMAL(6,2) NOT NULL,
  ts         TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  product_id BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_pricehistory_product
    FOREIGN KEY (product_id) REFERENCES Product(id)
) ENGINE=InnoDB;

CREATE TABLE staging_customer
(
  ID VARCHAR(50), FN VARCHAR(255), LN VARCHAR(255),
  CT VARCHAR(255), ST VARCHAR(255), ZP VARCHAR(50),
  S1 VARCHAR(255), S2 VARCHAR(255), EM VARCHAR(255), BD VARCHAR(50)
) ENGINE=InnoDB;

CREATE TABLE staging_orders
(
  OID VARCHAR(50), CID VARCHAR(50), Ordered VARCHAR(50), Shipped VARCHAR(50)
) ENGINE=InnoDB;

CREATE TABLE staging_orderlines
(
  OID VARCHAR(50), PID VARCHAR(50)
) ENGINE=InnoDB;

CREATE TABLE staging_products
(
  ID VARCHAR(50), Name VARCHAR(255), Price VARCHAR(50), Quantity_on_Hand VARCHAR(50)
) ENGINE=InnoDB;

LOAD DATA LOCAL INFILE '/home/mbennett/customers.csv'
INTO TABLE staging_customer
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/home/mbennett/orders.csv'
INTO TABLE staging_orders
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/home/mbennett/orderlines.csv'
INTO TABLE staging_orderlines
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/home/mbennett/products.csv'
INTO TABLE staging_products
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(@ID, @Name, @Price, @QOH)
SET ID=@ID, Name=@Name, Price=@Price, Quantity_on_Hand=@QOH;

INSERT INTO City (zip, city, state)
SELECT DISTINCT
  CAST(LPAD(NULLIF(ZP,''), 5, '0') AS UNSIGNED),
  CT, ST
FROM staging_customer
WHERE NULLIF(ZP,'') IS NOT NULL;

INSERT INTO Customer (id, firstName, lastName, email, address1, address2, phone, birthdate, zip)
SELECT
  CAST(ID AS UNSIGNED), FN, LN, NULLIF(EM,''), NULLIF(S1,''), NULLIF(S2,''),
  NULL, STR_TO_DATE(NULLIF(BD,''), '%m/%d/%Y'),
  CAST(LPAD(NULLIF(ZP,''), 5, '0') AS UNSIGNED)
FROM staging_customer;

INSERT INTO Product (id, name, currentPrice, availableQuantity)
SELECT
  CAST(ID AS UNSIGNED), Name,
  CAST(REPLACE(REPLACE(NULLIF(Price,''), '$', ''), ',', '') AS DECIMAL(6,2)),
  CAST(NULLIF(Quantity_on_Hand,'') AS UNSIGNED)
FROM staging_products;

INSERT INTO `Order` (id, datePlaced, dateShipped, customer_id)
SELECT
  CAST(OID AS UNSIGNED),
  CASE WHEN NULLIF(Ordered,'') IS NULL OR LOWER(Ordered)='cancelled' THEN NULL
       ELSE DATE(STR_TO_DATE(Ordered, '%Y-%m-%d %H:%i:%s')) END,
  CASE WHEN NULLIF(Shipped,'') IS NULL OR LOWER(Shipped)='cancelled' THEN NULL
       ELSE DATE(STR_TO_DATE(Shipped, '%Y-%m-%d %H:%i:%s')) END,
  CAST(CID AS UNSIGNED)
FROM staging_orders;

INSERT INTO Orderline (order_id, product_id, quantity)
SELECT CAST(OID AS UNSIGNED), CAST(PID AS UNSIGNED), COUNT(*)
FROM staging_orderlines
GROUP BY CAST(OID AS UNSIGNED), CAST(PID AS UNSIGNED);

INSERT INTO PriceHistory (oldPrice, newPrice, product_id)
SELECT NULL, currentPrice, id FROM Product;

DROP TABLE staging_customer;
DROP TABLE staging_orders;
DROP TABLE staging_orderlines;
DROP TABLE staging_products;
ETLEOF

chown "mbennett:mbennett" "/home/mbennett/etl.sql"
LogStatus "etl.sql generated"

# ----------------------------
# STEP 7: Generate views.sql and triggers.sql
# NOTE: DELIMITER is a client-only directive and silently breaks when SQL is
# piped via stdin redirection (< file). Triggers are written as single-statement
# form (no BEGIN...END block needed for single-statement triggers) which works
# correctly without DELIMITER in both batch and interactive modes.
# ----------------------------

NextStep "Generating views.sql and triggers.sql"
LogStatus "Writing views.sql to disk"

cat > "/home/mbennett/views.sql" <<'VIEWEOF'
USE POS;

DROP VIEW IF EXISTS v_ProductBuyers;

CREATE VIEW v_ProductBuyers AS
SELECT
    p.id AS productID,
    p.name AS productName,
    IFNULL(
        GROUP_CONCAT(
            DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
            ORDER BY c.id
            SEPARATOR ', '
        ),
        ''
    ) AS customers
FROM Product p
LEFT JOIN Orderline ol ON p.id = ol.product_id
LEFT JOIN `Order` o ON ol.order_id = o.id
LEFT JOIN Customer c ON o.customer_id = c.id
GROUP BY p.id, p.name
ORDER BY p.id;

DROP TABLE IF EXISTS mv_ProductBuyers;

CREATE TABLE mv_ProductBuyers AS
SELECT * FROM v_ProductBuyers;

CREATE INDEX idx_mv_productID ON mv_ProductBuyers(productID);
VIEWEOF

chown "mbennett:mbennett" "/home/mbennett/views.sql"
LogStatus "views.sql generated"

LogStatus "Writing triggers.sql to disk"

cat > "/home/mbennett/triggers.sql" <<'TRIGEOF'
USE POS;

DROP TRIGGER IF EXISTS trg_orderline_insert;
DROP TRIGGER IF EXISTS trg_orderline_delete;
DROP TRIGGER IF EXISTS trg_product_price_update;

CREATE TRIGGER trg_orderline_insert
AFTER INSERT ON Orderline
FOR EACH ROW
UPDATE mv_ProductBuyers
SET customers = (
    SELECT IFNULL(
        GROUP_CONCAT(
            DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
            ORDER BY c.id SEPARATOR ', '
        ), '')
    FROM Orderline ol
    JOIN `Order` o ON ol.order_id = o.id
    JOIN Customer c ON o.customer_id = c.id
    WHERE ol.product_id = NEW.product_id
)
WHERE productID = NEW.product_id;

CREATE TRIGGER trg_orderline_delete
AFTER DELETE ON Orderline
FOR EACH ROW
UPDATE mv_ProductBuyers
SET customers = (
    SELECT IFNULL(
        GROUP_CONCAT(
            DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
            ORDER BY c.id SEPARATOR ', '
        ), '')
    FROM Orderline ol
    JOIN `Order` o ON ol.order_id = o.id
    JOIN Customer c ON o.customer_id = c.id
    WHERE ol.product_id = OLD.product_id
)
WHERE productID = OLD.product_id;

CREATE TRIGGER trg_product_price_update
AFTER UPDATE ON Product
FOR EACH ROW
INSERT INTO PriceHistory (oldPrice, newPrice, product_id)
SELECT OLD.currentPrice, NEW.currentPrice, NEW.id
WHERE OLD.currentPrice <> NEW.currentPrice;
TRIGEOF

chown "mbennett:mbennett" "/home/mbennett/triggers.sql"
LogStatus "triggers.sql generated"

# ----------------------------
# STEP 8: Bootstrap complete — install phase2 wizard as standalone command
# ----------------------------

NextStep "Bootstrap complete — installing Phase 2 wizard"

cat > /usr/local/bin/phase2 <<'WIZEOF'
#!/bin/bash
# =============================================================================
# PRIMARY — Phase 2 Setup Wizard
# Run after bootstrap completes: sudo phase2
# =============================================================================

# Must run as root to execute MariaDB commands and SQL files
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Please run as root: sudo phase2"
  exit 1
fi

set +e

DbPass="MyVoiceIsMyPassport!"
PrimaryIP=$(hostname -I | awk '{print $1}')

# Step completion flags
s1=0; s2=0; s3=0; s4=0; s5=0; s6=0; s7=0

# Colors
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_CYAN=$'\033[36m'
C_DIM=$'\033[2m'

CheckMark() { [ "$1" -eq 1 ] && printf "${C_GREEN}✓${C_RESET}" || printf "${C_DIM}·${C_RESET}"; }

DrawMenu() {
  clear
  echo ""
  printf "${C_BOLD}╔══════════════════════════════════════════════════════════╗${C_RESET}\n"
  printf "${C_BOLD}║         PRIMARY — Phase 2 Setup Wizard                  ║${C_RESET}\n"
  printf "${C_BOLD}║         Primary IP: %-36s ║${C_RESET}\n" "$PrimaryIP"
  printf "${C_BOLD}╚══════════════════════════════════════════════════════════╝${C_RESET}\n"
  echo ""
  printf "  ${C_CYAN}[1]${C_RESET} $(CheckMark $s1)  Create replication user ${C_DIM}(auto-executes SQL)${C_RESET}\n"
  printf "  ${C_CYAN}[2]${C_RESET} $(CheckMark $s2)  Show CHANGE MASTER TO template for replicas\n"
  printf "  ${C_CYAN}[3]${C_RESET} $(CheckMark $s3)  Confirm both replicas connected ${C_DIM}(manual verification)${C_RESET}\n"
  printf "  ${C_CYAN}[4]${C_RESET} $(CheckMark $s4)  Verify binary log ${C_DIM}(SHOW MASTER STATUS)${C_RESET}\n"
  printf "  ${C_CYAN}[5]${C_RESET} $(CheckMark $s5)  ${C_YELLOW}Execute etl.sql${C_RESET} ${C_DIM}(requires step 3)${C_RESET}\n"
  printf "  ${C_CYAN}[6]${C_RESET} $(CheckMark $s6)  Create mbennett DB user + grant privileges ${C_DIM}(requires step 5)${C_RESET}\n"
  printf "  ${C_CYAN}[7]${C_RESET} $(CheckMark $s7)  ${C_YELLOW}Execute views.sql + triggers.sql${C_RESET} ${C_DIM}(requires step 6)${C_RESET}\n"
  echo ""
  printf "  ${C_CYAN}[r]${C_RESET}    Refresh menu\n"
  printf "  ${C_CYAN}[q]${C_RESET}    Quit (return to prompt)\n"
  echo ""
}

while true; do
  DrawMenu
  read -rp "  Select step: " choice

  case "$choice" in

    1)
      echo ""
      printf "${C_BOLD}Creating replication user...${C_RESET}\n"
      mariadb <<'SQL'
CREATE USER IF NOT EXISTS 'repl_user'@'%' IDENTIFIED BY 'Repl!Secure#2026';
GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%';
FLUSH PRIVILEGES;
SQL
      if [ $? -eq 0 ]; then
        printf "${C_GREEN}  repl_user created successfully.${C_RESET}\n"
        s1=1
      else
        printf "${C_RED}  ERROR: Failed. Check: sudo tail -50 /var/log/mysql/error.log${C_RESET}\n"
      fi
      read -rp "  Press Enter to continue..." _
      ;;

    2)
      echo ""
      printf "${C_BOLD}Run these commands on EACH REPLICA (as root):${C_RESET}\n"
      echo ""
      printf "${C_YELLOW}mariadb <<'SQL'\n"
      printf "CHANGE MASTER TO\n"
      printf "  MASTER_HOST='%s',\n" "$PrimaryIP"
      printf "  MASTER_USER='repl_user',\n"
      printf "  MASTER_PASSWORD='Repl!Secure#2026',\n"
      printf "  MASTER_PORT=3306,\n"
      printf "  MASTER_CONNECT_RETRY=10;\n"
      printf "SQL\n\n"
      printf "mariadb -e \"START SLAVE;\"\n"
      printf "mariadb -e \"SHOW SLAVE STATUS\\\\G\"\n"
      printf "${C_RESET}"
      echo ""
      printf "${C_DIM}  Tip: Type the single quotes manually — do not copy from PDF/Word.${C_RESET}\n"
      s2=1
      read -rp "  Press Enter to continue..." _
      ;;

    3)
      echo ""
      printf "${C_BOLD}Replica verification checklist:${C_RESET}\n"
      printf "  On each replica, confirm SHOW SLAVE STATUS\\G shows:\n"
      printf "    ${C_GREEN}Slave_IO_Running: Yes${C_RESET}\n"
      printf "    ${C_GREEN}Slave_SQL_Running: Yes${C_RESET}\n"
      printf "    ${C_GREEN}Seconds_Behind_Master: 0${C_RESET}\n"
      echo ""
      read -rp "  Are BOTH replicas showing Yes/Yes? (y/n): " confirm
      if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        printf "${C_GREEN}  Confirmed. Safe to proceed to ETL.${C_RESET}\n"
        s3=1
      else
        printf "${C_RED}  Not confirmed. Fix replicas before running ETL.${C_RESET}\n"
      fi
      read -rp "  Press Enter to continue..." _
      ;;

    4)
      echo ""
      printf "${C_BOLD}Primary binary log status:${C_RESET}\n"
      mariadb -e "SHOW MASTER STATUS\G"
      s4=1
      read -rp "  Press Enter to continue..." _
      ;;

    5)
      echo ""
      if [ $s3 -ne 1 ]; then
        printf "${C_RED}  BLOCKED: Confirm replicas are connected first (step 3).${C_RESET}\n"
        printf "  Running ETL before replicas connect means they will miss\n"
        printf "  the data load entirely and replication will crash.\n"
      else
        printf "${C_BOLD}Running etl.sql (this may take a minute)...${C_RESET}\n"
        mariadb --local-infile=1 < /home/mbennett/etl.sql
        if [ $? -eq 0 ]; then
          printf "${C_GREEN}  ETL complete. POS database built and data loaded.${C_RESET}\n"
          s5=1
        else
          printf "${C_RED}  ERROR: ETL failed. Check /var/log/user-data.log${C_RESET}\n"
        fi
      fi
      read -rp "  Press Enter to continue..." _
      ;;

    6)
      echo ""
      if [ $s5 -ne 1 ]; then
        printf "${C_RED}  BLOCKED: Run ETL first (step 5) — POS database must exist.${C_RESET}\n"
      else
        printf "${C_BOLD}Creating mbennett MariaDB user...${C_RESET}\n"
        mariadb <<SQL
CREATE USER IF NOT EXISTS 'mbennett'@'localhost' IDENTIFIED BY '${DbPass}';
GRANT ALL PRIVILEGES ON POS.* TO 'mbennett'@'localhost';
FLUSH PRIVILEGES;
SQL
        if [ $? -eq 0 ]; then
          printf "${C_GREEN}  mbennett created and granted POS.* privileges.${C_RESET}\n"
          printf "${C_DIM}  This SQL-level user replicates to both replicas automatically.${C_RESET}\n"
          s6=1
        else
          printf "${C_RED}  ERROR: Failed to create DB user.${C_RESET}\n"
        fi
      fi
      read -rp "  Press Enter to continue..." _
      ;;

    7)
      echo ""
      if [ $s6 -ne 1 ]; then
        printf "${C_RED}  BLOCKED: Complete step 6 first.${C_RESET}\n"
      else
        printf "${C_BOLD}Running views.sql...${C_RESET}\n"
        mariadb < /home/mbennett/views.sql
        if [ $? -eq 0 ]; then
          printf "${C_GREEN}  views.sql complete (view + materialized view + index).${C_RESET}\n"
        else
          printf "${C_RED}  ERROR: views.sql failed.${C_RESET}\n"
        fi

        echo ""
        printf "${C_BOLD}Running triggers.sql...${C_RESET}\n"
        mariadb < /home/mbennett/triggers.sql
        if [ $? -eq 0 ]; then
          printf "${C_GREEN}  triggers.sql complete (3 triggers created).${C_RESET}\n"
          s7=1
        else
          printf "${C_RED}  ERROR: triggers.sql failed.${C_RESET}\n"
        fi

        if [ $s7 -eq 1 ]; then
          echo ""
          printf "${C_BOLD}${C_GREEN}"
          printf "  ╔══════════════════════════════════════════════════════╗\n"
          printf "  ║   All Phase 2 steps complete. Cluster is live.      ║\n"
          printf "  ║   Run: mariadb -u mbennett -p                       ║\n"
          printf "  ║   Then: USE POS; SHOW TABLES;                       ║\n"
          printf "  ╚══════════════════════════════════════════════════════╝\n"
          printf "${C_RESET}"
        fi
      fi
      read -rp "  Press Enter to continue..." _
      ;;

    r|R)
      ;;

    q|Q)
      echo ""
      printf "${C_DIM}  Exiting wizard. Run 'sudo phase2' to re-launch at any time.${C_RESET}\n"
      echo ""
      exit 0
      ;;

    *)
      printf "${C_RED}  Invalid selection. Choose 1-7, r, or q.${C_RESET}\n"
      read -rp "  Press Enter to continue..." _
      ;;

  esac
done
WIZEOF

chmod 755 /usr/local/bin/phase2

touch /root/primary-bootstrap-complete
LogStatus "Primary bootstrap complete"
LogStatus "Run 'sudo phase2' to begin replication setup"

echo ""
echo "============================================================"
echo "  PRIMARY bootstrap complete."
echo "  When watchud exits, run:  sudo phase2"
echo "============================================================"
