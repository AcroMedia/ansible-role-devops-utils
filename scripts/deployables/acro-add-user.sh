#!/bin/bash

set -eu
set -o pipefail

function main() {

  [ $# -lt 1 ] && {
    usage
    exit 0
  }

  sanity_checks_pass || return 1

  ACTIVITY_LOG=/var/log/acro/add-user.log
  mkdir -pv "$(dirname "$ACTIVITY_LOG")" || true     # if we cant write to the log, we cant make changes either, so dont worry about logging it.
  touch "$ACTIVITY_LOG" || ACTIVITY_LOG=/dev/null    # if we cant write to the log, we cant make changes either, so dont worry about logging it.
  {
    echo "-------------------------------------------------------"
    echo "$(basename "$0") Starting at $(date "+%Y-%m-%d %H:%M:%S")"
    env | grep -v ^LS_COLORS
  } >> "$ACTIVITY_LOG"



  # -----------------------------------------------
  # Set some defaults
  # -----------------------------------------------
  GRANT_WEBS=${GRANT_WEBS:-0}   # Add access to all of the web owner accounts if they exist. Accept from env if defined.
  GRANT_SECONDARIES=1   # Default behaviour is to add access to secondary accounts if they are specified.
  NOTIFY=0          # Email notification is disabled by default. You need to specify --notify if you want the user to get an emaily telling them about their account creation.
  DUMP_KEYS=0
  PUB_FILES=0        # Only used with --dump-keys ... prints all pub keys for a given user to individual .pub files instead of to stdout.
  SQUELCH_SUDO=0     # Default behaviour is to apply sudo according to the user map. Can be overridden by passing --no-sudo or --with-sudo
  VERBOSE=${VERBOSE:-0} # Verbose enables any messages that 'info()' wants to send to stderr. Also accept "VERBOSE=1" as an environment variable.
  DEBUG=${DEBUG:-0}     # --debug enables any message that 'debug()' wants to send to stderr. Also accept "DEBUG=1" as an environment variable.
  FROM_GITHUB=0      # Default behaviour is to use the built in user map. You can add a user using their key from github instead, but you also need to provide GITHUB_USER env variable, and tell the script whether or not you want them to hvae sudo access. Careful with the GITHUB_USER name you provide. There's no way to check for typos.
  GITHUB_USER=${GITHUB_USER:-} # Require from environment. Only applies when "--from-github" is used.
  WITH_SUDO=0         # Users are only added to the sudo group automatically when being created in bulk with the built in map. Otherwise you must provide the --with-sudo argument.
  FROM_GITLAB=0       # Let keys / users be created using keys from a gitlab server. Simpler than --from-github, since the username can be used as is and you dont have to specify the gitlab version.
  PROMPT_FOR_CONFIRMATION=1   # Only applies to --create-all. Passing -y turns this off.


  # -----------------------------------------------
  # Override wired defaults with local environment defaults. Command line switches can still override these.
  # -----------------------------------------------
  local LOCAL_CONF=/etc/acro/add-user.conf
  if [ -e "$LOCAL_CONF" ]; then
    if assert_mode 644 "$LOCAL_CONF"; then
      if assert_owner_group root root "$LOCAL_CONF"; then
        debug "Reading config from $LOCAL_CONF"
        # shellcheck disable=SC1091
        # shellcheck disable=SC1090
        source "$LOCAL_CONF"
      fi
    fi
  else
    warn "No local conf exists: $LOCAL_CONF"
  fi


  # -----------------------------------------------
  # Internal behaviour vars that are derived from command line switches
  # -----------------------------------------------
  DOALL=0
  UPDATEONLY=0
  WHICHUSER='UNDEFINED'  # Set this to something arbitrary and nonseniscal, just so we don't crap out on "undefined variable" errors


  # -----------------------------------------------
  # Handle some mutually exclusive options
  # -----------------------------------------------
  if optional_parameter_exists "--dump-keys" "$@"; then
    DOALL=1
    UPDATEONLY=1
    DUMP_KEYS=1
    if optional_parameter_exists "--pub-files" "$@"; then
      PUB_FILES=1
    fi
  elif optional_parameter_exists "--update-all" "$@"; then
    require_root
    DOALL=1
    UPDATEONLY=1
    DUMP_KEYS=0
  elif optional_parameter_exists "--create-all" "$@"; then
    require_root
    DOALL=1
    UPDATEONLY=0
    DUMP_KEYS=0
  fi

  # Handle options - deny all other options to prevent misspellings.
  local ARG
  for ARG in "$@"; do
    case "$ARG" in
      --dump-keys)  # flags for this were already handled above.
          shift
          continue
          ;;
      --pub-files)  # flags for this were already handled above.
          shift
          continue
          ;;
      --update-all)  # flags for this were already handled above.
          shift
          continue
          ;;
      --create-all)  # flags for this were already handled above.
          shift
          continue
          ;;
      -y)
          PROMPT_FOR_CONFIRMATION=0
          continue
          ;;
      --help)
          usage
          exit 0
          ;;
      --notify)
          NOTIFY=1
          shift
          continue
          ;;
      --no-mail)
          # Notifications are off by default, so this does nothing. We only leave the option
          # in the list so as not to break older scripts that haven't been updated.
          shift
          continue
          ;;
      --no-generics)
          # Only here for bckwards compatibility.
          GRANT_SECONDARIES=0
          shift
          continue ;;
      --no-secondaries)
          # Don't add user's ssh key to secondary accounts , even if user has secondary accounts specified.
          GRANT_SECONDARIES=0
          shift
          continue ;;
      --no-webs)
          # Override a default; Don't add keys to website accounts.
          GRANT_WEBS=0
          shift
          continue
          ;;
      --grant-webs)
          # Add the real user's keys to website accounts in addition to their own.
          GRANT_WEBS=1
          shift
          continue
          ;;
      --no-sudo)
          SQUELCH_SUDO=1
          shift
          continue
          ;;
      --with-sudo)
          WITH_SUDO=1
          shift
          continue
          ;;
      --verbose)
          VERBOSE=1
          shift
          continue
          ;;
      -v)
          VERBOSE=1
          shift
          continue
          ;;
      --debug)
          DEBUG=1
          shift
          continue
          ;;
      --from-github)
          FROM_GITHUB=1
          shift
          continue
          ;;
      --from-gitlab)
          FROM_GITLAB=1
          shift
          continue
          ;;
      -*)
          err "Unknown option: '$ARG'"
          return 1
          ;;
      *)
          # If the arg doesn't have any dashes, then we'll assume this is the user that we want to create or update.
          # Since we only create users that match a pre-defined pattern, it really doesn't matter what this argument looks like at this stage.
          # If more than one user is specified, only the last one will be acted on.
          # @TODO: Make it so we can specify a space separated list of users.
          WHICHUSER="${ARG}"
          DOALL=0   # Specifying a user causes the DOALL flag to be set back to 0 again.
          continue
          ;;
    esac
  done

  if [ $FROM_GITHUB -eq 1 ]; then
    if [ $NOTIFY -eq 1 ]; then
      warn "Ignoring '--notify' because of '--from-github', to prevent security issues caused by mis-typed or incorrect GITHUB_USER."
      NOTIFY=0
    fi
  fi

  if [ $NOTIFY -eq 1 ]; then
    warn_if_no_mail
  fi

  if [[ "$DOALL" -eq 1 ]] && [[ "$UPDATEONLY" -eq 0 ]]; then
    if [ $WITH_SUDO -eq 1 ]; then
      warn "Ignoring '--with-sudo'. Bulk creation must follow the predefined user map."
      WITH_SUDO=0
    fi
    if [ $PROMPT_FOR_CONFIRMATION -eq 1 ]; then
      cerr "#"
      cerr "# * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * "
      cerr "#  You are about to bulk-create user accounts and give SSH (and possibly sudo) access"
      cerr "#  to the users defined in the config file (unless you specified --no-sudo)."
      cerr "#  Assuming mail delivery is available on this system, individual users"
      cerr "#  can be notified of their new account with the --notify option."
      >&2 echo -n ">>>  Enter [y] to continue, or anything else to abort: "
      read -r DRAMATIC_PAUSE
      if [[ $DRAMATIC_PAUSE != 'y' ]]; then
        cerr "Aborting."
        return 1
      fi
    fi
  fi

  if [[ "$WHICHUSER" == "UNDEFINED" ]] || [ -z "$WHICHUSER" ]; then
    if [ "$DOALL" -eq 1 ]; then
      true # This is OK
    else
      err "Which user do you want to add?"
      return 1
    fi
  else
    info "User: $WHICHUSER"
    if [ $DUMP_KEYS -eq 1 ]; then
      true # not chang the system, no need for special privileges
    else
      require_root
    fi
  fi



  # User data arrays
  KEYOWNERS=()
  KEYTYPES=()
  KEYS=()
  KEYCOMMENTS=()
  EMAILS=()
  SUDOERS=()
  SECONDARY_GROUPS=()


  if [ $FROM_GITHUB -eq 1 ] || [ $FROM_GITLAB -eq 1 ]; then

    if [ $FROM_GITLAB -eq 1 ]; then
      if [ -z "${GITLAB_SERVER_URL:-}" ]; then
        err "No GITLAB_SERVER_URL found in config or provided by environment."
        return 1
      fi
    fi

    if ! type curl > /dev/null; then   # We need to be able to download keys
      err "No curl available. There's no way to download keys. Sorry."
      return 1
    fi
    if ! type ssh-keygen > /dev/null; then   # This is what we'll use to validate the well-formed-ness of the keys we download
      err "No ssh-keygen available. There's no way to verify the well-formed-ness of downloaded keys. Sorry."
      return 1
    fi
    EXTERNAL_KEYS_FILE=$(mktemp)
    if [ $FROM_GITHUB -eq 1 ] && [ -z "$GITHUB_USER" ]; then
      # @TODO ... get this from command line
      err "No GITHUB_USER environment variable found."
      return 1
    fi
    if [ $FROM_GITHUB -eq 1 ]; then
      EXTERNAL_KEYS_URL="https://github.com/${GITHUB_USER}.keys"
    elif [ $FROM_GITLAB -eq 1 ]; then
      EXTERNAL_KEYS_URL="${GITLAB_SERVER_URL}/${WHICHUSER}.keys"    # We assume the gitlab user name is the same as the username you want to create here.
    else
      err "Missing value for EXTERNAL_KEYS_URL"
      return 1
    fi
    debug "EXTERNAL_KEYS_URL: $EXTERNAL_KEYS_URL"
    debug "EXTERNAL_KEYS_FILE: $EXTERNAL_KEYS_FILE"

    if ! (curl -sSL --fail "$EXTERNAL_KEYS_URL" | grep '^ssh' > "$EXTERNAL_KEYS_FILE"); then
      err "Curl command failed: 'curl -sSL --fail $EXTERNAL_KEYS_URL'"
      cerr "Result:"
      >&2 cat "$EXTERNAL_KEYS_FILE"
      return 1
    fi
    debug "EXTERNAL_KEYS_FILE content: $(cat "$EXTERNAL_KEYS_FILE")"

    EXTERNAL_VALID_KEY_COUNT=0
    while read -r KEYLINE || [[ -n "$KEYLINE" ]]; do   # Lines not terminated with '\n' are skipped. Need to also  check for a non-empty string.
      KEYLINEFILE=$(mktemp)
      debug "KEYLINEFILE: $KEYLINEFILE"
      debug "KEYLINE: $KEYLINE"
      echo "$KEYLINE" > "$KEYLINEFILE"
      echo "$KEYLINE" >> "$ACTIVITY_LOG"
      if ssh-keygen -l -f "$KEYLINEFILE"; then    # Easy way to validate the well-formed-ness of the public key
        EXTERNAL_VALID_KEY_COUNT=$((EXTERNAL_VALID_KEY_COUNT+1))

        # Dynamically add a user to the defined list
        KEYOWNERS+=("$WHICHUSER")
        KEYTYPES+=("$(echo "$KEYLINE"|awk '{print $1}')")
        KEYS+=("$(echo "$KEYLINE"|awk '{print $2}')")
        KEYCOMMENTS+=("$(date +%Y-%m-%d)")
        EMAILS+=("${WHICHUSER}")    # Purposely leaving off the domain since (1) there isnt one, and (2) we don't want to send out any email when creating a user by an external key, and (3) its possible to deliver mail to a local user even if something does happen to go out.
        if [ $WITH_SUDO -eq 1 ]; then
          SUDOERS+=(1)
        else
          SUDOERS+=(0)
        fi
        SECONDARY_GROUPS+=('')

      else
        debug "ssh-keygen command failed: ssh-keygen -l -f $KEYLINEFILE"
      fi
    done < "$EXTERNAL_KEYS_FILE"
    if [ $EXTERNAL_VALID_KEY_COUNT -eq 0 ]; then
      err "No valid keys were found for the external user you specified."
      return 1
    fi
  fi

  # Read in user + pubkey data
  local LOCAL_USER_KEYS_LIST=/etc/acro/add-user.data
  if [ -e "$LOCAL_USER_KEYS_LIST" ]; then
    if assert_mode 644 "$LOCAL_USER_KEYS_LIST"; then
      if assert_owner_group root root "$LOCAL_USER_KEYS_LIST"; then
        debug "Reading list of users and pubkeys from $LOCAL_USER_KEYS_LIST"
        # shellcheck disable=SC1091
        # shellcheck disable=SC1090
        source "$LOCAL_USER_KEYS_LIST"
      fi
    fi
  else
    warn "No local user map exists at ${LOCAL_USER_KEYS_LIST}."
  fi


  # Here we go.
  LOOP=0
  ACTEDON=0
  KEYS_DUMPED=0
  LAST_KEY_OWNER=""

  arraylength=${#KEYS[@]}   # aka count. base 1.
  for (( LOOP=0; LOOP < arraylength; LOOP++ )); do
    KEYOWNER="${KEYOWNERS[$LOOP]}"
    debug "$LOOP $KEYOWNER"
    KEYTYPE="${KEYTYPES[$LOOP]}"
    PUBKEY="${KEYS[$LOOP]}"
    KEYCOMMENT="${KEYCOMMENTS[$LOOP]}"
    EMAIL="${EMAILS[$LOOP]}"
    SECONDARIES="${SECONDARY_GROUPS[$LOOP]}"



    NEW_AUTH_LINE="$KEYTYPE $PUBKEY $EMAIL $KEYCOMMENT"
    THISHOST=$(hostname --long)
    if [ $SQUELCH_SUDO -eq 1 ]; then
      SUDOER=0  # Requested from command line
    elif [ $WITH_SUDO -eq 1 ]; then
      SUDOER=1  # Requested from command line
    else
      # Just use whatever value is configured for the user.
      SUDOER="${SUDOERS[$LOOP]}"
    fi

    MAIL_BODY=""
    MAIL_SUBJECT=""
    CREATED_PASSWORD=0

    # These next values can be bunk for now if no user exists, but if a user is created, they will need to get reset with real values.
    # shellcheck disable=SC2088
    HOMEDIR=$(eval echo "~$KEYOWNER") # if the user exists, this will return "/home/foo" or similar. If not, it will return "~foo". We're only using this if the user exists, so it doesn't matter either way. Tilde not expanding in quotes is the desired behavior in this circumstance.
    SSHDIR="$HOMEDIR/.ssh"
    AUTHFILE="$SSHDIR/authorized_keys"

    if [[ "$KEYOWNER" == "$WHICHUSER" ]] || [[ $DOALL -eq 1 ]]; then

      if [ "$DUMP_KEYS" -eq 1 ]; then
        if [ $PUB_FILES -eq 1 ]; then
          TEE_DEST="./${KEYOWNER}.pub"
        else
          TEE_DEST=/dev/null
        fi
        if [[ "$LAST_KEY_OWNER" != "$KEYOWNER" ]]; then
          echo ""
          echo "# $KEYOWNER"
        fi
        LAST_KEY_OWNER="$KEYOWNER"
        echo "$NEW_AUTH_LINE" | tee -a "${TEE_DEST}"
        KEYS_DUMPED=$((KEYS_DUMPED+1))
        continue
      fi

      # When not just updating keys, either create the user account, or make sure the user exists.
      info "Checking user $KEYOWNER..."
      if id -u "$KEYOWNER" >/dev/null 2>&1; then
        debug "User already exists."
        info "  OK"
        # Double check that home dir exists. It may not necessarily be there.
        if [ ! -d "$HOMEDIR" ]; then
          # Create home dir and skeleton files.
          info "  Creating $KEYOWNER's home dir"
          if type mkhomedir_helper >/dev/null 2>&1; then
            # Canonical way to create home dir structure
            (set -x && mkhomedir_helper "$KEYOWNER")
          else
            # Need to create it ourselves.
            (set -x && mkdir -p "$HOMEDIR")
            if [ -d "/etc/skel" ]; then
              (set -x && cp -r /etc/skel/. "$HOMEDIR")
              chown -R "$KEYOWNER": "$HOMEDIR"
            fi
          fi
        fi
      else
        if [[ "$UPDATEONLY" -eq 1 ]]; then
          info "  Skipping add user. This is update-only mode."
        else
          # Need to create the user.
          info "  Adding user $KEYOWNER"
          (set -x && useradd -m "$KEYOWNER")
          chsh -s /bin/bash "$KEYOWNER"

          # sudoers only need a password if their group isn't a NOP
          if [ "$SUDOER" -eq 1 ]; then
            if can_probably_sudo_without_password "$KEYOWNER"; then
              info "  Skipping password creation for $KEYOWNER;  It looks like they can sudo without one. This should be verified."
            else
              info "  Creating expired password for $KEYOWNER."
              # @TODO: I'm told that (1) generating random passwords is dangerous, and
              # (2) using passwd programmatically is a terrible thing to do. It's probably less of an issue since
              # we are expiring the password immediately, but still, find a way to not have to do this.
              # shellcheck disable=SC2002
              RAND=$(cat /dev/urandom | tr -dc "a-zA-Z0-9" | fold -w 20 | head -n 1);  # Use of cat here serves readability purposes.
              echo -e "$RAND\n$RAND" | passwd "$KEYOWNER"
              (set -x && chage -d 0 "$KEYOWNER")
              CREATED_PASSWORD=1
            fi
          fi

          if [ "$SUDOER" -eq 1 ]; then
            if [ $CREATED_PASSWORD -eq 1 ]; then
              MAIL_BODY="A new user account '$KEYOWNER' has been created for you at ${THISHOST}. SSH access has been enabled using your public key.\n\nYour account has sudo privileges, and a password will be required to perform sudo actions.\n\nA temporary password of '$RAND' has been assigned to your account. You will be prompted to change it when you first log in."
            else
              MAIL_BODY="A new user account '$KEYOWNER' has been created for you at ${THISHOST}. SSH access has been enabled using your public key. If you can't perform sudo actions without a password, contact an administrator to set one for you."
            fi
            MAIL_SUBJECT="new SSH account for you at $(hostname)"
          else
            MAIL_BODY="A new user account '$KEYOWNER' has been created for you at ${THISHOST}. SSH access has been enabled using your public key."
            MAIL_SUBJECT="new SSH account for you at $(hostname)"
          fi
          # Need to re-set these, since up until now there was no valid location. the rest of the script will need good values to work.
          # shellcheck disable=SC2088
          HOMEDIR=$(eval echo "~$KEYOWNER") # Tilde ~ not expanding in quotes is the desired behavior in this circumstance.
          SSHDIR="$HOMEDIR/.ssh"
          AUTHFILE="$SSHDIR/authorized_keys"
        fi
      fi

      ## Ensure correct mode and ownership on home dir. Some defaults allow world read or execute.
      ## On our servers, there's no need for anyone to access contents of a real user's dir except that user.
      ## Only do this if the home dir is in the standard location.
      debug "HOMEDIR: $HOMEDIR"
      if [ -d "$HOMEDIR" ] && [[ "$HOMEDIR" == "/home/${KEYOWNER}" ]]; then
        if ! assert_mode 700 "$HOMEDIR"; then
          (set -x && chmod 700 "$HOMEDIR")
        fi
        if ! assert_owner_group "$KEYOWNER" "$KEYOWNER" "/home/${KEYOWNER}"; then
          (set -x && chown "$KEYOWNER": "$HOMEDIR")
        fi
      fi


      # Make sure the SSH dir exists, but only if the user's home dir exists.
      # This works for both update and create mode, since we've ensured the user's home
      # dir exists in the 'create user' step.
      if [ -d "$HOMEDIR" ]; then
        if [ ! -d "$SSHDIR" ]; then
          # need to create the dir.
          info "  Creating $SSHDIR"
          (set -x && mkdir "$SSHDIR")
        fi
        # ensure correct permissions
        if [ "$HOMEDIR" == "/home/$KEYOWNER" ]; then
          # ... but only if users home dir is standard location
          chown "$KEYOWNER": "$SSHDIR"
          chmod 700 "$SSHDIR"
        else
          warn "$KEYOWNER's SSH dir is set to $SSHDIR. Ownership & permissions have been ignored. User may not be able to log in with public keys."
        fi
      fi

      # Same scenario as SSH dir. Only deal with the keys if the user's home dir exists.
      if [ -d "$HOMEDIR" ]; then
        info "  Checking authorized keys..."
        if [ -f "$AUTHFILE" ]; then
          if grep -q "$PUBKEY" "$AUTHFILE"; then
            info "    OK"
          else
            info "    adding key"
            {
              echo ""
              echo "$NEW_AUTH_LINE"
              echo ""
            } >> "$AUTHFILE"
            cerr "+ echo \"${KEYTYPE}... ...${EMAIL}\" >> $AUTHFILE"
          fi
        else
          info "    creating auth file and adding key"
          {
            echo "$NEW_AUTH_LINE" >> "$AUTHFILE"
            echo ""
          } >> "$AUTHFILE"
          cerr "+ echo \"${KEYTYPE}... ...${EMAIL}\" >> $AUTHFILE"
        fi
        # ensure correct permissions
        if [ "$HOMEDIR" == "/home/$KEYOWNER" ]; then
          # ... but only if users home dir is standard location
          chown "$KEYOWNER": "$AUTHFILE"
          chmod 600 "$AUTHFILE"
        else
          warn "$KEYOWNER's Auth file is set to $AUTHFILE. Ownership & permissions have been ignored. User may not be able to log in with public keys."
        fi
      fi

      # Only add users to groups if the user's home dir exists.
      # This will affect existing users in update mode, and all specified users in create mode
      if [ -d "$HOMEDIR" ]; then
        info "  Checking if user is in admin group(s)..."
        if [ "$SUDOER" -eq 1 ]; then
          add_user_to_group "$KEYOWNER" wheel    # sudo privileges for redhat/centos
          add_user_to_group "$KEYOWNER" sudo     # sudo privileges for ubuntu 12 and newer
          add_user_to_group "$KEYOWNER" admin    # sudo privileges for ubuntu 11 and lower
          add_user_to_group "$KEYOWNER" adm      # view sensitive log files on ubuntu
        fi
        # allow the user to log in remotely.
        add_user_to_group "$KEYOWNER" ssh
        if [[ "$(hostname -s)" == "git" ]]; then
          add_user_to_group "$KEYOWNER" git
        fi

        for GROUP2 in $SECONDARIES; do
          add_user_to_group "$KEYOWNER" "$GROUP2"
        done
      fi

      if [ $GRANT_SECONDARIES -eq 1 ]; then
        for SECONDARY in $SECONDARIES; do
          # Also add the user's key to the specified secondary accounts.
          if [ -f "/home/${SECONDARY}/.ssh/authorized_keys" ]; then
            if [[ "$KEYOWNER" != "$SECONDARY" ]]; then
              info "  Checking access to $SECONDARY account..."
              if grep -q "$PUBKEY" "/home/${SECONDARY}/.ssh/authorized_keys"; then
                info "    User can already log in."
              else
                info "    Adding key."
                {
                  echo ""
                  echo "# $KEYOWNER"
                  echo "$NEW_AUTH_LINE"
                  echo ""
                } >> "/home/${SECONDARY}/.ssh/authorized_keys"
                cerr "+ ${KEYTYPE}... ...${EMAIL} >> /home/${SECONDARY}/.ssh/authorized_keys"
              fi
            fi
          fi
        done
      fi


      if [ "$GRANT_WEBS" -eq 1 ]; then
        # Add user to existing web accounts, whether in "add" or "update" mode.
        add_pubkey_key_to_all_web_accounts "$KEYOWNER" "$PUBKEY" "$NEW_AUTH_LINE"
      fi

      if [ $NOTIFY -eq 1 ]; then
        if [ -n "$MAIL_BODY" ] && [ -n "$MAIL_SUBJECT" ]; then
          if mail_client_exists; then
            info "  Notifying new user of their account via email: $EMAIL"
            echo -e "$MAIL_BODY" | (set -x && mail -s "$MAIL_SUBJECT" "$EMAIL")
            echo -e "$MAIL_BODY" | mail -s "$MAIL_SUBJECT (copy)" root
          else
            echo "# ==============================================================================="
            echo "# Mail is not available. Please deliver the following new user details to $EMAIL:"
            echo -e "$MAIL_BODY"
            echo "# -------------------------------------------------------------------------------"
          fi
        fi
      else
        if [ $CREATED_PASSWORD -eq 1 ] && [ -n "$MAIL_BODY" ]; then
          echo "# ==============================================================================="
          echo "# Email notification was not specified, but the new user will require their temporary"
          echo "# password to log in to the system. Please deliver the following new user details to $EMAIL:"
          echo -e "$MAIL_BODY"
          echo "# -------------------------------------------------------------------------------"
        fi
      fi

      # Append the new user to the "AllowUsers" line (if it exists; but don't actually restart SSHD).
      # Only perform this check if the user's home directory exists.
      if [ -d "$HOMEDIR" ]; then
        SSHDCONF="/etc/ssh/sshd_config"
        if [ -f "$SSHDCONF" ]; then
          # Not really sure why we built this in a loop ... expecting to see more than one instance of AllowUsers perhaps?
          IFS=$'\n' # This causes the next line to split the output of grep in to an array based on newlines instead of on whitespace
          # shellcheck disable=SC2207
          AllowUsersLines=( $(grep -i "^AllowUsers" "$SSHDCONF" | grep -v " $KEYOWNER") )
          AllowUsersResult=$?
          if [ "$AllowUsersResult" -eq 0 ]; then
            for LINE in "${AllowUsersLines[@]}"
            do
              cerr ""
              cerr "#  ***********************************************************"
              cerr "#  *** Updating $SSHDCONF:"
              cerr "#  ***   Old AllowUsers line:"
              cerr "#  ***     $LINE"
              BAKSTRING=".$(date +%s%N)~"
              sed -i"$BAKSTRING" "/^AllowUsers / s/\$/ $KEYOWNER/" "$SSHDCONF"
              cerr "#  ***   New AllowUsers line:"
              cerr "#  ***     $(grep -i "^AllowUsers" "$SSHDCONF" | grep " $KEYOWNER")"
              cerr "#  ***"
              cerr "#  *** The ssh(d) service will need to be restarted before the new user will be able to log in."
              cerr "#  ***"
              cerr ""
            done
          fi
        else
          warn "File $SSHDCONF not found. I am unable to check if $KEYOWNER is in the 'AllowUser' list."
        fi
      fi

      ACTEDON=$((ACTEDON + 1))

      info ""
    fi

  done

  if [ $ACTEDON -gt 0 ] || [ $KEYS_DUMPED -gt 0 ]; then
    cerr "✔"
  else
    cerr "❌ Check your arguments and try again. The user you specified is not configured, or you specified an invalid option."
    help_hint
  fi

}


function optional_parameter_exists () {
  if [[ $# -lt 1 ]]; then
    err "Nevermind the haystack, I didn't even get the needle. Whoever called me did it the wrong way."
    exit 1
  fi
  if [[ $# -lt 2 ]]; then
    warn "optional_parameter_exists: I received no haystack to look through."
  fi
  local PARAM_NAME_PATTERN=${1}; shift
  while [[ $# -gt 0 ]]; do
    local KEY=$1
    case $KEY in
      "${PARAM_NAME_PATTERN}")
        return 0; # Needle was found.
        ;;
      *)
        true # Unknown / ignored option. Keep looping.
        ;;
    esac
    shift || break
  done
  return 1 # Needle not found
}


function err() {
  cerr "ERROR: $*"
}

function warn () {
  cerr "WARN: $*"
}

function cerr() {
  >&2 echo "$@"
}

function require_root () {
  if ! is_root; then
    cerr "ERR: You need to run this script as root."
    exit 1
  fi
}

function is_root() {
  if [ $EUID -eq 0 ]; then
    true
  else
    false
  fi
}

function warn_if_no_mail () {
  if ! mail_client_exists; then
    warn "The 'mail' command is not available. Any login details generated will be sent to stderr. Install the 'mailutils' (debian) or 'mailx' (rhel) package to be able to send login details to users."
  fi
}

function mail_client_exists () {
  if type mail >/dev/null 2>&1 ;then
    true
  else
    false
  fi
}


function sanity_checks_pass() {
  type useradd >/dev/null 2>&1 || {
    cerr "The 'useradd' command was not found. Hint: Use 'sudo -i <script>' or 'sudo su -' to gain root's PATH."
    return 1
  }
  if ! type chsh > /dev/null; then
    err "The command chsh was not found in PATH. On Ubuntu (all versions) and RedHat 6/7, chsh is usually present by default. On Amazon Linux, RedHat/CentOS 8 you need to install the 'util-linux-user' package first."
    return 1
  fi
}


# This is more of an educated guess than a hard science
function can_probably_sudo_without_password () {
  local WHICHUSER="$1"
  if grep -r "^%wheel\b\|^%sudo\b\|^%adm\b\|^$WHICHUSER\b" /etc/sudoers /etc/sudoers.d/ |grep -q NOPASSWD; then
    true
  else
    false
  fi
}


##
# Adds user to the specified group if the group exists,
# and if the user is not already in the group.
function add_user_to_group () {
  local PUSER="$1"
  local PGROUP="$2"
  getent group "$PGROUP" > /dev/null 2>&1
  local STATUS1=$?
  if [ $STATUS1 -eq 0 ]; then
    groups "$PUSER"|grep "\b$PGROUP\b"  > /dev/null 2>&1
    local STATUS2=$?
    if [ $STATUS2 -eq 0 ]; then
      info "    OK ($PGROUP)"
    else
      info "    adding to $PGROUP"
      (set -x && usermod -a -G "$PGROUP" "$PUSER")
    fi
  fi
}

function add_pubkey_key_to_all_web_accounts () {
  local OWNER="$1"
  local BARE_KEY="$2"
  local NEW_AUTH_LINE="$3"

  find . -maxdepth 1 -name 'foo' -printf 0 > /dev/null || {
    err "Find doesn't seem to support the '-printf' option. I cannot add the user to web account authorized_keys files."
    return 1
  }
  info "  Giving ${OWNER} access to existing web accounts..."
  local REAL_USER_LINES
  if [ -e /etc/redhat-release ] || [ -e /etc/redhat-release ]; then
    # Red hat users IDs start at 500
    REAL_USER_LINES=$(awk -F':' '{if($3 >= 500 && $3 < 10000) print}' /etc/passwd)
  else
    # Debian user IDs start at 1000
    REAL_USER_LINES=$(awk -F':' '{if($3 >= 1000 && $3 < 10000) print}' /etc/passwd)
  fi
  local WEB_ACCOUNT_LINES="$REAL_USER_LINES"
  local USERNAME
  for USERNAME in "${KEYOWNERS[@]}"; do
    WEB_ACCOUNT_LINES="$(echo "$WEB_ACCOUNT_LINES" | grep -v -w "$USERNAME")" # filter out configured users.
  done
  local WEBACCOUNT_HOME_DIRS
  WEBACCOUNT_HOME_DIRS="$(echo "$WEB_ACCOUNT_LINES" |  cut -d":" -f6 |sort -u)"
  local HOMEDIR
  for HOMEDIR in $WEBACCOUNT_HOME_DIRS; do
    if [ ! -d "$HOMEDIR" ]; then
      info "Skipping $HOMEDIR because it isn't a directory."
      continue
    fi
    local STATCODE
    STATCODE="$(stat -c %a "$HOMEDIR")"
    if [[ "$STATCODE" == *"700" ]]; then
      info "Skipping $HOMEDIR because of mode 700; probably a real person's home dir, and not a web account."
      continue
    fi
    if [[ ! "$STATCODE" == *"755" ]] && [[ ! "$STATCODE" == *"751" ]]; then
      warn "add_pubkey_key_to_all_web_accounts(), Ignoring dir '$HOMEDIR' because of unhandled mode '$STATCODE'"
      continue
    fi
    local AUTHORIZED_KEYS="$HOMEDIR/.ssh/authorized_keys"
    if  [ ! -f "$AUTHORIZED_KEYS" ]; then
      info "Skipping $HOMEDIR because it has no authorized_keys file."
      continue
    fi
    local WWWDIR="$HOMEDIR/www"
    if [ ! -d "$WWWDIR" ]; then
      info "Skipping $HOMEDIR because it has no www dir in it."
      continue
    fi
    local WEB_FILE_COUNT
    WEB_FILE_COUNT="$(find -L "$HOMEDIR/www"  -maxdepth 5 -type f \( -name '*.php' -o -name '*.htm' -o -name '*.html' \) -printf '.' -quit | wc -c)"
    if ! is_positive_integer "$WEB_FILE_COUNT"; then
      info "Skipping $HOMEDIR because WEB_FILE_COUNT was not a positive integer: $WEB_FILE_COUNT"
      continue
    fi
    if [ "$WEB_FILE_COUNT" -eq 0 ]; then
      info "Skipping $HOMEDIR because WEB_FILE_COUNT was zero: $WEB_FILE_COUNT"
      continue
    fi
    if grep -q "$BARE_KEY" "$AUTHORIZED_KEYS"; then
      info "Not adding ${OWNER}'s pubkey to $AUTHORIZED_KEYS because it already exists."
      continue
    fi
    {
      echo ""
      echo "# $OWNER"
      echo "$NEW_AUTH_LINE"
      echo ""
    } >> "$AUTHORIZED_KEYS"
    cerr "+ ${KEYTYPE}... ...${EMAIL} >> $AUTHORIZED_KEYS"
  done

}

function is_positive_integer() {
  local WHAT="$*"
  if [[ "$WHAT" =~ ^[0-9]+$ ]]; then
    true
  else
    false
  fi
}

function info () {
  if [ "$VERBOSE" -ne 1 ]; then
    return
  fi
  cerr "$*"
}


function debug () {
  if [ "$DEBUG" -ne 1 ]; then
    return
  fi
  cerr "$*"
}

function assert_mode () {
  local DESIRED_MODE="$1"
  local PATH_TO_CHECK="$2"
  debug "assert_mode() PATH_TO_CHECK: $PATH_TO_CHECK"
  if [ ! -e "$PATH_TO_CHECK" ]; then
    err "assert_mode() path not found or not readable: $PATH_TO_CHECK"
    return 1
  fi
  local STATCODE
  STATCODE="$(stat -c %a "${PATH_TO_CHECK}")" || {
    err "assert_mode() Could not determine mode of $PATH_TO_CHECK"
    return 1
  }
  if [[ "${STATCODE}" != "${DESIRED_MODE}" ]]; then
    info "Test for ${STATCODE} mode on $PATH_TO_CHECK failed."
    return 1
  fi
  # if we get to this line, no news is good news.
}

function assert_owner_group () {
  local DESIRED_OWNER="$1"
  local DESIRED_GROUP="$2"
  local PATH_TO_CHECK="$3"
  local OWNER_GROUP
  debug "assert_owner_group PATH_TO_CHECK: $PATH_TO_CHECK"
  if [ ! -e "$PATH_TO_CHECK" ]; then
    err "assert_owner_group() path not found or not readable: $PATH_TO_CHECK"
    return 1
  fi
  OWNER_GROUP=$(find "$(dirname "$PATH_TO_CHECK")" -mindepth 1 -maxdepth 1 -name "$(basename "$PATH_TO_CHECK")" -printf '%u %g\n') || {
    err "Could not determine permissions of $PATH_TO_CHECK"
    return 1
  }
  debug "OWNER_GROUP: $OWNER_GROUP"
  if [[ "$OWNER_GROUP" != "${DESIRED_OWNER} ${DESIRED_GROUP}" ]]; then
    info "Test for ${DESIRED_OWNER}:${DESIRED_GROUP} ownership on $PATH_TO_CHECK failed."
    return 1
  fi
  # if we get to this line, no news is good news.
}

function usage () {
  cerr "  This script creates user accounts for privileged users and sets up each user's public "
  cerr "  key for SSH access to the account(s). Users can be notifed of account creation "
  cerr "  if you pass the --notify option on the command line."
  cerr ""
  cerr "  The script supports pre-defined lists of usernames and public keys via include, so "
  cerr "  all you normally need to do is provide the name of the user you want to create."
  cerr ""
  cerr "  You may also create an arbitrary account that hasn't been defined in the include."
  cerr ""
  cerr "  If you prefix the script with the GITHUB_USER=xxxx environment variable, and add "
  cerr "  add --from-github switch, the script will fetch GITHUB_USER's published SSH keys"
  cerr "  from to apply it to the account."
  cerr ""
  cerr "  If tell the script where your private gitlab server is, you can do the same "
  cerr "  thing with the --from-gitlab switch."
  cerr "  "
  cerr "  If you specify a user whos account already exists, the users's home directory, "
  cerr "  ssh keys, and permissions are updated to ensure security and usability."
  cerr ""
  cerr "  Usage: $(basename "$0") <username> [options]   # set up a single user"
  cerr "     or: GITLAB_SERVER_URL='https://private.server.com' $(basename "$0") --from-gitlab <username> [options]   # set up a single user not defined in the built in map, usking keys from GITLAB_SERVER_URL"
  cerr "     or: $(basename "$0") --update-all [options] # update keys and groups for existing users"
  cerr "     or: $(basename "$0") --create-all [options] # set up all users at once - only recommended for new servers"
  cerr "     or: GITHUB_USER=foobar $(basename "$0") --from-github <username-not-defined-in-file> [options] # Create a user that has not yet been defined"
  cerr ""
  cerr "  Options:"
  cerr "    --notify:     Send an email message to new user(s) upon account creation"
  cerr "    --no-sudo:    Override the user map, omitting the specified user from administrative groups"
  cerr "    --with-sudo:  Override the user map, adding the specified user to administrative groups"
  cerr "    --verbose:    Show more info about what's happening."
  cerr "    --debug:    Show even more info about what's happening."
  cerr "    --dump-keys:  Output everyone's public key to stdout. Pipe through grep if you only want a certain user."
  cerr "    --pub-files:  When dumping keys, also create individual .pub files with each user's keys (one file per user)."
  cerr "                  Make sure to redirect output to /dev/null if you dont want everyone's pubkey on your screen."
}

function help_hint () {
  cerr "Pass --help to see usage."
}

main "$@" || {
  >&2 echo -n "❌ "
  help_hint
  exit 1
}
