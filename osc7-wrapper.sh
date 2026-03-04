#!/bin/bash
export PROMPT_COMMAND='printf "\033]7;file://%s%s\a" "$HOSTNAME" "$PWD"'
exec bash -l
