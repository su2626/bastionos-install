#!/usr/bin/env bash
# BastionOS installer (ADR-0095). Public: it holds no secret and no code of
# BastionOS, only the steps to fetch an installation bundle.
#
#   curl -fsSL https://raw.githubusercontent.com/su2626/bastionos-install/main/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/su2626/bastionos-install/main/install.sh | sudo bash -s 1.0.0
#
#   bash install.sh [VERSION (default: the latest version, BASTION_LATEST)] [--dir /var/dck/bastionos (asked if not given)] [--yes] [--no-backup]
#                   [--registry ghcr.io/su2626/bastionos]
#                   [--bundle bastionos-airgap-1.4.0-linux-amd64.tar
#                    (--pubkey release.pub | --unsigned)]
#
# 1. checks Docker, Compose v2 and openssl;
# 2. signs in to the registry when the images are private (a token that can
#    read the packages, kept in <dir>/.docker for upgrades);
# 3. takes the deployment bundle of VERSION out of its installer image:
#    Compose files, OpenBao configuration, operating scripts and the
#    `bastionos` command. No source code is installed;
# 4. runs `bastionos install`, which asks its questions on the terminal,
#    writes the configuration and the secrets, pulls the images, starts the
#    stack and checks its health.
#
# On a host that is already installed, it upgrades to VERSION instead,
# after a backup (--no-backup skips it).
# --bundle installs from an air-gapped bundle (ADR-0066) without Internet.
set -euo pipefail

# The latest version: installed when none is named. Moved at each release
# (docs/deployment/RELEASING.md). "main" installs the latest build of the
# main branch, for tests only.
BASTION_LATEST=1.0.0

main() {
  local version= dir=${BASTION_INSTALL_DIR:-} registry=ghcr.io/su2626/bastionos bundle= pubkey= unsigned= yes= nobackup=
  while [ $# -gt 0 ]; do
    case $1 in
      --dir) dir=$2; shift 2 ;;
      --registry) registry=$2; shift 2 ;;
      --bundle) bundle=$2; shift 2 ;;
      --pubkey) pubkey=$2; shift 2 ;;
      --unsigned) unsigned=1; shift ;;
      --yes|-y) yes=1; shift ;;
      --no-backup) nobackup=1; shift ;;
      -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
      -*) die "unknown option $1" ;;
      *) [ -z "$version" ] || die "one version only"; version=$1; shift ;;
    esac
  done

  case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in fr*) FR=1 ;; *) FR= ;; esac
  command -v docker >/dev/null || die "$(t "Docker is required: https://docs.docker.com/engine/install/" "Docker est nécessaire : https://docs.docker.com/engine/install/")"
  docker info >/dev/null 2>&1 || die "$(t "cannot talk to Docker (run as root, or as a member of the docker group)" "impossible de joindre Docker (lancez en root, ou membre du groupe docker)")"
  docker compose version >/dev/null 2>&1 || die "$(t "Docker Compose v2 is required" "Docker Compose v2 est nécessaire")"
  command -v openssl >/dev/null || die "$(t "openssl is required" "openssl est nécessaire")"

  # The installation directory: --dir, BASTION_INSTALL_DIR, or asked on the
  # terminal (the default kept under --yes or without a terminal).
  if [ -z "$dir" ]; then
    dir=/var/dck/bastionos
    if [ -z "$yes" ] && [ ! -s "$dir/deploy/compose/.env" ] && (: </dev/tty) 2>/dev/null; then
      local answer=
      printf '%s [%s]: ' "$(t "Installation directory" "Dossier d'installation")" "$dir" >&2
      IFS= read -r answer </dev/tty || true
      [ -z "$answer" ] || dir=$answer
    fi
  fi
  case $dir in /*) ;; *) die "$(t "the installation directory must be an absolute path: $dir" "le dossier d'installation doit être un chemin absolu : $dir")" ;; esac
  dir=${dir%/}

  if [ -n "$bundle" ]; then
    offline "$bundle"
    registry=bastionos
    export BASTION_INSTALL_SOURCE=airgap
  fi
  if [ -z "$version" ]; then
    if [ -f "$dir/deploy/compose/.env" ]; then
      version=$(sed -n 's/^BASTION_VERSION=//p' "$dir/deploy/compose/.env" | tail -1)
    else
      version=$BASTION_LATEST
      say "$(t "no version given: installing the latest version, $version" "aucune version donnée : installation de la dernière version, $version")"
    fi
  fi
  printf '%s\n' "$version" | grep -Eq '^(main|sha-[0-9a-f]{12}|[0-9]+\.[0-9]+(\.[0-9]+(-[0-9A-Za-z.-]+)?)?)$' ||
    die "$(t "not a version: $version (1.0.0, 1.0, main or sha-<12 hex>)" "version invalide : $version (1.0.0, 1.0, main ou sha-<12 hex>)")"

  umask 022
  mkdir -p "$dir"
  chmod 750 "$dir"
  export DOCKER_CONFIG="$dir/.docker"
  mkdir -p "$DOCKER_CONFIG"
  chmod 700 "$DOCKER_CONFIG"

  local img="$registry/installer:$version"
  if [ -z "$bundle" ]; then
    login "$img"
  fi

  # An installed host is upgraded: its own command knows how.
  if [ -s "$dir/deploy/compose/.env" ] && [ -x "$dir/bastionos" ]; then
    say "$(t "BastionOS is installed in $dir: upgrading to $version." "BastionOS est installé dans $dir : mise à jour vers $version.")"
    exec "$dir/bastionos" upgrade "$version" ${yes:+--yes} ${nobackup:+--no-backup}
  fi

  say "$(t "Fetching the bundle $version..." "Récupération du bundle $version...")"
  local tmp cid
  tmp=$(mktemp -d "$dir/.bundle.XXXXXX")
  [ -n "$bundle" ] || docker pull -q "$img" >/dev/null || die "$(t "cannot pull $img: does version $version exist, and may this token read it?" "impossible de tirer $img : la version $version existe-t-elle, et ce jeton peut-il la lire ?")"
  cid=$(docker create "$img" bundle) || die "$(t "image $img not found" "image $img introuvable")"
  docker cp "$cid:/bundle/." "$tmp" >/dev/null
  docker rm -f "$cid" >/dev/null
  [ -f "$tmp/bastionos" ] || die "$(t "$img holds no bundle" "$img ne contient pas de bundle")"
  # The bundle's own command places it (it keeps nothing of a former one).
  BASTION_HOME="$dir" bash "$tmp/bastionos" place-bundle "$tmp"
  rm -rf "$tmp"
  printf '%s\n' "$version" >"$dir/VERSION"
  if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
    ln -sf "$dir/bastionos" /usr/local/bin/bastionos
  fi

  local args=(install --version "$version" --registry "$registry")
  [ -z "$bundle" ] || args+=(--premium-registry bastionos)
  [ -z "$yes" ] || args+=(--yes)
  exec "$dir/bastionos" "${args[@]}"
}

t() { if [ -n "${FR:-}" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
say() { printf '%s\n' "$*" >&2; }
warn() { printf '%s %s\n' "$(t "warning:" "attention :")" "$*" >&2; }
die() { printf '%s %s\n' "$(t "error:" "erreur :")" "$*" >&2; exit 1; }

# login IMAGE: pulls the installer image, signing in to its registry first
# when it cannot be read anonymously. The token is read on the terminal (or from
# BASTION_REGISTRY_USER / BASTION_REGISTRY_TOKEN) and passed on stdin.
login() {
  local img=$1 host=${1%%/*} user=${BASTION_REGISTRY_USER:-} token=${BASTION_REGISTRY_TOKEN:-}
  # Pulled already (public images, or a login kept from a former run).
  if docker pull -q "$img" >/dev/null 2>&1; then return 0; fi
  if [ -z "$token" ]; then
    (: </dev/tty) 2>/dev/null || die "$(t "$host needs a login: set BASTION_REGISTRY_USER and BASTION_REGISTRY_TOKEN" "$host demande une connexion : définissez BASTION_REGISTRY_USER et BASTION_REGISTRY_TOKEN")"
    say "$(t "The images on $host are private: sign in with the account and the token (read:packages) you were given." "Les images sur $host sont privées : connectez-vous avec le compte et le jeton (read:packages) qui vous ont été remis.")"
    printf '%s: ' "$(t "Account" "Compte")" >&2
    [ -n "$user" ] || IFS= read -r user </dev/tty
    printf '%s: ' "$(t "Token (hidden)" "Jeton (masqué)")" >&2
    stty -echo </dev/tty 2>/dev/null || true
    IFS= read -r token </dev/tty || true
    stty echo </dev/tty 2>/dev/null || true
    printf '\n' >&2
  fi
  [ -n "$user" ] && [ -n "$token" ] || die "$(t "account and token are required" "le compte et le jeton sont nécessaires")"
  printf '%s' "$token" | docker login "$host" -u "$user" --password-stdin >/dev/null ||
    die "$(t "sign-in to $host refused" "connexion à $host refusée")"
  chmod 600 "$DOCKER_CONFIG/config.json" 2>/dev/null || true
  say "$(t "Signed in to $host (kept in $DOCKER_CONFIG for upgrades)." "Connecté à $host (gardé dans $DOCKER_CONFIG pour les mises à jour).")"
}

# offline BUNDLE.tar: verifies and loads an air-gapped bundle (ADR-0066).
# Nothing from the archive runs: the signature and the checksums are
# checked here, as deploy/airgap/install.sh does, then only the image
# archive is handed to docker load.
offline() {
  local tar=$1 tmp b listed present
  [ -s "$tar" ] || die "$(t "no such file: $tar" "fichier introuvable : $tar")"
  [ -n "$pubkey" ] || [ -n "$unsigned" ] || die "$(t "give the release public key with --pubkey (or --unsigned for a test bundle)" "donnez la clé publique de la version avec --pubkey (ou --unsigned pour un bundle de test)")"
  [ -z "$pubkey" ] || [ -s "$pubkey" ] || die "$(t "no such public key: $pubkey" "clé publique introuvable : $pubkey")"
  command -v sha256sum >/dev/null || die "$(t "sha256sum is required" "sha256sum est nécessaire")"
  tmp=$(mktemp -d)
  # No absolute path nor .. in the archive.
  if tar -tf "$tar" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then rm -rf "$tmp"; die "$(t "unsafe paths in $tar" "chemins dangereux dans $tar")"; fi
  tar -C "$tmp" --no-same-owner -xf "$tar"
  b=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -n "$b" ] && [ -s "$b/SHA256SUMS" ] && [ -s "$b/images.tar.gz" ] || { rm -rf "$tmp"; die "$(t "not an air-gapped bundle: $tar" "ce n'est pas un bundle hors ligne : $tar")"; }
  if [ -n "$pubkey" ]; then
    [ -s "$b/SHA256SUMS.sig" ] || { rm -rf "$tmp"; die "$(t "this bundle is not signed" "ce bundle n'est pas signé")"; }
    openssl pkeyutl -verify -pubin -inkey "$pubkey" -rawin -in "$b/SHA256SUMS" -sigfile "$b/SHA256SUMS.sig" >/dev/null 2>&1 ||
      { rm -rf "$tmp"; die "$(t "the signature does not match $pubkey: do not install this bundle" "la signature ne correspond pas à $pubkey : n'installez pas ce bundle")"; }
  else
    warn "$(t "signature not checked (--unsigned): the checksums prove nothing about the origin" "signature non vérifiée (--unsigned) : les sommes de contrôle ne prouvent rien de l'origine")"
  fi
  (cd "$b" && sha256sum --quiet -c SHA256SUMS) || { rm -rf "$tmp"; die "$(t "a file of the bundle does not match SHA256SUMS" "un fichier du bundle ne correspond pas à SHA256SUMS")"; }
  listed=$(sed 's/^[0-9a-f]\{64\}  //' "$b/SHA256SUMS" | LC_ALL=C sort)
  present=$(cd "$b" && find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.sig | sed 's|^\./||' | LC_ALL=C sort)
  [ "$listed" = "$present" ] || { rm -rf "$tmp"; die "$(t "the bundle has files SHA256SUMS does not list" "le bundle contient des fichiers absents de SHA256SUMS")"; }
  say "$(t "Loading the images..." "Chargement des images...")"
  gzip -dc "$b/images.tar.gz" | docker load -q >/dev/null || { rm -rf "$tmp"; die "docker load"; }
  [ -n "$version" ] || version=$(head -1 "$b/VERSION")
  rm -rf "$tmp"
}

main "$@"; exit $?
