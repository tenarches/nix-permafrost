# Naming for the virtiofs shares that carry host dot directories into the guest.
#
# Not a module — imported directly by the guest launch modules and by the runner
# script, which is the point: all three used to spell this hash out inline and a
# typo in any one of them would have produced a share the guest mounts nowhere.
{
  # A virtiofs tag is capped at 36 characters, and the guest paths are longer
  # than that once they are nested (.local/share/crush). Hash instead, so the tag
  # is fixed-width and derived from the one field that is unique per share.
  tag = share: "p_" + builtins.substring 0 30 (builtins.hashString "md5" share.guest);
}
