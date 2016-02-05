#!/bin/bash
# Testing workflow
find src '(' -name '*.coffee1' -or -name '*.ts1' -or -name '*.ts' -or -name '*.js' ')' -not -name fallback.ts -delete
rm -f *-errors.txt
