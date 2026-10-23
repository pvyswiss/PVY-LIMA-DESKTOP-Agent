#!/bin/sh
# PVY-LIMA-UI OSC7 wrapper - FreeBSD port (BSD-tweaked)
# Original Linux version assumed /bin/bash; FreeBSD pkg installs bash
# at /usr/local/bin/bash. tcsh fallback uses its native cwdcmd hook.
if [ -x /usr/local/bin/bash ]; then
    export PROMPT_COMMAND='printf "\033]7;file://%s%s\a" "$HOSTNAME" "$PWD"'
    exec /usr/local/bin/bash -l
fi
if [ -x /bin/tcsh ]; then
    # tcsh: emit OSC7 via cwdcmd (set by guest-agent setup-osc7 in ~/.tcshrc)
    exec /bin/tcsh -l
fi
exec /bin/sh -l
