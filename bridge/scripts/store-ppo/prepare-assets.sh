#!/usr/bin/env bash

set -euo pipefail

output_dir="${1:-}"
if [[ -z "$output_dir" || "$output_dir" == "/" ]]; then
  echo "Usage: prepare-assets.sh <output-directory>" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
store_dir="${repo_root}/apps/mobile/fastlane/screenshots/store"
ui_hero_dir="${repo_root}/apps/mobile/fastlane/screenshots/ppo/ui-only"

locales=(en-US ja zh-Hans ko)
screenshots=(
  01_session_list.png
  02_recent_sessions.png
  03_approval_list.png
  04_multi_question.png
  05_explorer.png
  06_git_actions.png
  07_images_screenshots.png
  08_network_resilience.png
)

for locale in "${locales[@]}"; do
  connection_output="${output_dir}/connection/${locale}"
  ui_output="${output_dir}/ui-only/${locale}"
  mkdir -p "$connection_output" "$ui_output"

  for screenshot in "${screenshots[@]}"; do
    source="${store_dir}/${locale}/${screenshot}"
    [[ -f "$source" ]] || {
      echo "Missing store screenshot: $source" >&2
      exit 1
    }
    cp "$source" "${connection_output}/${screenshot}"
    cp "$source" "${ui_output}/${screenshot}"
  done

  ui_hero="${ui_hero_dir}/${locale}/01_session_list.png"
  [[ -f "$ui_hero" ]] || {
    echo "Missing UI-focused hero: $ui_hero" >&2
    exit 1
  }
  cp "$ui_hero" "${ui_output}/01_session_list.png"
done

echo "Prepared PPO assets in ${output_dir}"
