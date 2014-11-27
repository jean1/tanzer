package provide tanzer::server 0.1

##
# @file tanzer/server.tcl
#
# The connection acceptance server
#

package require tanzer::error
package require tanzer::route
package require tanzer::logger
package require tanzer::session
package require TclOO

namespace eval ::tanzer::server {
    variable name    "tanzer"
    variable version "0.1"
}

##
# `::tanzer::server` accepts inbound connections and creates new session
# objects for each connecting client.
#
::oo::class create ::tanzer::server

##
# Create a new server, with optional `$newOpts` list of pairs indicating
# configuration.  Accepted values are:
#
# - `proto`
#
#   The protocol to accept connections for.  Defaults to `http`, but can be
#   `scgi`.
#
# - `readsize`
#
#   Defaults to 4096.  The size of buffer used to read from remote sockets and
#   local files.
# .
#
::oo::define ::tanzer::server constructor {{newOpts {}}} {
    my variable routes config sessions logger

    set opts   {}
    set routes [list]
    set logger ::tanzer::logger::default

    array set config {
        readsize 4096
        proto    "http"
    }

    if {$newOpts ne {}} {
        set opts [dict create {*}$newOpts]
    }

    foreach {key value} $opts {
        if {[array get config $key] ne {}} {
            set config($key) $value
        }
    }

    #
    # If need be, instantiate a logger object, passing configuration directives
    # directly from the caller here as required.
    #
    if {[dict exists $opts logging]} {
        set logger [::tanzer::logger new \
            [set config(logging) [dict get $opts logging]]]
    }

    #
    # Determine if support for the protocol specified at object instantiation
    # time is present.
    #
    set found 0

    set test [format {
        if {$::tanzer::%s::request::proto eq "%s"} {
            set found 1
        }
    } $config(proto) $config(proto)]

    if {[catch $test error]} {
        error "Unsupported protocol $config(proto): $error"
    }

    if {!$found} {
        error "No package found for protocol $config(proto)"
    }
}

::oo::define ::tanzer::server destructor {
    my variable routes sessions

    foreach route $routes {
        $route destroy
    }

    foreach sock [array names sessions] {
        $sessions($sock) destroy
    }
}

##
# Query configuration value `$name` from server, or set configuration for
# `$name` with `$value`.
#
::oo::define ::tanzer::server method config {name {value ""}} {
    my variable config

    if {$value ne ""} {
        set config($name) $value

        return
    }

    return $config($name)
}

::oo::define ::tanzer::server method log {request response} {
    my variable logger

    $logger log $request $response

    return
}

##
# Route a request handler to the server.  Arguments are as follows:
#
# - `$method`
#
#   A non-anchored regular expression performing a case insensitive match on
#   the incoming HTTP request method.  Anchoring is performed by the request
#   route matching engine.
#
# - `$pattern`
#
#   A URI path, containing any number of path components describing named
#   parameters in the `:param` style.  Paths ending with `*` will match any
#   incoming URI path parts before the glob.
#
# - `$host`
#
#   A non-anchored regular expression performing a case insensitive match on
#   the incoming HTTP Host: request header.  Anchoring is performed by the
#   request route matching engine.
#
# - `$args`
#
#   Any number of arguments desribing the request handler to be dispatched
#   for requests that match the route described by an invocation to this
#   method.
#
#   The following arguments will be appended to the script specified in
#   `$args`:
#
#   - An event, `read` or `write`, indicating the session socket is ready to be
#     read from or written to
#
#   - A reference to a `::tanzer::session` object
#
#   - When dispatching a `read` event, a chunk of data read from the request
#     body
#   .
# .
#
::oo::define ::tanzer::server method route {method pattern host args} {
    my variable routes

    lappend routes [::tanzer::route new $method $pattern $host $args]
}

##
# Return a list of the current routed request handlers.
#
::oo::define ::tanzer::server method routes {} {
    my variable routes

    return $routes
}

##
# Make the server completely forget about `$sock`.  The server will forget
# about the session handler associated with the socket.
#
::oo::define ::tanzer::server method forget {sock} {
    my variable sessions

    if {[array get sessions $sock] eq {}} {
        return
    }

    unset sessions($sock)
}

##
# Close socket `$sock`, destroy the associated session handler, and forget
# about the socket and session handler.
#
::oo::define ::tanzer::server method close {sock} {
    my variable sessions

    if {[array get sessions $sock] eq {}} {
        return
    }

    $sessions($sock) destroy

    my forget $sock
}

##
# Serve the error message `$e` for the session associated with `$sock`, and
# immediately end the session and close the socket.
#
::oo::define ::tanzer::server method error {e sock} {
    my variable sessions logger

    set session $sessions($sock)

    #
    # If the session has already sent a response for the current request,
    # then simply log the error and move on.
    #
    if {[$session responded]} {
        $logger err $e

        my close $sock

        return
    }

    if {[::tanzer::error servable $e]} {
        $session response -new [::tanzer::error response $e]
    } else {
        $session response -new \
            [::tanzer::error response [::tanzer::error fatal]]
    }

    set request [$session request]
    set status  [$session response status]

    if {$status >= 500} {
        $logger err $e
    }

    ::tanzer::error try {
        $session respond
        $session nextRequest
    } catch e {
        $logger err $e

        my close $sock
    }

    return
}

##
# The default I/O event handler associated with new connection sockets opened
# by the server.  `$event` is one of `read` or `write`.  Not meant to be called
# directly.
#
::oo::define ::tanzer::server method respond {event sock} {
    my variable sessions

    set session $sessions($sock)

    if {[$session ended]} {
        my close $sock

        return
    }

    ::tanzer::error try {
        $session handle $event
    } catch e {
        my error $e $sock
    }
}

##
# Accepts an inbound connection as a callback to `[socket -server]`.  Creates a
# new ::tanzer::session object associated with `$sock`, and installs the 
# server's default event handler for `$sock` for only `read` events, initially.
#
# Use this method directly if you intend to listen on multiple sockets, a
# different host address, or if you wish to use ::tls::socket to create a
# listener instead.
#
::oo::define ::tanzer::server method accept {sock addr port} {
    my variable config sessions

    fconfigure $sock \
        -translation binary \
        -blocking    0 \
        -buffering   full \
        -buffersize  $config(readsize)

    set sessions($sock) [::tanzer::session new [self] $sock $config(proto)]

    fileevent $sock readable [list [self] respond read $sock]

    return
}

##
# Listen for inbound connections on `$port`, and enter the socket handling
# event loop.  This simply creates a new listener with `[socket -server]` and
# dispatches all inbound connections to ::tanzer::server::accept.
#
# Do not use this if you intend to listen to listen on multiple sockets, or if
# you wish to use TLS.
#
::oo::define ::tanzer::server method listen {port} {
    socket -server [list [self] accept] $port

    vwait forever
}
