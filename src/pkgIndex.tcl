# pkgIndex.tcl - package index for the mongreldb Tcl client.
#
# Lets callers do:
#   lappend auto_path /path/to/MongrelDB-Tcl/src
#   package require mongreldb
#
# Licensing: MIT OR Apache-2.0.

package ifneeded mongreldb 0.60.3 [list source [file join $dir mongreldb.tcl]]
