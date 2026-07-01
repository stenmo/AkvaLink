# Prebuilt firmware drop for the NORA-W40 Matter Thermometer.
#
# After running `build.cmd build` (or `build.sh build`), four `.bin` files
# land here:
#
#     bootloader.bin                  → flashed at 0x00000
#     partition-table.bin             → flashed at 0x08000
#     ota_data_initial.bin            → flashed at 0x0F000
#     aqualink.bin                    → flashed at 0x20000  (factory app slot)
#
# The flash scripts (flash.cmd / flash.sh) hardcode those four offsets to
# match `partitions.csv` in the project root. If you change the partition
# layout, update both.
#
# This folder is gitignored *except* for this README — treat it as a build
# artifact / hand-off bucket, not a place to commit binaries.
