#!/bin/bash

# SPDX-FileCopyrightText: 2025 Łukasz Wojniłowicz <lukasz.wojnilowicz@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later

which sqlite3 &>/dev/null
[[ $? -eq 1 ]] && echo "No sqlite3 executable. Please install it." && exit 1

function is_number() {
  case $1 in
  '' | *[!0-9]*) echo 0 ;;
  *) echo 1 ;;
  esac
}

while getopts "hw:a:s:e:g:f:bc" opt; do
  case $opt in
  w)
    [[ $(is_number "$OPTARG") -eq 0 ]] && echo "The -w parameter cannot contain non-digits." && exit 1
    declare -ri input_window_bucket_id=$OPTARG
    ;;
  a)
    [[ $(is_number "$OPTARG") -eq 0 ]] && echo "The -a parameter cannot contain non-digits." && exit 1
    declare -ri input_afk_bucket_id=$OPTARG
    ;;
  s)
    [[ $(is_number "$OPTARG") -eq 0 ]] && echo "The -s parameter cannot contain non-digits." && exit 1
    [[ ${#OPTARG} -ne 19 ]] && echo "The -s parameter should have 19 digits." && exit 1
    declare -ri input_start_period=$OPTARG
    ;;
  e)
    [[ $(is_number "$OPTARG") -eq 0 ]] && echo "The -e parameter cannot contain non-digits." && exit 1
    [[ ${#OPTARG} -ne 19 ]] && echo "The -e parameter should have 19 digits." && exit 1
    declare -ri input_end_period=$OPTARG
    ;;
  g)
    [[ $(is_number "$OPTARG") -eq 0 ]] && echo "The -g parameter cannot contain non-digits." && exit 1
    [[ ${#OPTARG} -gt 5000 ]] && echo "It's unlikely for the -g parameter to be bigger than 5000 ms." && exit 1
    declare -ri input_gap_ms=$OPTARG
    ;;
  f)
    [[ ! -f "$OPTARG" ]] && echo "The file doesn't exist." && exit 1
    [[ $(head -c 15 "$OPTARG") != "SQLite format 3" ]] && echo "The file isn't a SQLite database." && exit 1
    declare -r db_filename="$OPTARG"
    ;;
  b)
    declare -ri bypass=1
    ;;
  c)
    declare -ri validation_only=1
    ;;
  h)
    echo "Description:"
    echo "A tool for filling gaps of inactivity, that awatcher creates between neighbouring window events, even when the user is not afk."
    echo ""
    echo "Usage:"
    echo "$(basename "$0") [-h] [-w id] [-a id] [-s nanoseconds] [-e nanoseconds] [-g milliseconds] [-b] [-c] -f filename"
    echo "-h print this help"
    echo "-w window events bucket id (autodetected by default)"
    echo "-a afk events bucket id (autodetected by default)"
    echo "-s start period in which to fill gaps (whole database by default)"
    echo "-e end period in which to fill gaps (whole database by default)"
    echo "-g length of desired gap in ms between adjacent events (0 by default)"
    echo "-b bypass warnings"
    echo "-c validate that there is no overlap between adjacent window events"
    echo "-f aw-server database file"
    echo ""
    echo "Example usage:"
    echo "$(basename "$0") -f sqlite.db"
    echo "$(basename "$0") -c -f sqlite.db"
    echo "$(basename "$0") -w 1 -a 2 -s 1742252400000000000 -e 1742338740000000000 -g 500 -f sqlite.db"
    echo ""
    echo "Hints:"
    echo "Use 'date +%s%N --date=\"2025-03-18 00:00 CET\"' to get numbers for the -s and -e parameters."
    echo "aw-server database file is usually in /home/$USER/.local/share/activitywatch/aw-server-rust/sqlite.db"
    exit 0
    ;;
  \?)
    echo "Invalid option -$OPTARG" >&2
    exit 1
    ;;
  esac
done

[[ ! -v input_gap_ms ]] && declare -ri input_gap_ms=0
declare -ri input_gap_ns=$((input_gap_ms * 1000000))

if [[ -v input_start_period && -v input_end_period &&
  $input_start_period -ge $input_end_period ]]; then
  echo "The -s parameter cannot be greater or equal to the -e parameter."
  exit 1
fi

if [[ ! -v db_filename ]]; then
  echo "No mandatory -f parameter passed."
  exit 1
fi

if [[ (-n $(pgrep aw-server) || -n $(pgrep aw-server-rust)) && ! -v bypass && ! -v validation_only ]]; then
  echo "aw-server is running, which might cause data corruption with this script."
  echo "Please stop it or use the -b parameter to bypass this, if you know what you're doing."
  exit 1
fi

if [[ ! -v bypass && ! -v validation_only ]]; then
  read -rp "You might loose your data, if something will go wrong. A backup is recommended. Continue? (y/n): " continue
  [[ $continue != 'y' ]] && exit
fi

# an event looks like:
# starttime|endtime|id
# 1742309414661216459|1742309887087611612|482101
function get_id() {
  local -n _id=$1
  _id="${2:40}"
}

function get_starttime() {
  local -n _starttime=$1
  _starttime="${2:0:19}"
}

function get_endtime() {
  local -n _endtime=$1
  _endtime="${2:20:19}"
}

function load_events_from_db() {
  local -n events=$1
  local -i bucket_id=$2
  local input_start_period_constraint=$3
  local input_end_period_constraint=$4
  local input_middle_period_constraint=$5
  mapfile -t events < <(
    sqlite3 "$db_filename" <<EOF
SELECT starttime, endtime, id FROM events
WHERE bucketrow == $bucket_id $input_start_period_constraint $input_end_period_constraint $input_middle_period_constraint;
EOF
  )
  local -ri starttime_idx=2
  readarray -t events < <(printf '%s\n' "${events[@]}" | sort -k${starttime_idx} -n -t'|')
}

function nanosec2human_readable() {
  local -i seconds=$((10#$1 / 1000000000 % 60))
  local -i days=$((10#$1 / 1000000000 / 60 / 60 / 24))
  local -i hours=$((10#$1 / 1000000000 / 60 / 60 - days * 24))
  local -i minutes=$((10#$1 / 1000000000 / 60 - hours * 60))

  printf "%d d %d h %d m %d s" "$days" "$hours" "$minutes" "$seconds"
}

function get_bucket_names() {
  declare -a buckets
  declare -n _buckets_by_id=$2
  mapfile -t buckets < <(sqlite3 "$db_filename" "SELECT id,name FROM buckets WHERE client = '$1';")
  for bucket in "${buckets[@]}"; do
    mapfile -t id_and_bucket < <(echo "$bucket" | tr '|' '\n')
    _buckets_by_id["${id_and_bucket[0]}"]=${id_and_bucket[1]}
  done
}

function select_bucket_id() {
  local -n _in_selected_bucket_id=$1
  local client_name=$2
  local -i input_bucket_id=$3
  local parameter=$4
  local -A buckets_by_id
  get_bucket_names "$client_name" buckets_by_id
  if [[ ${#buckets_by_id[@]} -gt 1 ]]; then
    for id in "${!buckets_by_id[@]}"; do
      [[ $id -ne $input_bucket_id ]] && continue
      local selected_bucket_id
      selected_bucket_id=$id
      break
    done

    if [[ ! -v selected_bucket_id ]]; then
      echo "More than one $client_name. Pick an id below," \
        "and restart with 'sh $0 -$parameter 23', if id=23"
      for id in "${!buckets_by_id[@]}"; do
        echo "id=$id name=${buckets_by_id[$id]}"
      done
      exit
    fi
  elif [[ ${#buckets_by_id[@]} -eq 0 ]]; then
    echo "No $client_name bucket present. Exiting."
    exit 1
  else
    local selected_bucket_id
    selected_bucket_id=$(echo "${!buckets_by_id[@]}" | cut -f1 -d' ')
  fi
  _in_selected_bucket_id=$selected_bucket_id
}

function get_is_event_in_adjacent_afk() {
  local -n _ret_val=$1
  local -i starttime=$2
  local -i current_afk_event=$3
  local -n in_afk_events=$4

  local -i afk_endtime
  local -i afk_starttime_next
  local -i afk_endtime_next
  local -i i=$current_afk_event
  for (( ; i < ${#in_afk_events[@]}; i += 1)); do
    [[ $((i + 1)) -ge ${#in_afk_events[@]} ]] && return
    get_endtime afk_endtime "${in_afk_events[$i]}"
    get_starttime afk_starttime_next "${in_afk_events[$((i + 1))]}"
    # it could be an afk range from the next day
    [[ $afk_endtime -ne $afk_starttime_next ]] && return
    get_endtime afk_endtime_next "${in_afk_events[$((i + 1))]}"
    if [[ $starttime -ge $afk_starttime_next &&
      $starttime -le $afk_endtime_next ]]; then
      _ret_val=1
      return
    fi
  done
}

function validate() {
  echo "Validation:"
  echo "  Checking if no overlapping occurs between window events:"
  i=0
  j=0
  for j in "${!window_events[@]}"; do
    echo -ne "    window_event $((j + 1))/${#window_events[@]}\r"
    [[ $((j + 1)) -ge "${#window_events[@]}" ]] && break
    declare -i window_id
    get_id window_id "${window_events[$j]}"
    get_starttime window_starttime "${window_events[$j]}"
    get_endtime window_endtime "${window_events[$j]}"
    declare -i next_window_id
    get_id next_window_id "${window_events[j + 1]}"
    get_starttime next_window_starttime "${window_events[j + 1]}"
    get_endtime next_window_endtime "${window_events[j + 1]}"
    if [[ $window_endtime -gt $next_window_starttime ]]; then
      echo -ne '\n'
      echo "    prev_window_endtime > next_window_starttime ($window_endtime > $next_window_starttime), prev_window_event_id: $window_id next_window_event_id: $next_window_id"
    fi
  done
  echo -ne '\n'
  echo "  Finished."
  j=0
  echo "  Checking if the gaps between window events are equal to $input_gap_ms ms:"
  for i in "${!afk_events[@]}"; do
    declare -i afk_starttime
    declare -i afk_endtime
    get_starttime afk_starttime "${afk_events[$i]}"
    get_endtime afk_endtime "${afk_events[$i]}"
    afk_events_total_time+=$((afk_endtime - afk_starttime))
    first_event_in_afk_found=0
    for (( ; j < ${#window_events[@]}; j += 1)); do
      echo -ne "    afk_event $((i + 1))/${#afk_events[@]}, window_event $((j + 1))/${#window_events[@]}\r"
      get_endtime window_endtime "${window_events[$j]}"
      # skip events that are not/before in the afk range
      [[ $window_endtime -le $afk_starttime ]] && continue
      get_starttime window_starttime "${window_events[$j]}"
      # skip the afk range that has no window events in itself
      [[ $window_starttime -ge $afk_endtime ]] && break

      if [[ $((j + 1)) -ge ${#window_events[@]} ]]; then
        continue
      else
        declare -i next_window_starttime
        get_starttime next_window_starttime "${window_events[$((j + 1))]}"

        local -i gap=$((next_window_starttime - window_endtime))
        if [[ $gap -ne $input_gap_ns ]]; then
          if [[ $next_window_starttime -ge $afk_endtime ]]; then
            local -i is_event_in_adjacent_afk=0
            get_is_event_in_adjacent_afk is_event_in_adjacent_afk "$next_window_starttime" "$i" afk_events
            [[ $is_event_in_adjacent_afk -eq 0 ]] && continue
          fi
          get_id window_id "${window_events[j]}"
          get_id next_window_id "${window_events[j + 1]}"

          echo "    gap != required_gap ($((gap / 1000000)) != $input_gap_ms) in ms, prev_window_event_id: $window_id next_window_event_id: $next_window_id"
        fi
      fi

      # no more window events in this afk range, so move to the next one
      [[ $window_endtime -ge $afk_endtime ]] && break
    done
  done
  echo -ne '\n'
  echo "  Finished."
}

declare -i selected_window_bucket_id
declare -i selected_afk_bucket_id
select_bucket_id selected_window_bucket_id "aw-watcher-window" "$input_window_bucket_id" "w"
select_bucket_id selected_afk_bucket_id "aw-watcher-afk" "$input_afk_bucket_id" "a"

if [[ $selected_window_bucket_id -eq $selected_afk_bucket_id ]]; then
  echo "aw-watcher-afk and aw-watcher-window have the same id=$selected_window_bucket_id, and that's not allowed. Exiting"
  exit 1
fi

input_start_period_constraint=
if [[ -v input_start_period ]]; then
  input_start_period_constraint="AND (starttime >= $input_start_period OR endtime >= $input_start_period)"
fi

input_end_period_constraint=
if [[ -v input_end_period ]]; then
  input_end_period_constraint="AND (endtime <= $input_end_period OR starttime <= $input_end_period)"
fi

input_middle_period_constraint=
if [[ -v input_start_period && -v input_end_period ]]; then
  input_middle_period_constraint="OR (endtime >= $input_end_period AND starttime <= $input_start_period)"
fi

load_events_from_db window_events \
  "$selected_window_bucket_id" \
  "$input_start_period_constraint" \
  "$input_end_period_constraint" \
  "$input_middle_period_constraint"

if [[ "${#window_events[@]}" -eq 0 || -z "${window_events[0]}" ]]; then
  echo "No window events in given time range."
  exit 1
fi

load_events_from_db afk_events \
  "$selected_afk_bucket_id" \
  "$input_start_period_constraint" \
  "$input_end_period_constraint" \
  "$input_middle_period_constraint"
if [[ "${#afk_events[@]}" -eq 0 || -z "${afk_events[0]}" ]]; then
  echo "No afk events in given time range."
  exit 1
fi

[[ -v validation_only ]] && validate && exit

declare -i afk_events_total_time
declare -i window_events_in_afk_events_total_time_before_fix
declare -i window_events_in_afk_events_total_time_after_fix
declare -i number_of_updated_window_events
declare -i i
declare -i j
declare -i previous_window_endtime=0
echo "Filling the gaps:"
for i in "${!afk_events[@]}"; do
  declare -i afk_starttime
  declare -i afk_endtime
  get_starttime afk_starttime "${afk_events[$i]}"
  get_endtime afk_endtime "${afk_events[$i]}"
  afk_events_total_time+=$((afk_endtime - afk_starttime))
  first_event_in_afk_found=0
  for (( ; j < ${#window_events[@]}; j += 1)); do
    echo -ne "  afk_event $((i + 1))/${#afk_events[@]}, window_event $((j + 1))/${#window_events[@]}\r"
    window_event_needs_update=0

    get_endtime window_endtime "${window_events[$j]}"
    # skip events that are not/before in the afk range
    [[ $window_endtime -le $afk_starttime ]] && continue
    get_starttime window_starttime "${window_events[$j]}"
    # skip the afk range that has no window events in itself
    [[ $window_starttime -ge $afk_endtime ]] && break

    # just for statistic
    window_starttime_in_afk_before_fix=$((window_starttime > afk_starttime ? window_starttime : afk_starttime))
    window_endtime_in_afk_before_fix=$((window_endtime > afk_endtime ? afk_endtime : window_endtime))
    window_events_in_afk_events_total_time_before_fix+=$((window_endtime_in_afk_before_fix - window_starttime_in_afk_before_fix))

    # align the start time of the first window event in the afk range
    # to the start time of that afk range
    if [[ $first_event_in_afk_found -eq 0 &&
      $window_starttime -ge $afk_starttime ]]; then
      first_event_in_afk_found=1
      afk_starttime_with_gap=$((afk_starttime + input_gap_ns))
      previous_window_endtime_with_gap=$((previous_window_endtime + input_gap_ns))
      # don't align the start time of the first event
      # as we may overlap with an unknown preceeding event
      if [[ $window_starttime -ne $afk_starttime_with_gap &&
        $window_starttime -ne $previous_window_endtime_with_gap &&
        ($j -ne 0 || ! -v input_start_period) ]]; then
        new_window_starttime=$((afk_starttime >= previous_window_endtime ? afk_starttime_with_gap : previous_window_endtime_with_gap))
        if [[ $new_window_starttime -lt $window_endtime ]]; then
          window_event_needs_update=1
          window_starttime=$new_window_starttime
        fi
      fi
    fi

    if [[ $((j + 1)) -ge ${#window_events[@]} ]]; then
      # don't align the end time of the last event
      # as we may overlap with an unknown following event
      if [[ $window_endtime -lt $afk_endtime && ! -v input_end_period ]]; then
        afk_endtime_with_gap=$((afk_endtime - input_gap_ns))
        if [[ $afk_endtime_with_gap -gt $window_starttime ]]; then
          window_event_needs_update=1
          window_endtime=$afk_endtime_with_gap
        fi
      fi
    else
      declare -i next_window_starttime
      get_starttime next_window_starttime "${window_events[$((j + 1))]}"
      next_window_starttime_with_gap=$((next_window_starttime - input_gap_ns))
      afk_endtime_with_gap=$((afk_endtime - input_gap_ns))
      new_window_endtime=$((next_window_starttime <= afk_endtime ? next_window_starttime_with_gap : afk_endtime_with_gap))
      # if the window event extends beyond the current afk event
      # then we rather adjust the start time of the next event
      if [[ $window_endtime -le $afk_endtime &&
        $new_window_endtime -gt $window_starttime ]]; then
        window_event_needs_update=1
        window_endtime=$new_window_endtime
      fi
    fi

    if [[ $window_event_needs_update -eq 1 ]]; then
      number_of_updated_window_events+=1
      declare -i event_id
      get_id event_id "${window_events[$j]}"
      sqlite3 "$db_filename" <<-EOF
                           UPDATE events
                           SET starttime = $window_starttime,
                               endtime = $window_endtime
                           WHERE id == $event_id;
EOF

      window_starttime_in_afk_after_fix=$((window_starttime > afk_starttime ? window_starttime : afk_starttime))
      window_endtime_in_afk_after_fix=$((window_endtime > afk_endtime ? afk_endtime : window_endtime))
      window_events_in_afk_events_total_time_after_fix+=$((window_endtime_in_afk_after_fix - window_starttime_in_afk_after_fix))
    else
      window_events_in_afk_events_total_time_after_fix+=$((window_endtime_in_afk_before_fix - window_starttime_in_afk_before_fix))
    fi
    previous_window_endtime=$window_endtime
    # no more window events in this afk range, so move to the next one
    [[ $window_endtime -ge $afk_endtime ]] && break
  done
done
echo -ne '\n'
echo "Statistic:"
echo "  window_events_in_afk_events_total_time_before_fix: $(nanosec2human_readable "${window_events_in_afk_events_total_time_before_fix}")"
echo "  window_events_in_afk_events_total_time_after_fix:  $(nanosec2human_readable "${window_events_in_afk_events_total_time_after_fix}")"
echo "  afk_events_total_time: $(nanosec2human_readable ${afk_events_total_time})"
echo "  number_of_updated_window_events: $number_of_updated_window_events"

load_events_from_db window_events \
  "$selected_window_bucket_id" \
  "$input_start_period_constraint" \
  "$input_end_period_constraint" \
  "$input_middle_period_constraint"

validate
