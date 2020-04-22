#!/usr/bin/bash


# install_otrs.sh - Install OTRS and MariaDB

# Site:       https://www.linkedin.com/in/mateusrissi/
# Author:     Mateus Rissi

#  This script will install OTRS and MariaDB, also will do the basic configuration 
#  of OTRS and the database that OTRS will use.
#
#  Examples:
#      # ./install_otrs.sh

# History:
#   v1.0.0 22/04/2020, Mateus:
#       - Start
#       - Funcionalities

# Tested on:
#   bash 4.2.46
# --------------------------------------------------------------------------- #


# VARIABLES
otrs_version="6.0.26"
mysql_conf_file="/etc/my.cnf"
random_passwd="$(date +%s | sha256sum | base64 | head -c 32)"
sec_mysql_temp_file="/tmp/secure_mysql_temp_file.txt"
install_otrs_log_file="/var/log/install_otrs.log"

tasks_to_execute="
    install_dependencies
    modify_mysql_config_file
    start_mariaDB
    secure_mysql
    install_otrs
    set_otrs_permissions
    install_otrs_modules
    enable_mariaDB
    disable_SELinux
    disable_firewall
    create_otrs_database
    start_otrs
    enable_apache
    config_web
    set_otrs_password
"

read -r -d '' info_to_show <<EOF
==================================================================
    MYSQL root@localhost: $random_passwd
    MYSQL otrs@localhost: $random_passwd
    Login: root@localhost
    Password: $random_passwd
==================================================================
EOF

red="\033[31;1m"
green="\033[32;1m"
no_color="\033[0m"


# FUNCTIONS
install_dependencies() {
    yum check-update

    yum -y install \
        epel-release \
        mariadb-server \
        mariadb
}

modify_mysql_config_file() {
    sed -i s/"\[mysqld\]"/"\[mysqld\]\nmax_allowed_packet = 64M\nquery_cache_size = 32M\ninnodb_log_file_size = 256M"/g $mysql_conf_file
}

start_mariaDB() {
    systemctl restart mariadb.service
}

secure_mysql() {
    cat <<- EOF > $sec_mysql_temp_file
        UPDATE mysql.user SET Password=PASSWORD('${random_passwd}') WHERE User='root';
        DELETE FROM mysql.user WHERE User='';
        DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
        DROP DATABASE IF EXISTS test;
        DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
        FLUSH PRIVILEGES;
EOF

    mysql -sfu root < $sec_mysql_temp_file

    rm -f $sec_mysql_temp_file
}

install_otrs() {
    yum check-update
    curl -L http://ftp.otrs.org/pub/otrs/RPMS/rhel/7/otrs-${otrs_version}-01.noarch.rpm -o "/tmp/otrs.rpm" -s
    yum -y install "/tmp/otrs.rpm" || yum -y install "/tmp/otrs.rpm"
    rm -f "/tmp/otrs.rpm"
    systemctl restart httpd.service
}

set_otrs_permissions() {
    /opt/otrs/bin/otrs.SetPermissions.pl
}

install_otrs_modules() {
    yum -y install \
        "perl(Crypt::Eksblowfish::Bcrypt)" \
        "perl(JSON::XS)" \
        "perl(Mail::IMAPClient)" \
        "perl(Authen::NTLM)" \
        "perl(ModPerl::Util)" \
        "perl(Text::CSV_XS)" \
        "perl(YAML::XS)"

    yum -y install mod_ssl
}

enable_mariaDB() {
    systemctl enable mariadb.service
    systemctl restart mariadb.service
}

disable_SELinux() {
    setenforce permissive
    sed -i s/enforcing/permissive/g /etc/sysconfig/selinux
}

disable_firewall() {
    systemctl disable firewalld
    systemctl stop firewalld
}

create_otrs_database() {
    mysql -u root -p$random_passwd -e "create database otrs character set utf8 collate utf8_bin;"
    mysql -u root -p$random_passwd -e "create user 'otrs'@'localhost' identified by '"${random_passwd}"';"
    mysql -u root -p$random_passwd -e "GRANT ALL on otrs.* TO 'otrs'@'localhost';"
    mysql -u root -p$random_passwd -e "flush privileges;"
}

start_otrs () {
    su - otrs -c '/opt/otrs/bin/otrs.Daemon.pl start > /dev/null 2>&1' \
              -c '/opt/otrs/bin/Cron.sh start > /dev/null 2>&1'
}

enable_apache() {
    systemctl enable httpd
    systemctl restart httpd
}

config_web() {
    curl -s -d action="/otrs/installer.pl" -d Subaction="License" -d submit="Submit" http://localhost/otrs/installer.pl > /dev/null
    curl -s -d action="/otrs/installer.pl" -d Subaction="Start" -d submit="Accept license and continue" http://localhost/otrs/installer.pl > /dev/null
    curl -s -d action="/otrs/installer.pl" -d Subaction="DB" -d DBType="mysql" -d DBInstallType="UseDB" -d submit="FormDBSubmit" http://localhost/otrs/installer.pl > /dev/null
    curl -s -d action="/otrs/installer.pl" -d Subaction="DBCreate" -d DBType="mysql" -d InstallType="UseDB" -d DBUser="otrs" -d DBPassword="${random_passwd}" -d DBHost="127.0.0.1" -d DBName="otrs" -d submit="FormDBSubmit" http://localhost/otrs/installer.pl > /dev/null
    curl -s -d action="/otrs/installer.pl" -d Subaction="System" -d submit="Submit" http://localhost/otrs/installer.pl > /dev/null
    curl -s -d action="/otrs/installer.pl" -d Subaction="ConfigureMail" -d LogModule="Kernel::System::Log::SysLog" DefaultLanguage="pt_BR" -d CheckMXRecord="0" -d submit="Submit" http://localhost/otrs/installer.pl > /dev/null
    curl -s -d action="/otrs/installer.pl" -d Subaction="Finish" -d Skip="0" -d button="Skip this step" http://localhost/otrs/installer.pl > /dev/null
}

set_otrs_password() {
    su - otrs -c "/opt/otrs/bin/otrs.Console.pl Admin::User::SetPassword root@localhost $random_passwd"
}


# EXEC
for task in $tasks_to_execute; do

    echo "Running ${task}... "

    $task >> $install_otrs_log_file 2>&1

    if [ $? -eq 0 ]; then
        echo -e "${green}ok${no_color}\n"
    else
        echo -e "${red}fail${no_color}\n"
    fi
done

echo "$info_to_show"
