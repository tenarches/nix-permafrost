# Runs as a unit in the initrd of the throwaway guest of mapping-smoke.sh, with the share
# mounted at /ws. $1 is the uid base of the slots. Prints one `SMOKE <name>
# <result>` line for each question; the host side checks them.
# A refused call is an answer here, not an error of the unit.
set +e
base="$1"
slot1=$((base + 1))
slot2=$((base + 2))
cd /ws/f-slot1 || { echo "SMOKE cd failed"; echo "SMOKE done"; exit 0; }

# As slot 1: a file, a directory, and a directory inside it.
setpriv --reuid "$slot1" --regid "$slot1" --clear-groups \
  sh -c 'umask 0027; mkdir d && touch f && mkdir d/sub && touch d/sub/g'
if [ -f f ] && [ -d d/sub ] && [ -f d/sub/g ]; then echo "SMOKE slot1-create ok"; else echo "SMOKE slot1-create failed"; fi

# As guest root: a create must be refused, a chown to 0 or outside the range too,
# a chown of an existing file to another slot is allowed.
if touch rootfile 2>/dev/null; then echo "SMOKE root-create allowed"; else echo "SMOKE root-create refused"; fi
setpriv --reuid "$slot1" --regid "$slot1" --clear-groups sh -c 'umask 0027; touch chowned'
if chown 0 chowned 2>/dev/null; then echo "SMOKE root-chown-0 allowed"; else echo "SMOKE root-chown-0 refused"; fi
if chown 5000 chowned 2>/dev/null; then echo "SMOKE root-chown-out-of-range allowed"; else echo "SMOKE root-chown-out-of-range refused"; fi
if chown "$slot2" chowned 2>/dev/null; then echo "SMOKE root-chown-slot2 ok"; else echo "SMOKE root-chown-slot2 failed"; fi
echo "SMOKE done"
