#!/bin/bash -ue

#############################################################################
# If LE is installed, enable SSL. The site owner can either leave the LE cert, or they can
# spend the extra dough and have a 'real' cert installed, which covers the cost of manual installation.
#----------------------------------------------------------------------------
function find_certbot() {
  # Letsencrypt has flip-flopped with its name and location over the years.
  # Simply doing a "which" may hit the wrong one if legacy versions are still around.
  if [ -e /snap/bin/certbot ]; then   # Snap version, 2020
    echo /snap/bin/certbot
    return 0
  elif [ -e /usr/local/bin/certbot-auto ]; then  # Self-updating script version, 2019ish, now deprecated.
    echo /usr/local/bin/certbot-auto
    return 0
  elif [ -e /usr/bin/certbot ]; then   # Package version, 2018ish, now deprecated.
    echo /usr/bin/certbot
    return 0
  else
    # Try and guess, prioritizing the current name.
    which certbot || which certbot-auto || {
      >&2 echo "No certbot or certbot-auto found"  # This is only a courtesey messsage. Be sure not to emit to stdout, and be sure not to exit with an error; The presence of certbot is not a requirement here.
    }
  fi
}


#############################################################################
#----------------------------------------------------------------------------
function main () {

  set +o pipefail # Turning this back off (it was set just before calling main) because the script wasn't written with it on, and I haven't had time to test the effects.

  sanity_checks_pass "$@" || exit 110

  if /usr/local/bin/optional-parameter-exists '--help' "$@" 2 > /dev/null; then
    usage
    exit 0
  fi

  if /usr/local/bin/optional-parameter-exists '--account' "$@" 2 > /dev/null; then
    USERACCOUNT="$(/usr/local/bin/require-named-parameter "--account" "$@")"
  else
    echo "Please enter the account name"
    USERACCOUNT="$(prompt_for_value_with_default "USERACCOUNT" "")"
    echo ""
  fi

  DEFAULT_PROJECT="${USERACCOUNT}";
  if /usr/local/bin/optional-parameter-exists '--project' "$@" 2 > /dev/null; then
    PROJECT="$(/usr/local/bin/require-named-parameter "--project" "$@")"
    [ "${PROJECT}" = "DEFAULT" ] && PROJECT="${DEFAULT_PROJECT}"
  else
    echo "Please enter the project name (hit enter to leave as project name)"
    PROJECT="$(prompt_for_value_with_default "PROJECT" "${DEFAULT_PROJECT}")"
    echo ""
  fi

  DEFAULT_FQDN="${PROJECT}.$(hostname -f)"
  if /usr/local/bin/optional-parameter-exists '--fqdn' "$@" 2 > /dev/null; then
    FQDN="$(/usr/local/bin/require-named-parameter "--fqdn" "$@")"
    [ "${FQDN}" = "DEFAULT" ] && FQDN="${DEFAULT_FQDN}"
  else
    echo "Please enter the FQDN (hit enter to leave as default)"
    FQDN="$(prompt_for_value_with_default "FQDN" "${DEFAULT_FQDN}")"
    echo ""
  fi

  DEFAULT_WEBROOT="wwwroot"
  if /usr/local/bin/optional-parameter-exists '--webroot' "$@" 2 > /dev/null; then
    WEB_ROOT_DIRNAME="$(/usr/local/bin/require-named-parameter "--webroot" "$@")"
    # If --webroot is "NONE" then change it to empty string to show that we don't want to make a dir.
    [ "${WEB_ROOT_DIRNAME}" = "NONE" ] && WEB_ROOT_DIRNAME=""
  else
    echo "What is the name of your web root dir?"
    echo "- Drupal 7 sites typically use 'wwwroot'"
    echo "- Drupal 8 sites typically use 'web'"
    echo "- Platform.sh projects can be just about anything"
    echo "- If the web root is at the base of the repo, then leave this blank"
    WEB_ROOT_DIRNAME="$(prompt_for_value_with_default "WEB_ROOT_DIRNAME" "${DEFAULT_WEBROOT}")"
    echo ""
  fi
  if ! test -z "$WEB_ROOT_DIRNAME"; then
    # Make sure it begins with a slash - we are going to append it to a path.
    WEB_ROOT_DIRNAME="/$(strip_non_slug_chars "${WEB_ROOT_DIRNAME}")"
  fi

  # Validate arguments themselves
  validate_account_string "$USERACCOUNT" || exit 165
  validate_project_string "$PROJECT" || exit 166
  validate_fqdn "$FQDN" || exit 167

  # Set the new relic name
  if [ "${DEFAULT_FQDN}" != "${FQDN}" ]; then
    NEWRELIC_APPNAME="${FQDN} ($(hostname -s): ${USERACCOUNT}/${PROJECT})"
  elif [ "${PROJECT}" != "${USERACCOUNT}" ]; then
    NEWRELIC_APPNAME="${FQDN} (${USERACCOUNT})"
  else
    NEWRELIC_APPNAME="${FQDN}"
  fi

  # Accept credentials from the environment for DB + User creation, instead of auto-generating names.
  # Useful when the script is being run by an Ansible playbook, where it's better to use predefined values over generated ones (think: load balanced systems)
  # No sanity checks are performed if these env vars are supplied. You must tend to var length, unsupported chars, etc, yourself.
  DBNAME=${DBNAME:-} # Accept from environment
  DBUSER=${DBUSER:-} # Accept from environment
  DBPASS=${DBPASS:-} # Accept from environment

  # When account + project are the same, it's preferred to use the 'single' name wherever appropriate:
  #   i.e. eikon/eikon  =  eikon.conf, 'eikon' as dbname, 'eikon' as db user, etc.
  # When a second project is being added to a project, or if the account and project name are
  # different, we will use the full 'account_prjoect' style for identifiers.
  #  i.e. eikon/electraysn = eikon-electrasyn.conf, eiko_elec as dbname + dbuser, etc.
  # In all cases, we need to preemptively detect and reject possible name collisions.
  if [[ "$USERACCOUNT" == "$PROJECT" ]]; then
    if project_exists "$USERACCOUNT" "$PROJECT"; then
      err "The account + project you specified already exists."
      if [ $FORCE -ne 1 ]; then
        exit 7
      fi
    fi
    if [ $# -gt 0 ] && /usr/local/bin/optional-parameter-exists "--service-account" "$@"; then
      SERVICEACCOUNT=$(/usr/local/bin/require-named-parameter '--service-account' "$@")
    else
      SERVICEACCOUNT="$(echo "$USERACCOUNT"| cut -c1-12)-srv"
    fi
    export SERVICEACCOUNT
    if [ -z "$DBNAME" ]; then
      DBNAME=$(safe_mysql_db_name "$USERACCOUNT")
    fi
    export DBNAME
    if [ -z "$DBUSER" ]; then
      DBUSER="$DBNAME"
    fi
    export DBUSER
  else
    if [ $# -gt 0 ] && /usr/local/bin/optional-parameter-exists "--service-account" "$@"; then
      SERVICEACCOUNT=$(/usr/local/bin/require-named-parameter '--service-account' "$@")
    else
      SERVICEACCOUNT="$(make_compound_service_account_name "$USERACCOUNT" "$PROJECT")"
    fi
    export SERVICEACCOUNT
    if [ -z "$DBNAME" ]; then
      DBNAME="$(make_compound_mysql_db_name "$USERACCOUNT" "$PROJECT")"
    fi
    export DBNAME
    if [ -z "$DBUSER" ]; then
      DBUSER="$(make_compound_mysql_user_name "$USERACCOUNT" "$PROJECT")"
    fi
    export DBUSER
  fi
  export FPM_POOL_CONF="$POOLDIR/$USERACCOUNT-$PROJECT.conf"
  export FPM_POOL_NAME="$USERACCOUNT-$PROJECT"
  export LOGROTATE_CONF="/etc/logrotate.d/vhost.$USERACCOUNT-$PROJECT"
  export SOCKET_FILE="/var/run/php${PHP_VERSION}-fpm-$USERACCOUNT-$PROJECT.sock"
  export REAL_VHOST="$SITES_AVAILABLE/${USERACCOUNT}-${PROJECT}.conf"
  export ENABLED_VHOST="$SITES_ENABLED/${USERACCOUNT}-${PROJECT}.conf"
  if [ "${WEBSERVER}" == "apache" ]; then
    export REAL_VHOST="${REAL_VHOST}.conf"
    export ENABLED_VHOST="${ENABLED_VHOST}.conf"
  elif [ "${WEBSERVER}" == "httpd" ]; then
    export REAL_VHOST="${REAL_VHOST}.conf"
    export ENABLED_VHOST="${ENABLED_VHOST}.conf" # this actually does nothing.
  fi

  export NEWRELIC_APPNAME
  if [ $FORCE -ne 1 ] ; then
    prevent_name_collisions || exit 8
  fi

  DEFAULT_RESPONSIBLE_PERSON="root"
  if tty --quiet; then  # Is this an interactive session?
    if /usr/local/bin/optional-parameter-exists '--responsible-person' "$@" 2 > /dev/null; then
      RESPONSIBLE_PERSON="$(/usr/local/bin/require-named-parameter "--responsible-person" "$@")"
    else
      echo "Who should receive notifications generated by the '${USERACCOUNT}' and '${SERVICEACCOUNT}' system accounts?"
      echo "- Enter your own email address, or leave as default to let notifications go to ${DEFAULT_RESPONSIBLE_PERSON}:"
      RESPONSIBLE_PERSON="$(prompt_for_value_with_default "RESPONSIBLE_PERSON" "${DEFAULT_RESPONSIBLE_PERSON}")"
      echo ""
    fi
  else
    # Don't prompt if we are not being used interactively (ie from a playbook)
    RESPONSIBLE_PERSON="root"
  fi

  # These can be made if they don't exist. This will only happen the first time this script runs on a machine.
  test -d "$VHOSTLOGROOT" || mkdir "$VHOSTLOGROOT"
  SSLDIR=${SSLDIR:-'/usr/local/ssl'}   # SSLDIR should be defined in /etc/acro/add-website.conf
  test -d "${SSLDIR}" || mkdir "${SSLDIR}"
  test -d "${KEYSDIR}" || ( mkdir "${KEYSDIR}" && chown root:adm "${KEYSDIR}" && chmod 2750 "${KEYSDIR}" )
  test -d "$CERTSDIR" || mkdir "$CERTSDIR"

  # Variables that are dependent on args
  export USERHOME="$HOMEROOT/$USERACCOUNT"
  export BARE_REPO_DIR="$USERHOME/git/$PROJECT"
  PROJECT_DIR="$(project_path "$USERACCOUNT" "$PROJECT")"
  export PROJECT_DIR
  export WWWROOT="${PROJECT_DIR}${WEB_ROOT_DIRNAME}"
  export REAL_LOG_DIR="$VHOSTLOGROOT/$USERACCOUNT"
  export PROJECT_LOG_DIR="$REAL_LOG_DIR/$PROJECT"
  export FPM_ERROR_LOG="$PROJECT_LOG_DIR/php-fpm-error.log"
  if [ "${WEBSERVER}" == "apache" ]; then
    export SERVER_ACCESS_LOG="$PROJECT_LOG_DIR/apache-access.log"
    export SERVER_ERROR_LOG="$PROJECT_LOG_DIR/apache-error.log"
  elif [ "${WEBSERVER}" == "httpd" ]; then
      export SERVER_ACCESS_LOG="$PROJECT_LOG_DIR/httpd-access.log"
      export SERVER_ERROR_LOG="$PROJECT_LOG_DIR/httpd-error.log"
  else
    export SERVER_ACCESS_LOG="$PROJECT_LOG_DIR/nginx-access.log"
    export SERVER_ERROR_LOG="$PROJECT_LOG_DIR/nginx-error.log"
  fi
  export SETTINGS_LOCAL_PHP="$WWWROOT/sites/default/settings.local.php"

  # This is what acro-remove-website uses so it doesnt have to guess at names and paths. It may not stay completely accurate over the lifespan of a site, but its better than nothing.
  export HINTS_DIR="${USERHOME}/.acro-add-website"
  export HINTS_FILE="${USERHOME}/.acro-add-website/${PROJECT}"

  # Time to do some work
  if [ $USE_LE -eq 1 ]; then
    lets_encrypt "$FQDN" || exit 9
    LE_RENEW="/etc/letsencrypt/renewal/${FQDN}.conf"
  fi
  assert_service_user "$SERVICEACCOUNT" || exit 10
  assert_real_user "$USERACCOUNT" || exit 11
  assert_user_in_group "$USERACCOUNT" "$SERVICEACCOUNT" || exit 12
  assert_project_structure "$USERACCOUNT" "$SERVICEACCOUNT" "$PROJECT" || exit 13
  if [[ "$PHP_VERSION" != 'none' ]]; then
    assert_fpm_pool "$USERACCOUNT" "$SERVICEACCOUNT" "$PROJECT" "$FQDN" "$SOCKET_FILE" || exit 14
  fi
  assert_vhost "$USERACCOUNT" "$SERVICEACCOUNT" "$PROJECT"  "$FQDN" "$SOCKET_FILE" || exit 15
  if [ $USE_MYSQL -eq 1 ]; then
    assert_mysql_things "$USERACCOUNT" "$SERVICEACCOUNT" "$PROJECT" "$FQDN" || exit 16
  fi
  assert_logrotate_things || exit 17
  assert_postfix_aliases


  # Putting a shebang at the top of a bash include indicates clearly what the file is for, and it doesnt hurt anything when sourcing from other scripts.
  echo '#!/bin/bash' > "$HINTS_FILE"

  # Save the variables for easier access and to help the removal script.
  {
  echo "USERACCOUNT='${USERACCOUNT}'"
  echo "PROJECT='${PROJECT}'"
  echo "FQDN='${FQDN}'"
  echo "SERVICEACCOUNT='${SERVICEACCOUNT}'"
  echo "DBNAME='${DBNAME}'"
  echo "DBUSER='${DBUSER}'"
  echo "SOCKET_FILE='${SOCKET_FILE}'"
  echo "POOLDIR='${POOLDIR}'"
  echo "FPM_POOL_CONF='${FPM_POOL_CONF}'"
  echo "FPM_POOL_NAME='${FPM_POOL_NAME}'"
  echo "LOGROTATE_CONF='${LOGROTATE_CONF}'"
  echo "REAL_VHOST='${REAL_VHOST}'"
  echo "ENABLED_VHOST='${ENABLED_VHOST}'"
  echo "USERHOME='${USERHOME}'"
  echo "BARE_REPO_DIR='${BARE_REPO_DIR}'"
  echo "PROJECT_DIR='${PROJECT_DIR}'"
  echo "WWWROOT='${WWWROOT}'"
  echo "REAL_LOG_DIR='${REAL_LOG_DIR}'"
  echo "PROJECT_LOG_DIR='${PROJECT_LOG_DIR}'"
  echo "FPM_ERROR_LOG='${FPM_ERROR_LOG}'"
  echo "SERVER_ACCESS_LOG='${SERVER_ACCESS_LOG}'"
  echo "SERVER_ERROR_LOG='${SERVER_ERROR_LOG}'"
  echo "SETTINGS_LOCAL_PHP='${SETTINGS_LOCAL_PHP}'"
  echo "NEWRELIC_APPNAME='${NEWRELIC_APPNAME}'"
  echo "WEBSERVER='${WEBSERVER}'"
  echo "PHP_VERSION='${PHP_VERSION}'"
  echo "PHP_FPM_SERVICE_NAME='${PHP_FPM_SERVICE_NAME}'"
  } >> "${HINTS_FILE}"
  if [ $USE_LE -eq 1 ]; then
    echo "LE_RENEW='${LE_RENEW}'" >> "${HINTS_FILE}"
  fi

  # Some nice feedback for the user.
  local THISHOST
  THISHOST="$(hostname -f)"
  if [ $USE_SSL -eq 1 ]; then PROTOCOL="https"; else PROTOCOL="http"; fi
  cerr "------------------------------------------------------"
  cerr "######################################################"
  cerr "------------------------------------------------------"
  cerr "Your virtual host should now be accepting connections at $PROTOCOL://$FQDN"
  cerr ""
  cerr "Next steps for you:"
  cerr " - Import your database (see below for the location MySQL credentials)"
  cerr " - Set up a deploy job in your GitLab repo (see below for rsync destination)"
  cerr " - Trigger the deploy"
  cerr ""
  cerr "Rsync destination (for setting up your deploy job in GitLab): "
  cerr "- ssh://$USERACCOUNT@$THISHOST:$PROJECT_DIR/"
  cerr ""
  cerr "MySQL: "
  cerr "- Credentials are stored at $SETTINGS_LOCAL_PHP"
  cerr "- If you delete or overwrite the above file, you will need to reset the password for your project manually."
  cerr ""
  cerr "SFTP:"
  cerr "- hostname: $THISHOST"
  cerr "- remote dir: $PROJECT_DIR"
  cerr "- username: $USERACCOUNT"
  cerr "- password: n/a; use public key; all acro keys (including yours) are enabled for this account"
  cerr ""
  cerr "Log files: "
  cerr "- Server and PHP-FPM logs are at $REAL_LOG_DIR"
  if [ $WARNINGS -gt 0 ]; then
  cerr ""
  cerr "${BOLD}THERE WERE ${WARNINGS} WARNING(S) WHILE CREATING YOUR SITE. PLEASE REVIEW THE OUTPUT ABOVE BEFORE CONTINUING.${UNBOLD}"
  fi

}



#############################################################################
# Supporting functions
#----------------------------------------------------------------------------

function sanity_checks_pass () {
  if [[ -x /usr/bin/dpkg ]]; then
    PACKAGELIST=$(/usr/bin/dpkg --list)
  elif [[ -x /bin/rpm ]]; then
    PACKAGELIST=$(/bin/rpm -qa)
  else
    err "Could not query packages from OS. Aborting."
    exit 254
  fi
  local DPKG_SERVER
  if [ "${WEBSERVER}" == "apache" ]; then
    DPKG_SERVER="apache2"
  elif [[ "${WEBSERVER}" == "http" ]]; then
    DPKG_SERVER="httpd"
  else
    DPKG_SERVER="nginx"
  fi

  echo "$PACKAGELIST" | grep -w "${DPKG_SERVER}" | grep -qE 'ubuntu|bionic|focal|jammy|noble|resolute' || {
     warn "This script only supports NGINX/Apache2 on Ubuntu 18.04 or newer. Proceed at your own risk."
  }

  if [ "${WEBSERVER}" == "apache" ] || [ "${WEBSERVER}" == "httpd" ]; then
    export SITES_AVAILABLE="$APACHE_SITES_AVAILABLE"
    export SITES_ENABLED="$APACHE_SITES_ENABLED"
    export VHOST_CONF_TEMPLATE="${APACHE_CONF_TEMPLATE}"
    set -o pipefail
    if apachectl configtest 2>&1 | /bin/grep -q 'Syntax OK'; then
      true
    else
      err "Apache is not in a healthy state. Fix the following error(s) and try again:"
      apachectl configtest
      exit 19
    fi
    set +o pipefail
  else
    export SITES_AVAILABLE="$NGINX_SITES_AVAILABLE"
    export SITES_ENABLED="$NGINX_SITES_ENABLED"
    export VHOST_CONF_TEMPLATE="${NGINX_CONF_TEMPLATE}"
  fi

  if [[ "${PHP_VERSION}" == "none" ]]; then
    : # OK
  elif [[ "${PHP_VERSION}" == "5" ]]; then
     : # OK
  elif [[ "$PHP_VERSION" =~ [0-9].[0-9] ]]; then
    : # OK
  else
    cerr "${BOLD}ERR:${UNBOLD} This script isn't built to handle a PHP_VERSION value of: $PHP_VERSION"
    cerr "The PHP_VERSION variable is used to name some files, and to control services."
    exit 20
  fi

  if [[ "$PHP_VERSION" != 'none' ]]; then
    echo "$PACKAGELIST" | grep -q -- "php${PHP_VERSION}-fpm" || {
       warn "PHP ${PHP_VERSION} doesn't seem to be installed. Your site may not work."
    }
    for PKG in bcmath cli common curl fpm gd json mbstring mysql opcache readline soap xml xmlrpc zip; do
      echo "$PACKAGELIST" | grep -q -- "ii  php${PHP_VERSION}-${PKG}" || {
        warn "The following package is not installed: php${PHP_VERSION}-${PKG}"
      }
    done
  fi

  # nginx/apache on Ubuntu
  test -d "$SITES_AVAILABLE" || {
    cerr "${BOLD}ERR:${UNBOLD} ${WEBSERVER} sites-available dir does not exist: $SITES_AVAILABLE"
    exit 22
  }
  test -d "$SITES_ENABLED" || {
    # There won't be a sites-enabled dir on red hat/centos, so let this slide.
    warn "sites-enabled dir does not exist: $SITES_ENABLED"
  }
  test -f "$VHOST_CONF_TEMPLATE" || {
    cerr "${BOLD}ERR:${UNBOLD} Source ${WEBSERVER} template does not exist: $VHOST_CONF_TEMPLATE"
    exit 24
  }

  if [[ "$PHP_VERSION" != 'none' ]]; then
    # fpm
    test -d "$POOLDIR" || {
      # This wont exist for apache + mod php, so dont make it a show stopper
      warn "PHP FPM pool directory does not exist: $POOLDIR"
    }
    test -f "$FPM_CONF_TEMPLATE" || {
      # Even if we dont use this, it should still exist
      err "PHP FPM template file does not exist: $FPM_CONF_TEMPLATE"
      exit 254
    }
    # mysql
    test -f "$SETTINGS_LOCAL_TEMPLATE" || {
      cerr "${BOLD}ERR:${UNBOLD} Drupal mysql settings template does not exist: $FPM_CONF_TEMPLATE"
      exit 27
    }
  fi

  if [ $USE_MYSQL -eq 1 ]; then
    mysqlshow > /dev/null 2>&1 || {
      cerr "${BOLD}ERR:${UNBOLD} Cannot access mysql. Make sure you 'sudo -i <scriptname>' (or 'su -') to get root's full environment."
      exit 28
    }
  fi

  # dependent utilities & files
  # shellcheck disable=SC2065
  test -x "/usr/local/sbin/acro-add-user.sh" > /dev/null 2>&1 || {
    cerr "${BOLD}ERR:${UNBOLD} Could not locate the 'acro-add-user.sh' script. Make sure you 'sudo -i <scriptname>' (or 'su -') to get root's full environment."
    exit 29
  }
  type getent > /dev/null 2>&1 || {
    cerr "${BOLD}ERR:${UNBOLD} Missing 'getent' command."
    exit 30
  }
  type id > /dev/null 2>&1 || {
    cerr "${BOLD}ERR:${UNBOLD} Missing 'id' command."
    exit 31
  }

  ## TODO Make this work for apache too.
  if [ "${WEBSERVER}" == "nginx" ]; then
    test -e /etc/nginx/includes/robots.conf || {
      err "The file /etc/nginx/includes/robots.conf must be linked before sites can be added. Do one of the following, depending what environment this server is in:"
      cerr "  cd /etc/nginx/includes && ln -s robots.production.conf robots.conf"
      cerr "  cd /etc/nginx/includes && ln -s robots.staging.conf robots.conf"
      cerr "  cd /etc/nginx/includes && ln -s robots.development.conf robots.conf"
    }
  fi

  # Postfix
  type /usr/bin/newaliases > /dev/null 2>&1 || {
    cerr "${BOLD}ERR:${UNBOLD} Missing 'newaliases' command."
    exit 254
  }
  [[ -e /etc/aliases ]] || {
    cerr "${BOLD}ERR:${UNBOLD} File not found: /etc/aliases"
    exit 254
  }
  service postfix status > /dev/null || {
    warn "Could not get postfix status"
  }

  # Figure out which shell to set to set for PHP service user
  if [[ -x /usr/sbin/nologin ]]; then
    NOLOGIN=/usr/sbin/nologin
  elif [[ -x /sbin/nologin ]]; then
    NOLOGIN=/sbin/nologin
  else
    err "Could not determine which shell to set for service accounts. Aborting."
    exit 254
  fi

  if tty --quiet; then  # Is this an interactive session?
    cerr "${BOLD}Command line virtual host creation is now deprecated in favor of creation via ansible playbook.${UNBOLD}"
#    if [ $# -gt 0 ] && /usr/local/bin/optional-parameter-exists "--non-compliant" "$@"; then
#      true # Stay and play.
#    else
#      exit 1
#    fi
  fi

}

function is_root () {
  if [[ $EUID -eq 0 ]]; then
    true
  else
    false
  fi
}

function validate_account_string () {
  local USERACCOUNT="$1"
  if test -z "$USERACCOUNT"; then
    usage
    exit 254
  fi
  if ! is_sane_account_string "$USERACCOUNT"; then
    cerr "${BOLD}ERR:${UNBOLD} Invalid account name: '$USERACCOUNT'. Account names must be less than $MAX_ACCOUNT_STRING_LENGTH chars, start with an alpha and contain only alphanmeric, dash, or underscore characters."
    usage
    exit 254
  fi
  if is_system_user "$USERACCOUNT"; then
    cerr "${BOLD}ERR:${UNBOLD} '$USERACCOUNT' is a system account."
    exit 254
  fi
  if echo "$USERACCOUNT" | grep -q -- "-srv$"; then
    cerr "${BOLD}ERR:${UNBOLD} User account names shouldn't end in '-srv'. That distinction is reserved for service account names."
    exit 254
  fi
  if test -d "$HOMEROOT/$USERACCOUNT"; then
    local STATCODE
    STATCODE="$(stat -c %a "$HOMEROOT/$USERACCOUNT")"
    if [[ "$STATCODE" == "755" ]] || [[ "$STATCODE" == "751" ]]; then
      true # This is what we normally expect to see. Web server will be able to traverse through the home dir.
    else
      if tty --quiet; then  # Is this an interactive session? # only ask about this if we're running interactively.
        warn "Expected mode 751 or 755 on $HOMEROOT/${USERACCOUNT}. Found: ${STATCODE} instead."
        cerr "This condition most commonly occurs when trying to create a site in an administrator's home directory."
        cerr "The account you specify to create a site should either be new, or a non-privileged user instead."
        if ! require_yes_or_no "Are you sure you want to continue?"; then
          exit 254
        fi
      fi
    fi
  fi
}

function require_yes_or_no() {
  local PROMPT_TEXT="$1 (y/n): "
  printf "%s" "$PROMPT_TEXT"
  while read -r options; do
    case "$options" in
      "y") ANSWER=1; break ;;
      "n") ANSWER=0; break ;;
      *) printf "%s" "$PROMPT_TEXT" ;;
    esac
  done
  if [ $ANSWER -eq 1 ]; then
    true
  else
    false
  fi
}


function is_system_user () {
  local USERNAME="$1"
  local USERID
  # @TODO Fix for red hat / centos ... system users are usually 500 and below
  if ! linux_user_exists "$USERNAME"; then
    return 1 # false
  fi

  # @TODO: Figure out the correct way to find the user id limit; these are total assumptions.
  if /usr/bin/yum --version > /dev/null 2>&1 ; then
    # Red hat / centos
    ID_BOUNDARY=500
  elif /usr/bin/dpkg --version > /dev/null 2>&1 ; then
    # Debian / ubuntu
    # @TODO We should actually parse the real SYS_UID_MAX from /etc/login.defs.
    ID_BOUNDARY=1000
  else
    err "is_system_user(): No yum or dpkg? Can't guess where system user ids begin / end."
    exit 254
  fi
  USERID=$(id -u -- "$USERNAME")
  if [ "$USERID" -lt $ID_BOUNDARY ]; then
    true
  else
    false
  fi
}

function validate_project_string () {
  local PROJECT="$1"
  if test -z "$PROJECT"; then
    usage
    exit 254
  fi
  if ! is_sane_project_string "$PROJECT"; then
    cerr "${BOLD}ERR:${UNBOLD} bad project string (must be less than $MAX_ACCOUNT_STRING_LENGTH chars with no punctuation): $PROJECT"
    usage
    exit 254
  fi
  if echo "$PROJECT" | grep -q -- "-srv$"; then
    cerr "${BOLD}ERR:${UNBOLD} Project names shouldn't end in '-srv'. That distinction is reserved for service account names."
    exit 254
  fi

}

function err () {
  cerr "${BOLD}ERR:${UNBOLD} $*"
}

function validate_fqdn () {
  local FQDN="$1"
  if ! is_sane_fqdn "$FQDN"; then
    cerr "${BOLD}ERR:${UNBOLD} bad fqdn string: $FQDN"
    usage
    exit 254
  fi
}

# returns 0 for yes, a number other than 0 for no.
function is_sane_account_string () {
  local ARG="$1"
  if [[ ! "$ARG" =~ ^[A-Za-z]+[A-Za-z0-9_-]+$ ]]; then
    return 1 # invalid characters
  fi
  if [ "${#ARG}" -gt "$MAX_ACCOUNT_STRING_LENGTH" ]; then
    return 2 # too long
  fi
  return 0
}

# returns 0 for yes, a number other than 0 for no.
function is_sane_mysql_user_name () {
  local ARG="$1"
  if [[ ! "$ARG" =~ ^[A-Za-z]+[A-Za-z0-9_]+$ ]]; then
    return 1 # invalid characters
  fi
  if [ "${#ARG}" -gt "$MAX_MYSQL_USERNAME_LENGTH" ]; then
    return 2 # too long
  fi
  return 0
}

# returns 0 for yes, a number other than 0 for no.
function is_sane_mysql_db_name () {
  local ARG="$1"
  if [[ ! "$ARG" =~ ^[A-Za-z]+[A-Za-z0-9_]+$ ]]; then
    return 1 # invalid characters
  fi
  if [ "${#ARG}" -gt "$MAX_MYSQL_DBNAME_LENGTH" ]; then
    return 2 # too long
  fi
  return 0
}

function is_sane_project_string () {
  local ARG="$1"
  if is_sane_account_string "$ARG"; then
    true
  else
    false
  fi
}

function is_sane_fqdn () {
  local ARG="$1"
  if echo "$ARG" | grep -Pq '(?=^.{5,254}$)(^(?:(?!\d+\.)[a-zA-Z0-9_\-]{1,63}\.?)+(?:[a-zA-Z]{2,})$)'; then
    true
  else
    false
  fi
}

function assert_project_structure () {
  local USERACCOUNT="$1"
  local SERVICEACCOUNT="$2"
  local PROJECT="$3"

  local directories=()

  # from export: USERHOME
  directories+=("$USERHOME")
  directories+=("$USERHOME/git")
  directories+=("$USERHOME/www")

  # from export: BARE_REPO_DIR
  directories+=("$BARE_REPO_DIR")

  # from export: PROJECT_DIR
  directories+=("$PROJECT_DIR")
  local PRIVATE_DIR="$PROJECT_DIR/private"
  directories+=("$PRIVATE_DIR")
  for ((i=0; i < ${#directories[@]}; i++)); do
    DIR="${directories[$i]}"
    test -d "$DIR" || (mkdir "$DIR" && chown "$USERACCOUNT:" "$DIR")
    chmod 751 "$DIR"
  done

  local public_dirs=()
  # from export: WWWROOT
  public_dirs+=("$WWWROOT")
  public_dirs+=("$WWWROOT/sites")
  public_dirs+=("$WWWROOT/sites/default")
  local FILES_DIR="$WWWROOT/sites/default/files"
  public_dirs+=("$FILES_DIR")
  for ((i=0; i < ${#public_dirs[@]}; i++)); do
    DIR="${public_dirs[$i]}"
    test -d "$DIR" || (mkdir "$DIR" && chown "$USERACCOUNT:" "$DIR")
    chmod 755 "$DIR"
  done

  # Create the hints dir as root so it can't be messed with, but let everyone read its contents.
  mkdir --parents --mode 0755 "${HINTS_DIR}"

  # Log Dirs and Files
  # Lock down /var/log/ACCOUNT/PROJECT so only root:adm can read them. Other processes still need traverse access through them.
  # @TODO Fow now, we'll give "all" execute on the dirs. In the future we should lock them down to 0750, and use ACL's to allow the individual PHP process access to its log file.
  test -d "$REAL_LOG_DIR" || mkdir "$REAL_LOG_DIR"
  chmod 0751 "$REAL_LOG_DIR"
  chown root:adm "$REAL_LOG_DIR"
  test -d "$PROJECT_LOG_DIR" || mkdir "$PROJECT_LOG_DIR"
  chmod 0751 "$PROJECT_LOG_DIR"
  chown root:adm "$PROJECT_LOG_DIR"
  local LOGLINK="$USERHOME/logs"
  if ! test -L "$LOGLINK"; then
    ln -s "$REAL_LOG_DIR" "$LOGLINK"
  fi
  # Precipitate the error log files
  (umask 027 && touch "$FPM_ERROR_LOG")
  chown "${SERVICEACCOUNT}":adm "$FPM_ERROR_LOG"
  (umask 027 && touch "$SERVER_ACCESS_LOG")
  chown "${WEBSERVER_PROCESS_OWNER}":adm "$SERVER_ACCESS_LOG"
  (umask 027 && touch "$SERVER_ERROR_LOG")
  chown "${WEBSERVER_PROCESS_OWNER}":adm "$SERVER_ERROR_LOG"


  # permissions private + files
  chown -R "$USERACCOUNT:$SERVICEACCOUNT" "$FILES_DIR"
  find "$FILES_DIR" -type d -exec chmod 2771 {} \;
  find "$FILES_DIR" -type f -exec chmod 664 {} \;
  chown -R "$USERACCOUNT:$SERVICEACCOUNT" "$PRIVATE_DIR"
  find "$PRIVATE_DIR" -type d -exec chmod 2770 {} \;
  find "$PRIVATE_DIR" -type f -exec chmod 660 {} \;

  local INDEXFILE
  if [[ "$PHP_VERSION" == 'none' ]]; then
    INDEXFILE="$WWWROOT/index.html"
  else
    INDEXFILE="$WWWROOT/index.php"
  fi
  if test -f "$INDEXFILE"; then
    cerr "Index file already exists: $INDEXFILE"
  else
    # shellcheck disable=SC2016
    # shellcheck disable=SC2028
    if [[ "$PHP_VERSION" == 'none' ]]; then
      echo "<h1>It works!</h1><hr/><p>Hello from ${FQDN}.</p>" >> "$INDEXFILE"
    else
      echo '<?php echo "<h1>It works!</h1><hr/><p>Hello, " . $_SERVER["REMOTE_ADDR"] . "</p>\n";' >> "$INDEXFILE"
    fi
    chown "$USERACCOUNT:$USERACCOUNT" "$INDEXFILE"
    # {
    ### Leave this here. It's helpful for making sure FPM is logging correctly after making changes to the script.
    #  echo "<?php error_reporting(E_ALL);  ini_set('display_errors', TRUE);  ini_set('display_startup_errors', TRUE); testing_fpm_error_reporting__hopefully_this_throws_an_exception(); " >> "$WWWROOT/error.php"
    # }
  fi

  # ssh authorized keys
  local SSHDIR="$USERHOME/.ssh"
  local AUTHORIZED_KEYS="$SSHDIR/authorized_keys"
  if ! test -d "$SSHDIR"; then
    (umask 077 && mkdir "$SSHDIR" && touch "$AUTHORIZED_KEYS")
    /usr/local/sbin/acro-add-user.sh --dump-keys > "$AUTHORIZED_KEYS" 2>/dev/null
    chown -R "$USERACCOUNT:$USERACCOUNT" "$SSHDIR"
  fi

}

function linux_user_exists () {
  local USERACCOUNT="$1"
  if getent passwd -- "$USERACCOUNT" > /dev/null 2>&1; then
    true
  else
    false
  fi
}

function assert_real_user () {
  local USERACCOUNT="$1"
  if linux_user_exists "$USERACCOUNT"; then
    cerr "User account already exists: $USERACCOUNT"
    return
  fi
  if ! useradd -m "$USERACCOUNT"; then
    warn "Useradd exited with an error"
    if [ $FORCE -ne 1 ] ; then
      exit 254
    fi
  fi
  if test -x /bin/bash; then
    chsh --shell /bin/bash "$USERACCOUNT"
  else
    cerr "Could not set shell to bash for $USERACCOUNT"
  fi
}

function assert_service_user () {
  local SERVICEACCOUNT="$1"
  if linux_user_exists "$SERVICEACCOUNT"; then
    cerr "Service account already exists: $SERVICEACCOUNT"
    return
  fi
  if ! useradd --system "$SERVICEACCOUNT"; then
    if [ $FORCE -ne 1 ] ; then
      exit 254
    fi
  fi
  if ! chsh --shell $NOLOGIN "$SERVICEACCOUNT"; then
    if [ $FORCE -ne 1 ] ; then
      exit 254
    fi
  fi
}



function assert_user_in_group () {
  local USER="$1"
  local GROUP="$2"
  if getent group "$GROUP" > /dev/null; then
    if groups "$USER"|grep -q "\b$GROUP\b"; then
      : # user is in group.
    else
      usermod -a -G "$GROUP" "$USER"
    fi
  else
    cerr "${BOLD}ERR:${UNBOLD} assert_user_in_group(): group does not exist: $GROUP"
    exit 254
  fi
}

function assert_fpm_pool () {
  local USERACCOUNT="$1"
  local SERVICEACCOUNT="$2"
  local PROJECT="$3"
  local FQDN="$4"
  local SOCKET_FILE="$5"

  # Template values
  local SERVICE_USER="$SERVICEACCOUNT"
  local SERVICE_GROUP="$SERVICEACCOUNT"
  local LISTEN_OWNER="$WEBSERVER_PROCESS_OWNER"
  local LISTEN_GROUP="$WEBSERVER_PROCESS_OWNER"

  # From export: FPM_POOL_CONF, FPM_POOL_NAME, FPM_ERROR_LOG
  if test -f "$FPM_POOL_CONF"; then
    cerr "${BOLD}ERR:${UNBOLD} PHP FPM conf already exists: $FPM_POOL_CONF"
  else
    local TMPFILE
    TMPFILE="$(mktemp)"
    cat "$FPM_CONF_TEMPLATE" > "$TMPFILE"
    sed -i -e "s!{{ pool_name }}!$FPM_POOL_NAME!g" "$TMPFILE"
    sed -i -e "s!{{ service_user }}!$SERVICE_USER!g" "$TMPFILE"
    sed -i -e "s!{{ service_group }}!$SERVICE_GROUP!g" "$TMPFILE"
    sed -i -e "s!{{ socket_file }}!$SOCKET_FILE!g" "$TMPFILE"
    sed -i -e "s!{{ listen_owner }}!$LISTEN_OWNER!g" "$TMPFILE"
    sed -i -e "s!{{ listen_group }}!$LISTEN_GROUP!g" "$TMPFILE"
    sed -i -e "s!{{ error_log }}!$FPM_ERROR_LOG!g" "$TMPFILE"
    sed -i -e "s!{{ project_dir }}!$PROJECT_DIR!g" "$TMPFILE"
    sed -i -e "s!{{ newrelic_appname }}!${NEWRELIC_APPNAME}!g" "$TMPFILE"
    install -o root -g root -m 644 -T "$TMPFILE" "$FPM_POOL_CONF"
    rm "$TMPFILE"
    if ! service "$PHP_FPM_SERVICE_NAME" restart > /dev/null; then
      warn "Service was not started: $PHP_FPM_SERVICE_NAME ... your website may not work."
    fi
  fi

}

function assert_vhost () {
  local USERACCOUNT="$1"
  local SERVICEACCOUNT="$2"
  local PROJECT="$3"
  local FQDN="$4"
  local SOCKET_FILE="$5"

  # Template values
  local DOCROOT="${WWWROOT}"
  if [ $USE_LE -eq 1 ]; then
    local SSL_CERT="$LE_LIVE_DIR/$FQDN/fullchain.pem"
    local SSL_KEY="$LE_LIVE_DIR/$FQDN/privkey.pem"
    local SSL_CA_BUNDLE="$LE_LIVE_DIR/$FQDN/chain.pem"
  else
    local SSL_CERT="$CERTSDIR/$FQDN.fullchain.pem"
    local SSL_KEY="$KEYSDIR/$FQDN.key"
    local SSL_CA_BUNDLE="$CERTSDIR/$FQDN.intermediates.pem"
  fi

  # From export: REAL_VHOST, ENABLED_VHOST
  if test -f "$REAL_VHOST"; then
    cerr "Vhost file already exists: $REAL_VHOST"
  else
    local TMPFILE
    TMPFILE="$(mktemp)"
    cat "$VHOST_CONF_TEMPLATE" > "$TMPFILE"
    sed -i "s!{{ fqdn }}!$FQDN!g" "$TMPFILE"
    sed -i "s!{{ docroot }}!$DOCROOT!g" "$TMPFILE"
    sed -i "s!{{ ssl_cert }}!$SSL_CERT!g" "$TMPFILE"
    sed -i "s!{{ ssl_key }}!$SSL_KEY!g" "$TMPFILE"
    sed -i "s!{{ ssl_ca_bundle }}!$SSL_CA_BUNDLE!g" "$TMPFILE"
    sed -i "s!{{ access_log }}!$SERVER_ACCESS_LOG!g" "$TMPFILE"
    sed -i "s!{{ error_log }}!$SERVER_ERROR_LOG!g" "$TMPFILE"
    sed -i "s!{{ socket_file }}!$SOCKET_FILE!g" "$TMPFILE"
    install -o root -g root -m 644 -T "$TMPFILE" "$REAL_VHOST"
    rm "$TMPFILE"
fi

  if test -L "$ENABLED_VHOST"; then
    cerr "Site is already enabled: $ENABLED_VHOST"
  else
    ln -s "$REAL_VHOST" "$ENABLED_VHOST"
    if [ "${WEBSERVER}" == "apache" ]; then
      # Apache on Ubuntu
      apachectl configtest 2>&1 | /bin/grep -v 'Syntax OK'
      service apache2 reload > /dev/null
    elif [ "${WEBSERVER}" == "httpd" ]; then
      # Apache on Red Hat
      apachectl configtest 2>&1 | /bin/grep -v 'Syntax OK'
      service httpd reload > /dev/null
    else
      # Implied "Nginx"
      nginx -tq > /dev/null   # -tq == Quiet unless there is a config error, which we will want to see in case the service reload fails.
      service nginx reload > /dev/null
    fi
  fi
}

function lets_encrypt () {
  local FQDN="$1"

  if test -e "$LE_LIVE_DIR/$FQDN"; then
    warn "LetsEncrypt files already exist: $LE_LIVE_DIR/$FQDN"
  fi

  if test -e "$REAL_VHOST"; then
    err "Vhost already exists: $REAL_VHOST"
    if [ $FORCE -ne 1 ]; then
      exit 254
    fi
  fi

  if test -e "$ENABLED_VHOST"; then
    err "Vhost is already enabled: $ENABLED_VHOST"
    if [ $FORCE -ne 1 ]; then
      exit 254
    fi
  fi

  # Create a temporary site so we can generate the cert
  local TMPFILE
  TMPFILE="$(mktemp)"
  cat "$ACROCONFROOT/${WEBSERVER}-acme-challenge-conf.j2" > "$TMPFILE"
  sed -i "s!{{ fqdn }}!$FQDN!g" "$TMPFILE"
  install -o root -g root -m 644 -T "$TMPFILE" "$REAL_VHOST"
  rm "$TMPFILE"
  ln -s "$REAL_VHOST" "$ENABLED_VHOST"
  if [ "${WEBSERVER}" == "nginx" ]; then
    nginx -ttq > /dev/null   # Emits an error if there is a config issue, which we want in case the service reload fails.
    service nginx reload > /dev/null
  else
    apachectl configtest 2>&1 | /bin/grep -v 'Syntax OK'
    service apache2 reload > /dev/null
  fi

  # Generate the cert
  if "$CERTBOT" certonly --no-self-upgrade --webroot -w "$LE_WWW" -d "$FQDN" --dry-run \
  && "$CERTBOT" certonly --no-self-upgrade --webroot -w "$LE_WWW" -d "$FQDN"; then
    : # It worked without an error
  else
    if test -L "/etc/letsencrypt/live/${FQDN}/cert.pem" \
    && test -L "/etc/letsencrypt/live/${FQDN}/chain.pem" \
    && test -L "/etc/letsencrypt/live/${FQDN}/fullchain.pem" \
    && test -L "/etc/letsencrypt/live/${FQDN}/privkey.pem" \
    && [ "$(find "/etc/letsencrypt/archive/${FQDN}/" -type f -mtime -60|wc -l)" -ge 4 ]; then
      if tty --quiet; then  # Only ask if this is an interactive session
        cerr ""
        cerr "The LetsEncrypt process returned an error, but the SSL files exist."
        cerr "This probably means a previous attempt to create the site was successful in registering the SSL cert, but failed somewhere else."
        if ! require_yes_or_no "Do you want to ignore the letsencrypt error and continue with site setup?"; then
          rm "$REAL_VHOST" "$ENABLED_VHOST"
          exit 254
        fi
      else
        # We're probably running from a playbook ... Assume the scenario described above and try getting past it with the "--keep" flag.
        if "$CERTBOT" certonly --no-self-upgrade --webroot -w "$LE_WWW" -d "$FQDN" --keep --dry-run \
        && "$CERTBOT" certonly --no-self-upgrade --webroot -w "$LE_WWW" -d "$FQDN" --keep; then
            true # It worked
        else
          rm "$REAL_VHOST" "$ENABLED_VHOST"
          err "Could not register or keep LE SSL cert ... manual intervention is required."
          exit 254
        fi
      fi
    else
      rm "$REAL_VHOST" "$ENABLED_VHOST"
      exit 254
    fi
  fi

  # Remove the temporary site
  rm "$REAL_VHOST" "$ENABLED_VHOST"
  if [ "${WEBSERVER}" == "nginx" ]; then
    nginx -ttq > /dev/null   # Emits an error if there is a config issue, which we want in case the service reload fails.
    service nginx reload > /dev/null
  else
    apachectl configtest 2>&1 | /bin/grep -v 'Syntax OK'
    service apache2 reload > /dev/null
  fi

}

function assert_mysql_things () {
  local USERACCOUNT="$1"
  local SERVICEACCOUNT="$2"
  local PROJECT="$3"
  local FQDN="$4"

  # from export: DBNAME
  if mysql -e "use $DBNAME" > /dev/null 2>&1; then
    cerr "Database already exists: $DBNAME"
  else
    if mysql -e "create database $DBNAME; flush privileges"; then
      echo "MySQL database created: $DBNAME"
    else
      cerr "There was an error trying to create database: $DBNAME"
    fi
  fi

  # from export: DBUSER
  if mysql_user_exists "$DBUSER" "${MYSQL_ALLOW_FROM}"; then
    cerr "Mysql user '$DBUSER' already exists. Not creating 'settings.local.php'."
  else
    if [ -z "$DBPASS" ]; then
      DBPASS=$(/usr/bin/openssl rand -base64 24) # Auto generate if not yet set.
    fi

    if mysql -e "CREATE USER '${DBUSER}'@'${MYSQL_ALLOW_FROM}' IDENTIFIED BY '$DBPASS'; flush privileges;"; then
      echo "MySQL user created: $DBUSER"
    else
      warn "There was an error trying to create MySQL user: $DBUSER"
    fi

    local PRIVS
    if [ $IS_RDS -eq 1 ]; then
      # RDS doesn't allow "Grant all". We have to explicitly specify the privileges we want the new user to have.
      PRIVS='SELECT,INSERT,UPDATE,DELETE,CREATE,DROP,REFERENCES,INDEX,ALTER,CREATE TEMPORARY TABLES,LOCK TABLES,EXECUTE,CREATE VIEW,SHOW VIEW,CREATE ROUTINE,ALTER ROUTINE'
    else
      PRIVS='ALL PRIVILEGES'
    fi
    if (set -x && mysql -e "GRANT $PRIVS ON $DBNAME.* TO '${DBUSER}'@'${MYSQL_ALLOW_FROM}'; flush privileges;" ) ; then
      echo "MySQL privileges updated for: $DBUSER"
    else
      warn "There was an error trying to grant privileges to MySQL user: $DBUSER ($PRIVS)"
    fi

    #  from export: local SETTINGS_LOCAL_PHP
    if test -f "$SETTINGS_LOCAL_PHP"; then
      cerr "Drupal local settings file already exists."
    else
      local TMPFILE
      TMPFILE="$(mktemp)"
      cat "$SETTINGS_LOCAL_TEMPLATE" > "$TMPFILE"
      sed -i "s!{{ db_user }}!$DBUSER!g" "$TMPFILE"
      sed -i "s!{{ db_pass }}!$DBPASS!g" "$TMPFILE" # WHAT IF THE PASSWORD HAS AN EXCLAMATION POINT IN IT??
      sed -i "s!{{ db_name }}!$DBNAME!g" "$TMPFILE"
      sed -i "s!{{ db_host_address }}!${MYSQL_HOST_ADDRESS}!g" "$TMPFILE"
      install -o "$USERACCOUNT" -g "$SERVICEACCOUNT" -m 640 -T "$TMPFILE" "$SETTINGS_LOCAL_PHP"
      rm "$TMPFILE"
      #cerr "MySQL connection settings have been saved to $SETTINGS_LOCAL_PHP"
    fi
  fi

}

function assert_logrotate_things () {
  # Template values:
  #   From export: PROJECT_LOG_DIR
  #   From export: WEBSERVER_PROCESS_OWNER
  #   From export: SERVICEACCOUNT
  #   From export: FPM_ERROR_LOG
  if test -f "$LOGROTATE_CONF"; then
    warn "Logrotate conf already exists: $LOGROTATE_CONF"
  else
    local TMPFILE
    TMPFILE="$(mktemp)"
    cat "$LOGROTATE_CONF_TEMPLATE" > "$TMPFILE"
    sed -i "s!{{ project_log_dir }}!$PROJECT_LOG_DIR!g" "$TMPFILE"
    sed -i "s!{{ WEBSERVER }}!$WEBSERVER!g" "$TMPFILE"
    sed -i "s!{{ WEBSERVER_PROCESS_OWNER }}!$WEBSERVER_PROCESS_OWNER!g" "$TMPFILE"
    sed -i "s!{{ serviceaccount }}!$SERVICEACCOUNT!g" "$TMPFILE"
    sed -i "s!{{ fpm_error_log }}!$FPM_ERROR_LOG!g" "$TMPFILE"
    sed -i "s!{{ fpm_logrotate_postrotate }}!$PHP_FPM_LOGROTATE_POSTROTATE!g" "$TMPFILE"
    install -o root -g root -m 644 -T "$TMPFILE" "$LOGROTATE_CONF"
    rm "$TMPFILE"
  fi
}

# Make sure there's a mapping in /etc/aliases for both the web account owner and the PHP owner, so that
# when a cron job burps out an error, someone actually finds out about it.
# Previous to this, we've found local mailboxes that were hundreds of MB large with errors that no one had any clue about.
function assert_postfix_aliases () {
  local DO_POSTFIX_RELOAD=0
  if ! grep -w "^${USERACCOUNT}" /etc/aliases; then
    echo "${USERACCOUNT}: ${RESPONSIBLE_PERSON}" >> /etc/aliases
    DO_POSTFIX_RELOAD=1
  fi
  if ! grep -w "^${SERVICEACCOUNT}" /etc/aliases; then
    echo "${SERVICEACCOUNT}: ${RESPONSIBLE_PERSON}" >> /etc/aliases
    DO_POSTFIX_RELOAD=1
  fi
  if [[ $DO_POSTFIX_RELOAD -eq 1 ]]; then
    /usr/bin/newaliases
    service postfix reload
  fi
}


function make_compound_mysql_user_name () {
  local USERACCOUNT="$1"
  local PROJECT="$2"
  NO_DUPE_PROJECT="${PROJECT/$USERACCOUNT/}"  # strip occurrences of USERACCOUNT from PROJECT : i.e. convert project 'sandler-shop' to '-sandler' when account is 'sandler'
  NO_DUPE_PROJECT="$(strip_non_alphanumerics "$NO_DUPE_PROJECT")"   # get rid of any remaining artifacts
  ACCOUNT_MAX_LEN=$((MAX_MYSQL_USERNAME_LENGTH/2))
  PROJECT_MAX_LEN=$((ACCOUNT_MAX_LEN-1))
  echo "$(strip_non_alphanumerics "$USERACCOUNT"|cut -c1-$ACCOUNT_MAX_LEN)_$(echo "$NO_DUPE_PROJECT"|cut -c1-$PROJECT_MAX_LEN)"
}

function make_compound_mysql_db_name () {
  local USERACCOUNT="$1"
  local PROJECT="$2"
  NO_DUPE_PROJECT="${PROJECT/$USERACCOUNT/}"  # strip occurrences of USERACCOUNT from PROJECT : i.e. convert project 'sandler-shop' to '-sandler' when account is 'sandler'
  NO_DUPE_PROJECT="$(strip_non_alphanumerics "$NO_DUPE_PROJECT")"   # get rid of any remaining artifacts
  ACCOUNT_MAX_LEN=$((MAX_MYSQL_DBNAME_LENGTH/2))
  PROJECT_MAX_LEN=$((ACCOUNT_MAX_LEN-1))
  echo "$(strip_non_alphanumerics "$USERACCOUNT"|cut -c1-$ACCOUNT_MAX_LEN)_$(echo "$NO_DUPE_PROJECT"|cut -c1-$PROJECT_MAX_LEN)"
}


function make_compound_service_account_name () {
  local USERACCOUNT="$1"
  local PROJECT="$2"
  NO_DUPE_PROJECT="${PROJECT/$USERACCOUNT/}"  # strip occurrences of USERACCOUNT from PROJECT : i.e. convert project 'sandler-shop' to '-sandler' when account is 'sandler'
  NO_DUPE_PROJECT="$(strip_non_alphanumerics "$NO_DUPE_PROJECT")"   # get rid of any remaining artifacts
  ADJUSTED_RAW_MAX=$((MAX_ACCOUNT_STRING_LENGTH-4)) # need to account for the '-srv' characters we're going to append to it
  ACCOUNT_MAX_LEN=$((ADJUSTED_RAW_MAX/2))
  PROJECT_MAX_LEN=$((ACCOUNT_MAX_LEN-1))
  COMPOUND_NAME="$(echo "$USERACCOUNT"| cut -c1-$ACCOUNT_MAX_LEN)-$(echo "$NO_DUPE_PROJECT"| cut -c1-$PROJECT_MAX_LEN)-srv"
  echo "$COMPOUND_NAME"
}

function safe_mysql_db_name () {
  strip_non_alphanumerics "$1" | cut -c1-64
}

function safe_mysql_user_name () {
  strip_non_alphanumerics "$1" | cut -c1-16
}

function mysql_user_exists () {
  local USERNAME="$1"
  local ALLOW_FROM="$2"
  RESULT="$(mysql -se "SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user = '$USERNAME' and host = '${ALLOW_FROM}')")"
  if [[ $RESULT == "1" ]]; then
    true
  else
    false
  fi
}

# Aborts the script if there's a false negative.
function mysql_db_exists () {
  local DBNAME="$1"
  # Underscores are treated as wildcards by mysqlshow.
  # Replace them with '\\_'. One of the underscores is consumed by the shell to keep the one mysqlshow needs in tact.
  ESCAPED_DB_NAME="${DBNAME//_/\\\_}"
  RESULT="$(mysqlshow "$ESCAPED_DB_NAME" 2>&1)"; EXITCODE=$?
  if [ "$EXITCODE" -eq 0 ]; then
    # This is never a false positive.
    true
  else
    if echo "$RESULT" | grep -iq "Unknown database"; then
      # True negative.
      false
    else
      # False negative: Abort the script.
      cerr "ERR (mysql_db_exists): $RESULT"
      exit 254
    fi
  fi
}

function project_path () {
  local USERACCOUNT="$1"
  local PROJECT="$2"
  echo "$HOMEROOT/$USERACCOUNT/www/$PROJECT"
}

function project_exists () {
  local USERACCOUNT="$1"
  local PROJECT="$2"
  if test -e "$(project_path "$USERACCOUNT" "$PROJECT")"; then
    true
  else
    false
  fi
}

function strip_non_alphanumerics () {
  arg="${1:-}"
  echo "${arg//[^a-zA-Z0-9]/}"
}

# Leaves dashes & underscores
function strip_non_slug_chars () {
  arg="${1:-}"
  echo "${arg//[^a-zA-Z0-9\-_]/}"
}

# All should come from export variables.
function prevent_name_collisions () {
  NAME_COLLISION_HELP="A future version of this script may allow more granular specification of account and file names [to override the ones that this script generates]. In the mean time, you'll need to pick a different project or domain name to avoid collision."
  if linux_user_exists "$SERVICEACCOUNT"; then
    cerr "${BOLD}ERR:${UNBOLD} The linux user '$SERVICEACCOUNT' (for services) already exists."
    cerr "$NAME_COLLISION_HELP"
    usage
    exit 254
  fi
  if [ $USE_MYSQL -eq 1 ]; then
    if mysql_db_exists "$DBNAME"; then
      cerr "${BOLD}ERR:${UNBOLD} The mysql database '$DBNAME' already exists."
      cerr "$NAME_COLLISION_HELP"
      usage
      exit 254
    fi
    if mysql_user_exists "$DBUSER" "${MYSQL_ALLOW_FROM}"; then
      cerr "${BOLD}ERR:${UNBOLD} The mysql user '$DBUSER' already exists."
      cerr "$NAME_COLLISION_HELP"
      usage
      exit 254
    fi
  fi
  if [[ "$PHP_VERSION" != 'none' ]]; then
    if test -e "$SOCKET_FILE"; then
      cerr "${BOLD}ERR:${UNBOLD} The socket file '$SOCKET_FILE' already exists."
      cerr "$NAME_COLLISION_HELP"
      usage
      exit 254
    fi
    if test -e "$FPM_POOL_CONF"; then
      cerr "${BOLD}ERR:${UNBOLD} The FPM pool '$FPM_POOL_CONF' already exists."
      cerr "$NAME_COLLISION_HELP"
      usage
      exit 254
    fi
  fi
  if test -e "$REAL_VHOST" || test -e "$ENABLED_VHOST"; then
    cerr "${BOLD}ERR:${UNBOLD} There is already a virtual host using the name '$FQDN' on this server."
    cerr "$NAME_COLLISION_HELP"
    usage
    exit 254
  fi
}


function ctrl_c() {
  # When using "read -e", weird things happen if ctrl + c gets called. Stty sane fixes that. Could also use 'reset' but thats really aggressive.
  stty sane
  exit 254
}

function prompt_for_value_with_default() {
  trap ctrl_c INT # read -re causes weird things if you ctrl+c; we need to make sure to clean up after ourselves.
  # All this for the benefit of RHEL 5, which uses bash 3, and doesn't support the "-i" switch of the "read" shell builtin.
  local VARIABLE_NAME="$1"
  local DEFAULT_VALUE="$2"
  local VARIABLE_VALUE
  if bash --version |head -1|grep -qoi 'version 5'; then
    read -r -e -p "$VARIABLE_NAME: " -i "$DEFAULT_VALUE" VARIABLE_VALUE
  elif bash --version |head -1|grep -qoi 'version 4'; then
    read -r -e -p "$VARIABLE_NAME: " -i "$DEFAULT_VALUE" VARIABLE_VALUE
  elif bash --version |head -1|grep -qoi 'version 3'; then
    read -r -p "$VARIABLE_NAME [$DEFAULT_VALUE]: " VARIABLE_VALUE
    if test -z "${VARIABLE_VALUE}"; then
      VARIABLE_VALUE="$DEFAULT_VALUE"
    fi
  else
    fatal "Unhandled bash version."
    exit 1
  fi
  # Return the value to the caller.
  echo "$VARIABLE_VALUE"
}

WARNINGS=0
function warn () {
  cerr "${BOLD}Warn:${UNBOLD} $*"
  WARNINGS=$((WARNINGS+1))
}

function cerr () {
  >&2 echo "$@"
}

function usage () {
  cerr "Usage:"
  cerr "  $(basename "$0") [ --account foo --project bar --fqdn www.foobar.com --webroot wwwroot]"
  cerr "  Any paramater you don't specify will be asked for interactively."
  cerr "  See https://wiki.acromediainc.com/wiki/Acro-add-website.sh for full documentation."
}



readonly ACROCONFROOT="/etc/acro"

BOLD=$(tput bold 2>/dev/null) || BOLD='\033[1;33m' # orange, if tput isnt available.
UNBOLD=$(tput sgr0 2>/dev/null) || UNBOLD='\033[m'



if ! [[ $EUID -eq 0 ]]; then
  >&2 echo "${BOLD}ERR:${UNBOLD} This script must be run as root. Try: sudo -i $(basename "$0")"
  exit 12
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
NOLOGIN='' # will be set later.

readonly LE_LIVE_DIR="/etc/letsencrypt/live"
CERTBOT=$(find_certbot)
readonly LE_WWW="/var/www/letsencrypt"

# Set default, and override later
USE_LE=0
USE_SSL=0
VHOST_CONF_STUB=""

IS_RDS=0

if [ $# -gt 0 ] && /usr/local/bin/optional-parameter-exists "--rds" "$@"; then
  IS_RDS=1
fi

FORCE=0
if [ $# -gt 0 ] && /usr/local/bin/optional-parameter-exists "--force" "$@"; then
  FORCE=1
  >&2 echo "FORCE=1 has been specified. Errors will be ignored. Good luck, soldier."
fi

WEBSERVER="nginx"
if [ $# -gt 0 ] && /usr/local/bin/optional-parameter-exists "--apache" "$@"; then
  # Apache on Ubuntu
  WEBSERVER="apache"
elif [ $# -gt 0 ] && /usr/local/bin/optional-parameter-exists "--httpd" "$@"; then
  # Apache on Red Hat
  WEBSERVER="httpd"
fi

# Allow creation of a site without MySQL ... this is meant to be used along with "--php-version none"
USE_MYSQL=1
if [ $# -gt 0 ] && (/usr/local/bin/optional-parameter-exists "--skip-mysql" "$@" || /usr/local/bin/optional-parameter-exists "--no-mysql" "$@"); then
  USE_MYSQL=0
else
  if [ $# -gt 0 ] && /usr/local/bin/optional-parameter-exists "--mysql-allow-from" "$@"; then
    MYSQL_ALLOW_FROM="$(/usr/local/bin/require-named-parameter "--mysql-allow-from" "$@")"
  else
    MYSQL_ALLOW_FROM='localhost'
  fi

  # @TODO See if we can detect this from the mysql connection that we're on, intead of having to provide it manually.
  #       Parse it out of /root/.my.cnf maybe? Can we find this out from the mysql cli client?
  if [ $# -gt 0 ] && /usr/local/bin/optional-parameter-exists "--mysql-host-address" "$@"; then
    MYSQL_HOST_ADDRESS="$(/usr/local/bin/require-named-parameter "--mysql-host-address" "$@")"
  else
    MYSQL_HOST_ADDRESS='localhost'
  fi
fi


if [ $# -gt 0 ] && (/usr/local/bin/optional-parameter-exists "--skip-ssl" "$@" ||  /usr/local/bin/optional-parameter-exists "--no-ssl" "$@"); then
  cerr "SSL has been disabled by request"
elif test -e "$LE_WWW/.well-known/acme-challenge" && test -x "$CERTBOT"; then
  cerr "Certbot is available"
  USE_LE=1
  USE_SSL=1
  VHOST_CONF_STUB="-ssl"
fi

# Provide some feedback
if [ ${USE_LE} -eq 1 ]; then
  >&2 printf "LetsEncrypt Automatic SSL: %bEnabled%b    (use --skip-ssl to disable)\n" "${GREEN}" "${NC}"
else
  >&2 printf "LetsEncrypt Automatic SSL: %bDisabled%b\n" "${RED}" "${NC}"
fi

export USE_LE
export USE_SSL
export VHOST_CONF_STUB

#############################################################################
# Get configuration from an external file
#----------------------------------------------------------------------------

if [ $# -gt 0 ] && /usr/local/bin/optional-parameter-exists "--php-version" "$@"; then
  PHP_VERSION="$(/usr/local/bin/require-named-parameter "--php-version" "$@")"
fi

if [ -n "${PHP_VERSION:-}" ]; then
  if [ -e "${ACROCONFROOT}/add-website.conf${PHP_VERSION}" ]; then
    ACROCONF="${ACROCONFROOT}/add-website.conf${PHP_VERSION}"
  else
    ACROCONF="${ACROCONFROOT}/add-website.conf.phpdefault"
  fi
else
  if [ -e "${ACROCONFROOT}/add-website.conf" ]; then
    ACROCONF="${ACROCONFROOT}/add-website.conf"
  else
    ACROCONF="${ACROCONFROOT}/add-website.conf.phpdefault"
  fi
fi

test -e "${ACROCONF}" || {
  >&2 echo "${BOLD}ERR:${UNBOLD} Missing configuration file: '${ACROCONF}'"
  >&2 echo "If you are seeing this message (and you did not explictly specify a PHP version to use), it means the configuration for this script has not yet been linked."
  >&2 echo "To fix the problem, create a symlink to one of the master configs in the ${ACROCONFROOT} directory as 'add-website.conf':"
  >&2 echo "i.e:"
  >&2 echo "  cd ${ACROCONFROOT} && sudo ln -s 'add-website.conf.php7.2' 'add-website.conf'"
  >&2 echo "or"
  >&2 echo "  cd ${ACROCONFROOT} && sudo ln -s 'add-website.conf.php5' 'add-website.conf'"
  >&2 echo "or"
  >&2 echo "  cd ${ACROCONFROOT} && sudo ln -s 'add-website.conf.phpdefault' 'add-website.conf'"
  >&2 echo "or"
  >&2 echo "  cd ${ACROCONFROOT} && sudo ln -s 'add-website.conf.phpdnone' 'add-website.conf'"
  >&2 echo "If you DID specify a PHP version, it means the version you specified isn't supported or doesn't exist."
  exit 92
}
source "${ACROCONF}"

>&2 printf "HTTP daemon to use.......: %b%s%b\n" "${BLUE}" "${WEBSERVER}" "${NC}"
if [[ "$PHP_VERSION" == 'none' ]]; then
  >&2 printf "PHP FPM version to use...: %b%s%b\n" "${RED}" "${PHP_VERSION}" "${NC}        (specify a different version with: --php-version X.X)"
else
  >&2 printf "PHP FPM version to use...: %b%s%b\n" "${BLUE}" "${PHP_VERSION}" "${NC}        (specify a different version with: --php-version X.X)"
fi
>&2 printf "\n"

ACTIVITY_LOG="/var/log/acro-add-website.log"




#############################################################################
# Preapare for liftoff
#----------------------------------------------------------------------------
if touch "$ACTIVITY_LOG"; then
  chmod 0640 "$ACTIVITY_LOG"  # Log may contain sensitive info.
  chown root:adm  "$ACTIVITY_LOG" || true   # This is ideal ownership on ubuntu + red hat, but not critical since we took off world-read privileges.
else
  warn "ACTIVITY_LOG '$ACTIVITY_LOG' is not writeable. Sending log lines to /dev/null instead."
  ACTIVITY_LOG="/dev/null"
fi

{
  echo "#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#="
  echo "Starting at $(date "+%Y-%m-%d %H:%M:%S")"
  env | grep -v ^LS_COLORS
  echo "#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#=#="
} >> "$ACTIVITY_LOG"

# Pipefail traps any non-zero exit code from main, which would otherwise be lost because of the pipe through tee.
# Without the if statement, we can't record the exit code.
set -o pipefail
if main "$@" 2>&1 | tee -a "$ACTIVITY_LOG"; then
  MAIN_EXIT_CODE=0
else
  MAIN_EXIT_CODE="$?"
fi

{
  echo "------------------------------------------------------------------------------"
  echo "MAIN_EXIT_CODE: $MAIN_EXIT_CODE"
  echo ""
  echo ""
  echo ""
  echo ""
  echo ""
  echo ""
} >> "$ACTIVITY_LOG"
exit "$MAIN_EXIT_CODE"
