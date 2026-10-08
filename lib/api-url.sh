#!/usr/bin/env bash
# AGD-11: the API root every CLI call of the action uses. A served .ptc-config.yml names its PTC in `api_url:` when that
# PTC is not production (a lab, a self-hosted instance); the config wins over the api-url input's DEFAULT only, never
# over an explicit non-default input. Read the way the CLI reads it (first `api_url:` line, trailing spaces trimmed).
ptc_effective_api_url() {  # ptc_effective_api_url <api-url input> [config file]
  local input="$1" config="${2:-}" from_config=""
  if [ "$input" = "https://app.ptc.wpml.org/api/v1/" ] && [ -n "$config" ] && [ -f "$config" ]; then
    from_config="$(sed -n 's/^api_url: *//p' "$config" | sed 's/ *$//' | head -n 1)"
  fi
  printf '%s\n' "${from_config:-$input}"
}
