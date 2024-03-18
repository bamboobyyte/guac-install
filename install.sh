#! /bin/bash

log_file='/home/panda/log.txt'

guac_ver='1.5.4'
mysql_connector_j_ver='8.0.30'

sql_guac_user='guacamole_user'
sql_guac_pass='password'
sql_root_pass='Password'

guacd_host='localhost'
guacd_port='4822'
sql_guac_db='guacamole_db'
sql_host='localhost'

# Colors to use for output
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

install_or_upgrade_packages() {
    # local packages=($1) # List of packages

    # Update package index
    sudo apt-get update >/dev/null 2>&1

    # Loop through each package
    for pkg in "$@"; do
        if dpkg -l | grep -qw "$pkg"; then
            # Upgrade package
            if sudo apt-get install -y "$pkg" >/dev/null 2>&1; then
                echo -e "${NC}$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[  ok   ]${NC} $pkg is successfully upgraded." | tee -a "$log_file"
            else
                echo -e "${NC}$(date '+%Y-%m-%d %H:%M:%S') ${RED}[  err  ]${NC} $pkg is not able to upgrade." | tee -a "$log_file"
            fi
        else
            # Install package
            if sudo apt-get install -y "$pkg" >/dev/null 2>&1; then
                echo -e "${NC}$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[  ok   ]${NC} $pkg is successfully installed." | tee -a "$log_file"
            else
                echo -e "${NC}$(date '+%Y-%m-%d %H:%M:%S') ${RED}[  err  ]${NC} $pkg is not able to install." | tee -a "$log_file"
            fi
        fi
    done
}

# Check if user is root or sudo
if ! [ $( id -u ) = 0 ]; then
    echo "Please run this script as sudo or root" 1>&2
    exit 1
fi

# updates
apt-get update && apt-get upgrade -y

# install dependencies
guac_server_dependencies=(
    libcairo2-dev libjpeg-turbo8-dev libpng-dev libtool-bin uuid-dev libavcodec-dev \
    libavformat-dev libavutil-dev libswscale-dev freerdp2-dev freerdp2-x11 libpango1.0-dev \
    libssh2-1-dev libtelnet-dev libvncserver-dev libwebsockets-dev libpulse-dev libssl-dev \
    libvorbis-dev libwebp-dev make
)

install_or_upgrade_packages "${guac_server_dependencies[@]}"

# download guac files
# making a temp directory to store all files
mkdir guacamole
cd guacamole

# download source code of Guac server
wget --show-progress https://dlcdn.apache.org/guacamole/${guac_ver}/source/guacamole-server-${guac_ver}.tar.gz
# download Guac client
wget --show-progress https://dlcdn.apache.org/guacamole/${guac_ver}/binary/guacamole-${guac_ver}.war
# download SQL connector
wget --show-progress https://dlcdn.apache.org/guacamole/${guac_ver}/binary/guacamole-auth-jdbc-${guac_ver}.tar.gz
# download MySQL ConnectorJ
wget https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-java-${mysql_connector_j_ver}.tar.gz

# compile guac server
tar -xzf guacamole-server-${guac_ver}.tar.gz
cd guacamole-server-${guac_ver}/
./configure --with-init-dir=/etc/init.d --with-systemd-dir=/etc/systemd/system
make
make install
ldconfig
cd ..

# install tomcat
sudo apt install -y tomcat9

# delete the deafult page of tomcat
rm -r /var/lib/tomcat9/webapps/*

# deploy guac client
mkdir -p /etc/guacamole
cp guacamole-${guac_ver}.war /etc/guacamole/guacamole.war
ln -s /etc/guacamole/guacamole.war /var/lib/tomcat9/webapps/ROOT.war

# configure guac
mkdir -p /etc/guacamole/extensions
mkdir -p /etc/guacamole/lib

# remove potential existing configurations
rm -f /etc/guacamole/guacamole.properties
rm -f /etc/guacamole/guacd.conf
rm -f /etc/guacamole/user-mapping.xml

# create new configuration files
touch /etc/guacamole/guacamole.properties
touch /etc/guacamole/guacd.conf
touch /etc/guacamole/user-mapping.xml

# config guacamole.properties
echo "# Hostname and port of guacamole proxy
guacd-hostname: ${guacd_host}
guacd-port:     ${guacd_port}" >> /etc/guacamole/guacamole.properties

# config guacd.conf
echo "[server]
bind_host = ${guacd_host}
bind_port = ${guacd_port}">> /etc/guacamole/guacd.conf

# config user-mapping.xml
# echo '<user-mapping>
#     <!-- Per-user authentication and config information -->
#     <authorize
#             username="guacadmin"
#             password="5CBD438413E8E3CA0E14E200FDE621A9"
#             encoding="md5">
#         <protocol>ssh</protocol>
#         <param name="hostname">127.0.0.1</param>
#         <param name="port">22</param>
#     </authorize>
# </user-mapping>'>> /etc/guacamole/user-mapping.xml

# install and config mysql
apt-get install -y mysql-server-8.0
systemctl start mysql

# copy mysql extension
tar -xzf guacamole-auth-jdbc-${guac_ver}.tar.gz
cp guacamole-auth-jdbc-1.5.4/mysql/guacamole-auth-jdbc-mysql-1.5.4.jar /etc/guacamole/extensions

# copy mysql conectorj
tar -xzf mysql-connector-java-${mysql_connector_j_ver}.tar.gz
cp mysql-connector-java-8.0.30/mysql-connector-java-8.0.30.jar /etc/guacamole/lib

SQLCODE="
DROP DATABASE IF EXISTS ${sql_guac_db};
CREATE DATABASE IF NOT EXISTS ${sql_guac_db};
CREATE USER IF NOT EXISTS '${sql_guac_user}'@'${sql_host}' IDENTIFIED BY \"${sql_guac_pass}\";
GRANT SELECT,INSERT,UPDATE,DELETE ON ${sql_guac_db}.* TO '${sql_guac_user}'@'${sql_host}';
FLUSH PRIVILEGES;"

echo ${SQLCODE} | mysql -u root -p${sql_root_pass}

cat guacamole-auth-jdbc-1.5.4/mysql/schema/001-create-schema.sql | sudo mysql -u root -p${sql_root_pass} -D ${sql_guac_db}
cat guacamole-auth-jdbc-1.5.4/mysql/schema/002-create-admin-user.sql | sudo mysql -u root -p${sql_root_pass} -D ${sql_guac_db}

# adding mysql config to guacamole.properties
echo "" >> /etc/guacamole/guacamole.properties
echo "# MySQL properties
mysql-hostname: ${sql_host}
mysql-database: ${sql_guac_db}
mysql-username: ${sql_guac_user}
mysql-password: ${sql_guac_pass}">> /etc/guacamole/guacamole.properties

# finishing up
# fix the free RDP not able to initialize
mkdir -p /usr/sbin/.config/freerdp
chown daemon:daemon /usr/sbin/.config/freerdp

systemctl start tomcat9
systemctl start guacd
systemctl enable tomcat9
systemctl enable mysql
systemctl enable guacd

cd ..

rm -rf guacamole
