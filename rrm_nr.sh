#!/bin/sh
# shellcheck disable=1091,3043,2317,3060,3057

. "$IPKG_INSTROOT"/lib/functions.sh
readonly NAME=rrm_nr

config_load $NAME
# Log level: 4=debug, 3=info, 2=warn, 1=err
config_get LOG_LEVEL global log_level 3

log_message() {
  local level="$1"
  shift
  [ "$level" -le "$LOG_LEVEL" ] || return 0
  case "$level" in
    4) logger -p daemon.debug -t rrm_nr "$@" ;;
    3) logger -p daemon.info -t rrm_nr "$@" ;;
    2) logger -p daemon.warn -t rrm_nr "$@" ;;
    1) logger -p daemon.err -t rrm_nr "$@" ;;
  esac
}

count_enabled_wifi_interfaces() {
  local up_configured
  up_configured=0

  is_wifi_interface_enabled() {
    local config disabled mode
    config="$1"
    config_get disabled "$config" disabled 0
    config_get mode "$config" mode

    [ "$disabled" -eq 0 ] && [ "$mode" = "ap" ] && up_configured=$((up_configured + 1))
  }

  config_load wireless
  config_foreach is_wifi_interface_enabled wifi-iface

  echo "$up_configured"
}

check_wifi() {
  [ "$(count_enabled_wifi_interfaces)" -gt 0 ] && return 0
  log_message 1 "No enabled Wi-Fi interfaces found"
  exit 1
}

wait_for_wifi() {
  are_all_wireless_interfaces_up() {
    local num_up
    num_up=$(ubus list hostapd.* | wc -l)
    count=$(count_enabled_wifi_interfaces)
    [ "$count" -eq "$num_up" ] && return 0
  }

  local max=6 n=1
  while [ $n -le $max ] && ! are_all_wireless_interfaces_up; do
    log_message 3 "Waiting for all Wi-Fi interfaces to initialize (Run: $n/$max)"
    n=$((n + 1))
    sleep 30
  done

  [ $max -eq $n ] && log_message 1 "Aborted due to long waiting time; check all hanging enabled Wi-Fi interfaces"
}

is_802dot11k_nr_enabled() {
  load_sections() {
    local config ssid device _ssid _device ieee80211k
    config="$1"
    ssid="$2"
    device="${3/phy/radio}"
    config_get _ssid "$config" ssid
    config_get _device "$config" device
    config_get disabled "$config" disabled 0
    config_get ieee80211k "$config" ieee80211k 0

    [ "$disabled" = "0" ] && [ "$ieee80211k" = "1" ] && [ "$ssid" = "$_ssid" ] && [ "$device" = "$_device" ] && is_802dot11k_nr_enabled=true
  }

  ssid=$1
  phy=$2
  is_802dot11k_nr_enabled=false
  config_load wireless
  config_foreach load_sections wifi-iface "$ssid" "$phy"
  $is_802dot11k_nr_enabled
}

get_valid_wifi_iface_list() {
  is_802dot11k_nr_enabled() {
    load_sections() {
      local config ssid device _ssid _device ieee80211k
      config="$1"
      ssid="$2"
      device="${3/phy/radio}"
      config_get _ssid "$config" ssid
      config_get _device "$config" device
      config_get disabled "$config" disabled 0
      config_get ieee80211k "$config" ieee80211k 0

      [ "$disabled" = "0" ] && [ "$ieee80211k" = "1" ] && [ "$ssid" = "$_ssid" ] && [ "$device" = "$_device" ] && _is_802dot11k_nr_enabled=true
    }

    local ssid phy _is_802dot11k_nr_enabled
    ssid=$1
    phy=$2
    _is_802dot11k_nr_enabled=false

    config_load wireless
    config_foreach load_sections wifi-iface "$ssid" "$phy"
    $_is_802dot11k_nr_enabled
  }

  local wifi_iface
  for iface in $(ubus list hostapd.*); do
    eval "$(ubus -v call "$iface" get_status | jsonfilter -e ssid='$.ssid' -e phy='$.phy')"
    is_802dot11k_nr_enabled "$ssid" "$phy" && echo "${iface/hostapd./}"
  done
}

get_ssid() {
  iwinfo "${1:?Missing: Wi-Fi iface}" info | grep ESSID | cut -d\" -f2
}

restart_or_update_umdns() {
  if [ -z "$(ubus call umdns browse | jsonfilter -e '@["_'"$NAME"'._udp"]')" ]; then
    # For unknown reason, umdns doesn't publish anything with this error visible in logs: "do_page_fault(): sending SIGSEGV to umdns for invalid write access to 00000004".
    service umdns restart
    log_message 2 "Restarted umdns service as nothing is getting published."
  else
    ubus call umdns update
  fi
}

_do_updates() {

  local wifi_iface
  local wifi_iface_list

  local all_rrm_nr
  local old_all_rrm_nr
  local all_rrm_nr_length
  local ssid

  restart_or_update_umdns
  sleep 5

  wifi_iface_list="$(get_valid_wifi_iface_list)"

  for wifi_iface in $wifi_iface_list; do

    ssid="$(get_ssid "$wifi_iface")"

    get_internal_rrm_nr_lists() {
      local other_wifi_iface
      for other_wifi_iface in $wifi_iface_list; do
        { [ "$wifi_iface" = "$other_wifi_iface" ] || [ "$ssid" != "$(get_ssid "$other_wifi_iface")" ]; } && continue
        ubus call hostapd."${other_wifi_iface}" rrm_nr_get_own | jsonfilter -e '$.value'
      done
    }

    get_external_rrm_nr_lists() {

      create_wlan_keys_string() {
        local string
        local current
        local count

        current=0
        count=${1:?Missing: Number of keys}

        while [ "$current" -lt "$count" ]; do
          string="$string,\"wlan$current\""
          current=$((current + 1))
        done

        printf "%s" "${string:1}"
      }

      local router json_root_string
      json_root_string="$(ubus call umdns browse | sed "s/\"txt\": \"\(\([[:alnum:]]\|_\)\+\)=/\"\1\": \"/" | jsonfilter -e '@["_'"$NAME"'._udp"]')"

      [ -z "$json_root_string" ] && return 0

      eval "$(jsonfilter -s "$json_root_string" -e 'JSON_ROOT_KEYS=$')"

      for router in $JSON_ROOT_KEYS; do
        local json_selector
        json_selector="$(create_wlan_keys_string "$(jsonfilter -s "$json_root_string" -e "@['$router'].wlan_length")")"
        jsonfilter -s "$json_root_string" -e "@['$router'][$json_selector]" | grep "\"${ssid}\""
      done

      unset JSON_ROOT_KEYS
    }

    all_rrm_nr="$( (
      get_internal_rrm_nr_lists
      get_external_rrm_nr_lists
    ) | sort -u | tr '\n' ',' | sed "s/,$//")"

    old_all_rrm_nr="$(ubus call hostapd."$wifi_iface" rrm_nr_list | jsonfilter -e '@.list[@]' | sort -u | tr '\n' ',' | sed "s/,$//")"

    if [ "$old_all_rrm_nr" = "$all_rrm_nr" ]; then
      # Setting a new list will cause the wifi to quickly cycle, which we do not want every 60s
      continue
    fi

    all_rrm_nr_length=$(echo "$all_rrm_nr" | grep -o "$ssid" | wc -l)
    ubus call hostapd."${wifi_iface}" rrm_nr_set "{ \"list\": [$all_rrm_nr] }"
    log_message 3 "Updated $wifi_iface's 802.11k rrm_nr_list[$all_rrm_nr_length]: [ $all_rrm_nr ]"
  done

}
