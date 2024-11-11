. "$(dirname "$0")/format_seconds.sh"

check_haf_lib() {
  if [ "$(psql "$POSTGRES_URL" --quiet --no-align --tuples-only --command="SELECT hive.is_instance_ready();")" = f ]; then
    echo "down #HAF not in sync"
    exit 1
  fi
  LAST_IRREVERSIBLE_BLOCK_AGE=$(psql "$POSTGRES_URL" --quiet --no-align --tuples-only --command="select extract('epoch' from now() - created_at)::integer from hafd.blocks where num = (select consistent_block from hafd.irreversible_data)")
  if [ "$LAST_IRREVERSIBLE_BLOCK_AGE" -gt 60 ]; then
    age_string=$(format_seconds "$LAST_IRREVERSIBLE_BLOCK_AGE")
    echo "down #HAF LIB over a minute old ($age_string)"
    exit 2
  fi
}
