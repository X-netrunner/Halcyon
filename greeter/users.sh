#!/bin/sh
# Real login accounts, one per line:  name <TAB> full name <TAB> home.  (read by shell.qml; root-owned copy lives in /usr/local/share/halcyon-greeter)
getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)$/ && $7 != "" { split($5, g, ","); printf "%s\t%s\t%s\n", $1, g[1], $6 }'
