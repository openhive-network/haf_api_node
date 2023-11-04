format_seconds() {
  remainder="$1"
  age_string=""
  if [ $remainder -gt 31536000 ]; then
    years=$((remainder / 31536000))
    age_string="${years}y"
    remainder=$((remainder - years * 31536000))
  fi
  if [ $remainder -gt 2592000 ]; then
    months=$((remainder / 2592000))
    age_string="${age_string}${months}M"
    remainder=$((remainder - months * 2592000))
  fi
  if [ $remainder -gt 86400 ]; then
    days=$((remainder / 86400))
    age_string="${age_string}${days}d"
    remainder=$((remainder - days * 86400))
  fi
  if [ $remainder -gt 3600 ]; then
    hours=$((remainder / 3600))
    age_string="${age_string}${hours}h"
    remainder=$((remainder - hours * 3600))
  fi
  if [ $remainder -gt 60 ]; then
    minutes=$((remainder / 60))
    age_string="${age_string}${minutes}m"
    remainder=$((remainder - minutes * 60))
  fi
  if [ $remainder -gt 0 ]; then
    age_string="${age_string}${remainder}s"
  fi
  echo "$age_string"
}
