#!/bin/bash -e
# vim: st=2 sts=2 sw=2 et ai

POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    -w|--work-dir|--workdir)
      WORK="$2"
      shift
      shift
      ;;
    -d|--destination|--dest)
      FINAL="$2"
      shift
      shift
      ;;
    -u|--user|--remote-user)
      REMOTE_USER="$2"
      shift
      shift
      ;;
    -t|--target|--host)
      REMOTE_HOST="$2"
      shift
      shift
      ;;
    -h|--help)
      HELP=1
      shift
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
  esac
done

set -- "${POSITIONAL_ARGS[@]}"

# Ensure required arguments are specified
if [[ -z $WORK ]] || [[ -z $FINAL ]] || [[ -z $REMOTE_USER ]] || [[ -z $REMOTE_HOST ]]; then
  HELP=1
fi

latest=
R=$(tput setaf 1 2> /dev/null || echo "")
G=$(tput setaf 2 2> /dev/null || echo "")
H=$(tput setaf 6 2> /dev/null || echo "")
Y=$(tput setaf 3 2> /dev/null || echo "")
B=$(tput bold || echo "")
CL=$(tput sgr0 || echo "")
HCID="1505d3ba-1183-4de1-8f7e-c3ea6ecba4c6"
#KEYFILE=/root/.ssh/id_rsa

messages=""

Debug() {
  printf "$(date +%Y-%m-%d\ %H:%M:%S) ${H}${B}[ INFO ]${CL} - $1\n" $*
  messages="${messages}$(date +%Y-%m-%d\ %H:%M:%S) INFO: $*"$'\n'
}
Fail() {
  printf "$(date +%Y-%m-%d\ %H:%M:%S) ${R}${B}[ FAIL ]${CL} - $1\n" $*
  messages="${messages}$(date +%Y-%m-%d\ %H:%M:%S) FAIL: $*"$'\n'
}
Warn() {
  printf "$(date +%Y-%m-%d\ %H:%M:%S) ${Y}${B}[ WARN ]${CL} - $1\n" $*
  messages="${messages}$(date +%Y-%m-%d\ %H:%M:%S) WARN: $*"$'\n'
}
Done() {
  printf "$(date +%Y-%m-%d\ %H:%M:%S) ${G}${B}[ DONE ]${CL} - $1\n" $*
  messages="${messages}$(date +%Y-%m-%d\ %H:%M:%S) DONE: $*"$'\n'
}

do_clone() {
  # Try to rsync
  Debug "Cloning down: ${1##*/}"
  rsync \
    -vaHAXxr \
    --numeric-ids \
    --delete \
    --progress \
    --stats \
    --rsync-path="sudo rsync" \
    --whole-file \
    --exclude +gitaly \
    ${REMOTE_USER}@${REMOTE_HOST}:${1} ${2};

    #-e "ssh -i $KEYFILE -T -o Compression=no -x" \

  RESULT=$?

  # Check the results
  if [ $RESULT -eq 30 ]; then
    Fail "rsync failed, got result: $RESULT"
    if [ $1 -le 5 ]; then
      Warn "retrying... attempt $1/5";
      do_backup $(($1+1));
    else
      Warn "failed... attempt $1/5";
    fi
    return 1
  elif [ $RESULT -ne 0 ]; then
    Debug "rsync failed, got result: $RESULT"
    Fail "unhanlded error, exiting..."
    return $RESULT
  fi
  Done "Completed clone of: ${B}${G}${1##*/}${CL}"
}

do_archive() {
  Debug "Archiving: $1"
  tar  -C $1 -cf $2 .
  Done "Created: $2"
}

db_backup() {
  # Try to rsync
  Debug "Pulling latest database backups"
  rsync \
    -aHAXxr \
    --numeric-ids \
    --rsync-path="sudo rsync" \
    --remove-source-files \
    --whole-file \
    --include '*.tar' \
    --exclude '*' \
    ${REMOTE_USER}@${REMOTE_HOST}:/var/opt/gitlab/backups/ \
    $WORK/db/;

    #-e "ssh -i $KEYFILE -T -o Compression=no -x" \
  RESULT=$?

  # Check the results
  if [ $RESULT -eq 30 ]; then
    Fail "rsync failed, got result: %d" "$RESULT"
    if [ $1 -le 5 ]; then
      Warn "retrying... attempt $1/5";
      do_backup $(($1+1));
    else
      Warn "failed... attempt $1/5";
    fi
    return 1
  elif [ $RESULT -ne 0 ]; then
    Fail "rsync failed, got result: %d" "$RESULT"
    Fail "unhandled error, exiting..."
    return $RESULT
  fi

  # With the file cloned, find latest and re-archive
  latest=$(basename $(ls -t $WORK/db/*.tar | cat | head -n1))
  Debug "Found latest as ${B}${H}${latest}${CL}"
  Debug "Extracting database backup to $WORK/intake/"
  tar xf $WORK/db/$latest -C $WORK/intake/
  Done "Finished preparing database backup"
}

pack_backup() {
  local result=
  Debug "Packing backup to $FINAL/$1"

  tar cf $FINAL/$1 -C $WORK/intake .
  result=$?
  if [ $result -ne 0 ]; then
    Fail "Failed packaging backup, got RC: $result";
    return 1;
  fi

  Done "Packed backup to $FINAL/$1"
}

raise() {
  echo "BACKUP FAILED at $1"
  echo $messages
  exit 1
}


main() {
  if ! [[ -z $HELP ]] && [[ $HELP -eq 1 ]]; then
    echo "$0 - GitLab Remote Backup

Utilizes rsync and persistent work directories to synchronize content to the
local filesystem, then packs and archives everything to a gitlab-compatible
format.

Args:
  --work-dir | -w
    Specify the persistent working directory. This should be hot, fast storage.
  
  --destination | -d
    Specify the directory for the final output archive. This should be cold,
    archival storage.

  --user | -u
    Specify the remote SSH user for rsync to use for connection. Authentication
    will rely on you having an active SSH Agent with the private key loaded.
  
  --target | -t
    Specify the remote SSH Server running your gitlab instance.
"
    exit 0
  fi

  # STage our directory structure
  mkdir -p $WORK/{intake,artifacts,uploads,builds,lfs,pages}

  if [ -z $1 ] || [[ $1 == "repositories" ]]; then
    do_clone /srv/gitlab/git-data/repositories           $WORK/intake     || raise "Clone: Repos"
  fi
  if [ -z $1 ] || [[ $1 == "uploads" ]]; then
    do_clone /var/opt/gitlab/gitlab-rails/uploads        $WORK/uploads    || raise "Clone: Uploads"
  fi
  if [ -z $1 ] || [[ $1 == "builds" ]]; then
    do_clone /var/opt/gitlab/gitlab-ci/builds            $WORK/builds     || raise "Clone: Builds"
  fi
  if [ -z $1 ] || [[ $1 == "artifacts" ]]; then
    do_clone /srv/gitlab/gitlab-rails/shared/artifacts   $WORK/artifacts  || raise "Clone: Artifacts"
  fi
  if [ -z $1 ] || [[ $1 == "registry" ]]; then
    do_clone /srv/gitlab/gitlab-rails/shared/registry    $WORK/registry   || raise "Clone: Registry"
  fi
  if [ -z $1 ] || [[ $1 == "pages" ]]; then
    do_clone /srv/gitlab/gitlab-rails/shared/pages       $WORK/pages      || raise "Clone: Pages"
  fi
  if [ -z $1 ] || [[ $1 == "lfs" ]]; then
    do_clone /srv/gitlab/gitlab-rails/shared/lfs-objects $WORK/lfs        || raise "Clone: LFS"
  fi

  if [ -z $1 ] || [[ $1 == "archive" ]]; then
    do_archive $WORK/uploads/uploads       $WORK/intake/uploads.tar.gz    || raise "Archive: Uploads"
    do_archive $WORK/builds/builds         $WORK/intake/builds.tar.gz     || raise "Archive: Builds"
    do_archive $WORK/artifacts/artifacts   $WORK/intake/artifacts.tar.gz  || raise "Archive: Artifacts"
    do_archive $WORK/registry/registry     $WORK/intake/registry.tar.gz   || raise "Archive: Registry"
    do_archive $WORK/pages/pages           $WORK/intake/pages.tar.gz      || raise "Archive: Pages"
    do_archive $WORK/lfs                   $WORK/intake/lfs.tar.gz        || raise "Archive: LFS"
  fi

  if [ -z $1 ] || [[ $1 == "pack" ]]; then
    db_backup || raise "Archive: DB"
    pack_backup "$latest" || raise "Pack Backup"
  fi

  if [ -z $1 ] || [[ $1 == "cleanup" ]]; then
    if find "$FINAL" -maxdepth 1 -name '*_gitlab_backup.tar' -size 0 -o -empty | grep -q '.'; then
      FAil "Partial or incomplete backups found:"
      while read line; do
        Fail $line;
      done < <(find "$FINAL" -maxdepth 1 -name '*_gitlab_backup.tar' -size 0 -o -empty)
      exit 1
    fi
    if find "$FINAL" -type f -maxdepth 1 -name '*_gitlab_backup.tar' -size -40G | grep -q '.'; then
      Fail "Backups too small:"
      while read line; do
        Fail $line;
      done < <(find "$FINAL" -maxdepth 1 -size -40G)
      exit 1
    fi
    count=$(find "$FINAL" \
      -maxdepth 1 \
      -type f \
      -mtime -30 \
      -name '*gitlab_backup.tar' \
      | wc -l);
    if [ $count -lt 25 ]; then
      Warn "Not enough backups, have $count"
      exit 0
    fi

    Warn "Removing the following backups:"
    while read line; do
      Debug $line;
    done < <(find "$FINAL" -maxdepth 1 -type f -mtime +30 -name '*gitlab_backup.tar' | sort)
    find "$FINAL" -maxdepth 1 -type f -mtime +30 -name '*gitlab_backup.tar' -delete
  fi

}

main $@


