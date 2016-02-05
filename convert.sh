#!/bin/bash
set -e -x

./convert-cleanup.sh

old=($(find src -name '*.coffee'))
coffeescript-to-typescript/bin/coffee -cma ${old[@]} &>coffee-to-ts-errors.txt
#find src -name '*.js' -delete  # Why are these generated??  2016-01-29: I assume it's the typescript-property-accumulator pass, now disabled.

# These apply only to the final conversion.
#git rm ${old[@]}
#git add src

# Current testing workflow.  Remove for final conversion.

## TODO: Some exit codes should be fatal.
#tsc $(find src -name '*.ts') &>tsc-errors.txt || echo "exit code $?" >>tsc-errors.txt
