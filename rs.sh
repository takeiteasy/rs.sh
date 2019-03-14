#!/usr/bin/env sh

function is_valid_json {
	if echo "$1" | jq -e . >/dev/null 2>&1; then
		return 0
	else
		return 1
	fi
}

function is_rss {
	if echo "$1" | jq -e ".rss.channel" &>/dev/null ; then
		if [ $(echo "$1" | jq ".rss.channel.item | length" 2>&1) -eq $(echo "$1" | jq '.rss.channel.item[].pubDate' 2>&1 | wc -l) ]; then
			return 0
		else
			return 1
		fi
	else
		return 1
	fi
}

function is_mrss {
	if echo "$1" | jq -e ".feed" &>/dev/null; then
		if [ $(echo "$1" | jq ".feed.entry | length" 2>&1) -eq $(echo "$1" | jq '.feed.entry[].published' 2>&1 | wc -l) ]; then
			return 0
		else
			return 1
		fi
	else
		return 1
	fi
}

function is_feed {
	xml="$(echo "$1" | tr '\r\n' ' ' | xml2json)"
	if [ $? != 0 ]; then
		return 1
	elif ! is_valid_json "$xml"; then
		return 1
	elif is_rss "$xml"; then
		return 0
	elif is_mrss "$xml"; then
		return 0
	else
		return 1
	fi
}

function try_feed {
	out=$(curl -s "$1")
	if [ $? != 0 ]; then
		echo "ERROR: cURL failed to get \"$1\""
		return 1
	fi
	if ! is_feed "$out"; then
		echo "ERROR: \"$1\" is not a valid feed"
		return 1
	fi
	return 0
}

function add_feed {
	if ! echo "$1" | grep -qoP '^(http(s)?:\/\/.)?(www\.)?[-a-zA-Z0-9@:%._\+~#=]{2,256}\.[a-z]{2,6}\b([-a-zA-Z0-9@:%_\+.~#?&//=]*)$'; then
		echo "ERROR: Invalid URL \"$1\""
		return 1
	fi

	if [ ! -e ~/.rss.json ] || [ ! -s ~/.rss.json ]; then
		conf='{ "feeds": [] }'
	else
		conf=$(cat ~/.rss.json)
	fi

	if ! try_feed "$1"; then
		echo "ERROR: Invalid feed \"$1\""
		return 1
	fi

	if echo "$conf" | jq '.feeds[].url' | grep -q "$1"; then
		echo "ERROR: ~/.rss.json already contins \"$1\""
		return 1
	fi

	cp ~/.rss.json ~/.rss.json.bak
	echo "$conf" | jq -M ".feeds[.feeds | length] |= . + {\"url\": \""$1\"", \"shell\": \"\", \"last\": $(date +%s)}" > ~/.rss.json
}

function test_feed {
	printf "$1: "
	if try_feed "$1"; then
		echo "OK"
		return 0
	else
		echo "Invalid"
		return 1
	fi
}

function send_alert_rss {
	ANSWER="$(alerter -subtitle "New RSS feed" -title "$(echo "$1" | jq -r '.title')" -message "$(echo "$1" | jq -r '.description')" -appIcon ~/.rss.png)" 
	case $ANSWER in
		"@CONTENTCLICKED" | "@CLOSED") exit 1 ;;
		"@ACTIONCLICKED")
			open "$(echo "$1" | jq -r '.link')"
			exit 0
			;;
	esac
}

function send_alert_mrss {
	ANSWER="$(alerter -subtitle "New MRSS feed" -title "$(echo "$1" | jq -r '.author.name')" -message "$(echo "$1" | jq -r '.title')" -appIcon ~/.rss.png -contentImage "$(echo "$1" | jq -r '.["media:group"]["media:thumbnail"]["@url"]')")" 
	case $ANSWER in
		"@CONTENTCLICKED" | "@CLOSED") exit 1 ;;
		"@ACTIONCLICKED")
			open "$(echo "$1" | jq -r '.link["@href"]')"
			exit 0
			;;
	esac
}

function import_opml {
	js=$(cat "$1" | tr '\r\n' ' ' | xml2json)
	if [ $? != 0 ] || ! is_valid_json "$js"; then
		echo "ERROR: File \"$1\" not valid XML"
		return 1
	fi
	if ! echo "$js" | jq -e ".opml.body.outline" &>/dev/null; then
		echo "ERROR: File \"$1\" not valid OPML #2"
		return 1
	fi
	if [ ! $(echo "$js" | jq ".opml.body.outline.outline | length" 2>&1) -eq $(echo "$js" | jq '.opml.body.outline.outline[]["@xmlUrl"]' 2>&1 | wc -l) ]; then
		echo "ERROR: File \"$1\" not valid OPML #2"
		return 1
	fi

	n=$(echo "$js" | jq ".opml.body.outline.outline | length")
	for ((i=0;i<$n;i++)) do
		url=$(echo "$js" | jq -Mr ".opml.body.outline.outline[$i][\"@xmlUrl\"]")
		printf "$url: "
		if add_feed "$url"; then
			echo "OK"
		fi
	done
}

case "$1" in
	add) handle_func="add_feed" ;;
	fix)
		if [ ! -e ~/.rss.json ] || [ ! -s ~/.rss.json ]; then
			echo "ERROR: ~/.rss.json doesn't exist or is empty"
			exit 1
		fi

		js=$(cat ~/.rss.json)
		if ! is_valid_json "$js"; then
			mv ~/.rss.json ~/invalid_rss_conf.json
			echo "ERROR: ~/.rss.json is not valid JSON"
			exit 1
		fi

		if [ ! $(echo "$js" | jq '.feeds[].url' 2>&1 | wc -l) -eq $(echo "$js" | jq '.feeds[].last' 2>&1 | wc -l) ]; then
			mv ~/.rss.json ~/invalid_rss_conf.json
			echo "ERROR: ~/.rss.json is malformed or corruped"
			exit 1
		fi

		conf='{ "feeds": [] }'
		n=$(echo "$js" | jq '.feeds | length')
		for ((i=0;i<$n;i++)) do
			item=$(echo "$js" | jq -Mr ".feeds[$i]")
			url=$(echo "$item" | jq -Mr '.url')
			printf "$url: "
			if try_feed "$url"; then
				conf=$(echo "$conf" | jq -M ".feeds[.feeds | length] |= . + $item")
				echo "OK"
			fi
		done

		cp ~/.rss.json ~/.rss.json.bak
		echo "$conf" > ~/.rss.json
		echo
		diff ~/.rss.json.bak ~/.rss.json
		exit 0
		;;
	update)
		conf=$(cat ~/.rss.json)
		cp ~/.rss.json.bak ~/.rss.json

		n=$(echo "$conf" | jq '.feeds | length')
		for ((i=0;i<$n;i++)) do
			url=$(echo "$conf" | jq -r ".feeds[$i].url")
			js=$(curl -s "$url" | tr '\r\n' ' ' | xml2json)
			if [ $? != 0 ] || ! is_valid_json "$js"; then
				echo "ERROR: Failed to get \"$url\""
				continue
			elif is_mrss "$js"; then
				is_mrss=true
				send_alert_fn="send_alert_mrss"
			else
				is_mrss=false
				send_alert_fn="send_alert_rss"
			fi

			last=$(echo "$conf" | jq -r ".feeds[$i].last")
			if [ "$is_mrss" = true ]; then
				nn=$(echo "$js" | jq -r '.feed.entry | length')
			else
				nn=$(echo "$js" | jq -r '.rss.channel.item | length')
			fi

			for ((ii=0;ii<$nn;ii++)) do
				if [ "$is_mrss" = true ]; then
					d=$(gdate --date="$(echo "$js" | jq -Mr ".feed.entry[$ii].published")" +%s)
				else
					d=$(gdate --date="$(echo "$js" | jq -Mr ".rss.channel.item[$ii].pubDate")" +%s)
				fi

				if (( $d > $last )); then
					if [ "$is_mrss" = true ]; then
						item=$(echo "$js" | jq -Mr ".feed.entry[$ii]")
					else
						item=$(echo "$js" | jq -Mr ".rss.channel.item[$ii]")
					fi

					$send_alert_fn "$item" & 
					sh -c "$(echo "$conf" | jq -r ".feeds[$i].shell") '$item'" &>/dev/null &
				else
					break
				fi
			done

			conf=$(echo "$conf" | jq ".feeds[$i].last = $(date +%s)")
		done

		echo "$conf" > ~/.rss.json
		exit 0
		;;
	test) handle_func="test_feed" ;;
	import) handle_func="import_opml" ;;
	*)
		echo "ERROR: Unknown argument: \"$1\""
		exit -1
		;;
esac

shift
for var in "$@"
do
	$handle_func "$var"
done
