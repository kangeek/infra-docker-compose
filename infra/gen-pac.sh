#!/bin/bash

export http_proxy=http://127.0.0.1:8118
export https_proxy=http://127.0.0.1:8118

basepath=$(cd `dirname $0`; pwd)

cd $basepath
curl -s -L https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt > gfwlist.txt

genpac --pac-proxy "SOCKS5 proxy.example.com:1080" --gfwlist-proxy="SOCKS5 127.0.0.1:1080" --output="${basepath}/index.html" --user-rule-from="${basepath}/user-rules.txt" --gfwlist-local="gfwlist.txt"

rm gfwlist.txt
