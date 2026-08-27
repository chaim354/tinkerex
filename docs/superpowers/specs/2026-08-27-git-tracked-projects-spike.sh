#!/bin/bash
set -e
SCRATCH="$1"; N="$2"
rm -rf "$SCRATCH/repo"; mkdir -p "$SCRATCH/repo"; cd "$SCRATCH/repo"
git init -q . ; git config gc.auto 0; git config user.email b@t; git config user.name Bot

# A maker project the way the spec routes it: text as CONTENT, binaries as POINTERS.
mkdir -p src include docs config test cad models laser
for i in $(seq 1 22); do printf 'static int f%d(void){\n  return %d;\n}\n' $i $i > src/mod$i.c; done
for i in $(seq 1 12); do printf '#define K%d %d\n' $i $i > include/h$i.h; done
for i in $(seq 1 10); do head -c 1800 /dev/urandom | base64 > docs/note$i.md; done
for i in $(seq 1 8);  do printf 'key%d: value%d\n' $i $i > config/c$i.yml; done
for i in $(seq 1 8);  do printf 'assert f%d\n' $i > test/t$i.rb; done
# LFS-style pointers: 3 lines, ~130 bytes, standing in for STL/STEP/3MF/lbrn2
for i in $(seq 1 18); do
  printf 'version tinkerex/v1\noid sha256:%064d\nsize %d\n' $i $((i*4000000)) > cad/part$i.step.ptr
done
for i in $(seq 1 12); do
  printf 'version tinkerex/v1\noid sha256:%064d\nsize %d\n' $i $((i*9000000)) > models/m$i.stl.ptr
done
git add -A >/dev/null; git commit -qm "initial" --no-gpg-sign

TEXT=($(ls src/*.c include/*.h docs/*.md config/*.yml test/*.rb))
NT=${#TEXT[@]}
for c in $(seq 1 "$N"); do
  # a scan-triggered commit: 1-5 files settled since the last tick
  for k in $(seq 1 $((RANDOM % 5 + 1))); do
    f="${TEXT[$((RANDOM % NT))]}"; echo "// rev $c $k" >> "$f"
  done
  # occasionally a binary is re-saved -> its pointer changes (new content hash)
  if [ $((RANDOM % 6)) -eq 0 ]; then
    p="cad/part$((RANDOM % 18 + 1)).step.ptr"
    printf 'version tinkerex/v1\noid sha256:%064d\nsize 4000000\n' $c > "$p"
  fi
  git add -A >/dev/null; git commit -qm "auto $c" --no-gpg-sign
done
