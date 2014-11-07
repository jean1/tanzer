package provide tanzer::file 0.1

##
# @file tanzer/file.tcl
#
# Static file service
#

package require tanzer::response
package require tanzer::error

package require fileutil::magic::mimetype
package require TclOO
package require sha1

namespace eval ::tanzer::file {}

proc ::tanzer::file::mimeType {path} {
    set mimeType [lindex [::fileutil::magic::mimetype $path] 0]

    switch -glob -nocase $path {
        *.txt  { return "text/plain" }
        *.htm -
        *.html { return "text/html" }
        *.css  { return "text/css" }
        *.png  { return "image/png" }
        *.jpg -
        *.jpeg { return "image/jpeg" }
        *.gif  { return "image/gif" }
    }

    return "application/octet-stream"
}

##
# An object representing an open, servable file.
#
::oo::class create ::tanzer::file

##
# Open a file at `$newPath`, passing information returned from `[file stat]`
# as a list in `$newSt`, and a list of key-value configuration pairs in
# `$newConfig`.
#
# Configuration values required in `$newConfig`:
#
# * `readsize`
# 
#   The number of bytes of a file to read at a time.
#
::oo::define ::tanzer::file constructor {newPath newSt newConfig} {
    my variable config path fh st etag

    set required {
        readsize
    }

    foreach requirement $required {
        if {[dict exists $newConfig $requirement]} {
            set config($requirement) [dict get $newConfig $requirement]
        } else {
            error "Required configuration value $requirement not provided"
        }
    }

    set       path $newPath
    set       etag {}
    array set st   $newSt

    if {$st(type) ne "file"} {
        error "Unsupported operation on file of type $st(type)"
    }

    set fh [open $newPath]

    fconfigure $fh \
        -translation binary \
        -buffering   none \
        -blocking    1
}

::oo::define ::tanzer::file destructor {
    my close
}

##
# Close the file channel held by the current ::tanzer::file object.
#
::oo::define ::tanzer::file method close {} {
    my variable fh

    if {$fh ne {}} {
        ::close $fh
    }
}

##
# Return the MIME type of the current file.
#
::oo::define ::tanzer::file method mimeType {} {
    my variable path

    return [::tanzer::file::mimeType $path]
}

##
# Return an RFC 2616 Entity Tag describing the current file.
#
::oo::define ::tanzer::file method etag {} {
    my variable path st etag

    if {$etag ne {}} {
        return $etag
    }

    return [set etag [::sha1::sha1 -hex [concat \
        $path $st(mtime) $st(ino)]]]
}

##
# Returns true if the RFC 2616 Entity Tag specified in `$etag` matches the
# Entity Tag of the current file.
#
::oo::define ::tanzer::file method entityMatches {etag} {
    if {[regexp {^"([^\"]+)"$} $etag {} quoted]} {
        set etag $quoted
    }

    return [expr {$etag eq "*" || $etag eq [my etag]}]
}

##
# Returns true if the current file modification time matches the RFC 2616
# timestamp provided in `$rfc2616`.
#
::oo::define ::tanzer::file method entityNewerThan {rfc2616} {
    my variable st

    return [expr {$st(mtime) > [::tanzer::date::epoch $rfc2616]}]
}

##
# Returns false if the ::tanzer::request object in `$request` lists an
# `If-Match:` header value that does not match the RFC 2616 Entity Tag of the
# current file.  Otherwise, returns true.
#
::oo::define ::tanzer::file method match {request} {
    if {![$request headerExists If-Match]} {
        return 1
    }

    return [my entityMatches [$request header If-Match]]
}

##
# Returns false if the ::tanzer::request object in `$request` lists an
# `If-None-Match:` header value that matches the RFC 2616 Entity Tag of the
# current file.  Otherwise, return true.
#
::oo::define ::tanzer::file method noneMatch {request} {
    if {![$request headerExists If-None-Match]} {
        return 1
    }

    return [expr {![my entityMatches [$request header If-None-Match]]}]
}

##
# Returns false if the ::tanzer::request object in `$request` lists an
# `If-Modified-Since:` header value that is newer than the modification time of
# the current file.  Otherwise, returns true.
#
::oo::define ::tanzer::file method modifiedSince {request} {
    if {![$request headerExists If-Modified-Since]} {
        return 1
    }

    return [my entityNewerThan [$request header If-Modified-Since]]
}

##
# Returns false if the ::tanzer::request object in `$request` lists an
# `If-Unmodified-Since:` header value that is older than the modification time
# of the current file.  Otherwise, returns true.
#
::oo::define ::tanzer::file method unmodifiedSince {request} {
    if {![$request headerExists If-Unmodified-Since]} {
        return 1
    }

    return [expr {![my entityNewerThan [$request header If-Unmodified-Since]]}]
}

::oo::define ::tanzer::file method mismatched {} {
    return 0
}

##
# Used as a callback for `write` events generated by `[fileevent]` on a client
# channel.  Calls ::tanzer::session::pipe to shuffle data from the file handle
# to the client socket.
#
::oo::define ::tanzer::file method stream {event session} {
    my variable fh

    set sock [$session sock]

    foreach event {readable writable} {
        fileevent $sock $event {}
    }

    fcopy $fh $sock -command [list apply {
        {session copied args} {
            if {[llength $args] > 0} {
                ::tanzer::error throw 500 [lindex $args 0]
            }

            $session nextRequest
        }
    } $session]

    return
}

##
# Generate and return a `[dict]` of headers suitable for creating a response
# to serve the current file.
#
::oo::define ::tanzer::file method headers {} {
    my variable st

    set headers [dict create]

    dict set headers Content-Type   [my mimeType]
    dict set headers Content-Length $st(size)
    dict set headers Etag           "\"[my etag]\""
    dict set headers Accept-Ranges  "bytes"
    dict set headers Last-Modified  [::tanzer::date::rfc2616 $st(mtime)]

    return $headers
}
