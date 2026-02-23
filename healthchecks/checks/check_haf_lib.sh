. "$(dirname "$0")/format_seconds.sh"

# Calculate time offset if EXPECTED_BLOCK_TIME is set (for CI environments)
# This allows healthchecks to work with historical blockchain data
calculate_time_offset() {
  if [ -n "${EXPECTED_BLOCK_TIME:-}" ]; then
    # Convert EXPECTED_BLOCK_TIME to epoch seconds
    EXPECTED_EPOCH=$(date +%s -d "${EXPECTED_BLOCK_TIME}")
    CURRENT_EPOCH=$(date +%s)
    # Calculate how far in the past we're operating
    TIME_OFFSET=$((CURRENT_EPOCH - EXPECTED_EPOCH))
  else
    TIME_OFFSET=0
  fi
}

# Apply time offset to age calculations
adjust_age_for_ci() {
  local age=$1
  if [ "$TIME_OFFSET" -gt 0 ]; then
    # Subtract the offset to get the "real" age relative to expected time
    echo $((age - TIME_OFFSET))
  else
    echo "$age"
  fi
}

check_haf_lib() {
  calculate_time_offset
  
  if [ "$(psql "$POSTGRES_URL" --quiet --no-align --tuples-only --command="SELECT hive.is_instance_ready();")" != t ]; then
    echo "down #HAF not in sync"
    exit 1
  fi
  LAST_IRREVERSIBLE_BLOCK_AGE=$(psql "$POSTGRES_URL" --quiet --no-align --tuples-only --command="select extract('epoch' from now() - created_at)::integer from hafd.blocks where hafd.block_id_to_num(block_id) = (select hafd.block_id_to_num(consistent_block) from hafd.hive_state)")
  
  # Adjust age for CI environments
  ADJUSTED_AGE=$(adjust_age_for_ci "$LAST_IRREVERSIBLE_BLOCK_AGE")
  
  if [ "$ADJUSTED_AGE" -gt 60 ]; then
    age_string=$(format_seconds "$LAST_IRREVERSIBLE_BLOCK_AGE")
    if [ "$TIME_OFFSET" -gt 0 ]; then
      echo "down #HAF LIB over a minute old ($age_string, adjusted from CI offset)"
    else
      echo "down #HAF LIB over a minute old ($age_string)"
    fi
    exit 2
  fi
}
