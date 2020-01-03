#!/bin/bash

export http_proxy=http://127.0.0.1:8118
export https_proxy=http://127.0.0.1:8118

basepath=$(cd `dirname $0`; pwd)

cd $basepath

genpac --format=pac --pac-compress --pac-proxy "SOCKS5 127.0.0.1:1080" --user-rule-from="${basepath}/whitelist" --output="${basepath}/index.html" 
