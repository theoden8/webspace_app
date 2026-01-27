#!/usr/bin/env bash

set -ex

fvm flutter build apk --flavor fmain --release && \
  fvm flutter build apk --flavor fmain --release --split-per-abi && \
  fvm flutter build appbundle --flavor fmain --release && \
  fvm flutter build ipa --release
