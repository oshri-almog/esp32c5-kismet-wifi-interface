#!/bin/bash
# H7: libwebsockets output on the C remote helper's stderr, over every --connect run of this retest.
. $HOME/e2e/hw3/tools/common.sh
D=$E/h7-stderr; mkdir -p $D; cd $E
FILES=$(ls h1-latency/c-ws-*.out h1-latency/c-tcp-*.out h1-latency/strace/c-ws-*.out h3-kill/*.helper.log \
    h4-busy/*/c*.helper.log h5-btle/remote/c.helper.log h6-login/*/c*.helper.log h8-freq/cremote/*.helper.log \
    h9-regress/cremote*/*.helper.log h2-giveup/remote/c.helper.log 2>/dev/null)
echo "C --connect stderr files: $(echo $FILES | wc -w)" | tee $D/h7.txt
{
echo "--- files and their websocket/tcp kind"
for f in $FILES; do echo "$f"; done
echo "--- notice lines (libwebsockets 'N:' lines, lws_create_context, __lws_lc_tag, getsockopt): count per file"
for f in $FILES; do printf "%3d %s\n" "$(grep -c '\] N: \|^N: \|lws_create_context\|__lws_lc_tag\|getsockopt fd' $f)" "$f"; done
echo "--- every libwebsockets line ('[date] X: ' or 'X: ' with X in E/W/N/I), verbatim, with counts"
cat $FILES | grep -E '^\[[0-9 :./-]+\] [EWNID]: |^[EWN]: ' | sed -E 's/^\[[0-9 :./-]+\] //' | sort | uniq -c | sort -rn
echo "--- all distinct stderr lines, with counts (packets are not printed by the helper)"
cat $FILES | sed -E 's/^\[[0-9 :./-]+\] //; s/[0-9]+ ms/N ms/' | sort | uniq -c | sort -rn | head -80
} | tee -a $D/h7.txt
