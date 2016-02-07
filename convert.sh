#!/bin/bash
set -e -x

if [ "$1" == "--debug" ]; then
	maybe_debug=node-debug
else
	maybe_debug=
fi

# I've forgotten this enough times.  Saves a step for new checkouts too.
make -C tests/coffeescript-to-typescript

./convert-cleanup.sh

old=($(find src -name '*.coffee'))
$maybe_debug tests/coffeescript-to-typescript/bin/coffee -cma ${old[@]} &>coffee-to-ts-errors.txt
#find src -name '*.js' -delete  # Why are these generated??  2016-01-29: I assume it's the typescript-property-accumulator pass, now disabled.

# These apply only to the final conversion.
#git rm ${old[@]}
#git add src

# Current testing workflow.  Remove for final conversion.

## TODO: Some exit codes should be fatal.
#tsc $(find src -name '*.ts') &>tsc-errors.txt || echo "exit code $?" >>tsc-errors.txt
