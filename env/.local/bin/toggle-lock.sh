#!/bin/zsh
state="${XDG_STATE_HOME}/togglemonitorlock"
booleanvalue="false"
if [[ -f ${state} ]]; then
     booleanvalue=$(cat ${state})
fi
if [[ ${booleanvalue} == "true" ]]; then
     wlr-randr --output HDMI-A-1 --pos 2560,0
     echo "false" > ${state}
else
     wlr-randr --output HDMI-A-1 --pos 10000,10000
     echo "true" > ${state}
fi
