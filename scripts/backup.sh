#!/usr/bin/env bash
# Encrypted PostgreSQL backup with retention (CL-53).
#
#   BACKUP_AGE_RECIPIENT=age1... scripts/backup.sh
#
# Dumps the database with `pg_dump -Fc` as the owner role and encrypts the
# stream with `age` straight to the public key in BACKUP_AGE_RECIPIENT. The
# plaintext dump is never written to disk: it only exists in the pipe, so there
# is nothing to clean up (or leak) if a step fails. The result is
#
#   $BACKUP_DIR/cash_lens_backup_<UTC YYYYmmdd_HHMMSS>.dump.age   (mode 600)
#
# Then old backups are pruned (see "Retention"). It aborts, non-zero and before
# touching anything, when BACKUP_AGE_RECIPIENT is unset.
#
# Environment
#   BACKUP_AGE_RECIPIENT   required. age public key (age1...) or an `ssh-ed25519`
#                          recipient. Only the public half belongs on the server.
#   BACKUP_DATABASE_URL    connection URL for the owner role; defaults to
#                          MIGRATION_DATABASE_URL (an `ecto://` URL is accepted).
#                          With neither set, libpq's PG* variables are used.
#                          Add `?sslmode=verify-full&sslrootcert=...` for TLS.
#                          The role must be able to read the forced-RLS tables:
#                          superuser or BYPASSRLS (the app role is neither, so it
#                          cannot take a backup).
#   BACKUP_DIR             output directory, default ./backups (git-ignored).
#
# Retention (by the UTC date in the file name, not mtime). A backup is kept when
# any rule matches, otherwise deleted:
#   daily    every backup younger than 7 days
#   weekly   Sunday backups younger than 28 days (4 weeks)
#   monthly  backups taken on the 1st younger than 183 days (6 months)
#
# Restore (rehearse it; an untested backup is a hope, not a backup):
#   age -d -i key.txt backups/cash_lens_backup_X.dump.age | pg_restore -d "$URL" --clean --if-exists --no-owner
#
# Testing hooks: BACKUP_TEST_NOW=YYYYmmdd_HHMMSS replaces the clock.
set -euo pipefail
umask 077

die() {
  echo "backup.sh: $*" >&2
  exit 1
}

if [ -z "${BACKUP_AGE_RECIPIENT:-}" ]; then
  die "BACKUP_AGE_RECIPIENT is not set; refusing to write an unencrypted backup"
fi
command -v pg_dump >/dev/null 2>&1 || die "pg_dump not found"
command -v age >/dev/null 2>&1 || die "age not found (https://github.com/FiloSottile/age)"

backup_dir="${BACKUP_DIR:-$(cd "$(dirname "$0")/.." && pwd)/backups}"
mkdir -p "$backup_dir"
chmod 700 "$backup_dir"

now="${BACKUP_TEST_NOW:-$(date -u +%Y%m%d_%H%M%S)}"
final="$backup_dir/cash_lens_backup_${now}.dump.age"
partial="$final.partial"

# Whatever happens, never leave a half-written file that looks like a backup.
trap 'rm -f "$partial"' EXIT

url="${BACKUP_DATABASE_URL:-${MIGRATION_DATABASE_URL:-}}"
url="${url/#ecto:\/\//postgresql://}"

dump_args=(-Fc --no-password)
if [ -n "$url" ]; then
  dump_args+=("$url")
fi

# pipefail: a failing pg_dump or age fails the whole pipeline.
pg_dump "${dump_args[@]}" | age -r "$BACKUP_AGE_RECIPIENT" -o "$partial"
[ -s "$partial" ] || die "encrypted backup is empty"

chmod 600 "$partial"
mv "$partial" "$final"
echo "backup.sh: wrote $final"

# --- retention ---------------------------------------------------------------

# Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm); pure
# arithmetic, so it behaves the same with GNU and BSD date.
days_from_civil() {
  local y=$1 m=$((10#$2)) d=$((10#$3)) era yoe doy doe
  [ "$m" -le 2 ] && y=$((y - 1))
  era=$((y >= 0 ? y / 400 : (y - 399) / 400))
  yoe=$((y - era * 400))
  doy=$(((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1))
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  echo $((era * 146097 + doe - 719468))
}

today_days=$(days_from_civil "${now:0:4}" "${now:4:2}" "${now:6:2}")

for file in "$backup_dir"/cash_lens_backup_*.dump.age; do
  [ -e "$file" ] || continue
  name=${file##*/}
  stamp=${name#cash_lens_backup_}
  stamp=${stamp%.dump.age}
  # Skip anything that does not carry a timestamp we wrote.
  [[ "$stamp" =~ ^[0-9]{8}_[0-9]{6}$ ]] || continue

  y=${stamp:0:4} m=${stamp:4:2} d=${stamp:6:2}
  file_days=$(days_from_civil "$y" "$m" "$d")
  age_days=$((today_days - file_days))
  # 1970-01-01 was a Thursday; 0 = Sunday.
  weekday=$(((file_days + 4) % 7))

  keep=false
  [ "$age_days" -lt 7 ] && keep=true
  [ "$weekday" -eq 0 ] && [ "$age_days" -lt 28 ] && keep=true
  [ "$((10#$d))" -eq 1 ] && [ "$age_days" -lt 183 ] && keep=true

  if [ "$keep" = false ]; then
    rm -f -- "$file"
    echo "backup.sh: pruned $name"
  fi
done
