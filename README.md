# prosody-openbsd

## Description

`prosody-openbsd` is an OpenBSD sandboxing module for Prosody, using
[pledge(2)](https://man.openbsd.org/pledge.2) and
[unveil(2)](https://man.openbsd.org/unveil.2) to minimize process capabilities
and filesystem visibility.

The default set of pledge promises and configuration-derived unveil paths
should suffice for typical Prosody installations from OpenBSD ports.
Bindings to ktrace(2) are included to assist with determining additional
promises and paths to supplement the defaults.

## Installation

The Makefile and default compiler flags assume an OpenBSD build host, and
the default installation paths assume an OpenBSD prosody ports package
using Lua 5.4.

```shell
  $ make install
```

## Configuration

### openbsd.cfg.lua Include

The modules `mod_pledge` and `mod_unveil` *should* be loaded as early as
possible to ensure the process is already sandboxed before any other module
begins loading state. By default Prosody loads modules in mostly random
order (by iterating a hash--not array--built from `modules_enabled` and
other built-in lists), and modules can only force a dependency on
specifically named modules. Fortunately, code can be executed directly from
the configuration file. To ensure early module loading, `openbsd.cfg.lua`
can be `Include`'d from `prosody.cfg.lua`, which will use the Prosody API to
force-load `mod_pledge`, `mod_unveil`, and `mod_ktrace` before any others.

```shell
  $ cp /usr/local/share/examples/prosody/openbsd.cfg.lua /etc/prosody/
```

then add an Include directive to the server-wide settings section of
`/etc/prosody/prosody.cfg.lua`,

```
  Include "openbsd.cfg.lua"
```

Note that `mod_pledge` and `mod_unveil` are enabled by default once loaded
unless explicitly disabled by the `pledge` or `unveil` directives,
respectively. `mod_ktrace` must be explicitly enabled.


### pledge Option (mod_pledge)

String of additional pledge promises, or a boolean feature gate flag.
Defaults to `true`. `pledge` is a global option only.

The default set of built-in pledge promises should be sufficient for typical
installations. `pledge`'d promises are reported in the `info` log at
startup.

#### Examples

```lua
  -- Example 1
  pledge = "exec unix" -- add exec and unix pledge(2) promises

  -- Example 2
  pledge = false -- disable pledge(2) support
```

### unveil Option (mod_unveil)

Table of additional paths to unveil, or a boolean feature gate flag.
Defaults to `true`. The table is a list of path/permission tuples, each
tuple a table with `path` (or `template`) and `permissions` keys. If
undefined, `permissions` defaults to `"r"`. `unveil` is a global option
only.

The default set of unveil paths--including `ssl.key`, `ssl.certificate`,
`ssl.cafile`, and related paths derived from the configuration--should be
sufficient for typical installations. `unveil`'d paths are reported in the
`info` log at startup.

The `template` key can be used instead of `path`, in which case the value is
parsed as a Lua search template, splitting on `;`. If any of the resulting
paths have a substitution component (e.g. `?.lua`), the substitution
component and any trailing subdirectories are dropped. For example,
`/usr/local/share/lua/5.4/?/init.lua` is unveiled as
`/usr/local/share/lua/5.4`).

#### Examples

```lua
  -- Example 1
  unveil = {
    { path = "/var/cache/prosody", permissions = "rwc" },
  }

  -- Example 2
  unveil = false -- disable unveil(2) support
```

### ktrace Option (mod_ktrace)

To enable, set the `ktrace` prosody configuration option to boolean `true`
or to a table value. The allowable table keys are:

* tracefile - ktrace(2) output path string. By default a trace is written
  to `/var/prosody/ktrace-TIMESTAMP-PID.out`

* tracepoints - Space-delimited string list of KTRFAC_* flags (see ktrace(2)).
  The builtin default set of tracepoints can be referenced as `DEFAULT`.
  Preceding a tracepoint flag with `-` causes it to be excluded from
  the set of tracepoints.

* duration - Duration in integer seconds after which tracing is stopped.
  WARNING: A trace cannot be stopped if the process has already been
  pledge'd. Duration is only useful when disabling `mod_pledge` as there is
  no pledge promise for the ktrace capability. If called after pledge'ing,
  the ktrace(2) syscall will trigger SIGKILL (default), or, if the error
  promise has been explicitly pledged, fail with ENOSYS. To avoid an abrupt
  exit with no log message, `mod_ktrace` will check the state of
  `mod_pledge` before attempting to stop a trace.

Both `mod_pledge` and `mod_unveil` implicitly load `mod_ktrace`,
`mod_pledge` to ensure a trace can be started before pledge'ing, and
`mod_unveil` in case a tracefile is specified that is not in a subdirectory
of an unveil'd, writeable path. Tracing is not enabled by default, but when
loaded KTRFAC_USER tracepoints records (see utrace(2)) are injected for
various Prosody events. To prevent loading of `mod_ktrace`, add `ktrace` to
`modules_disabled` in `prosody.cfg.lua`.

#### Examples

```lua
  -- Example 1
  ktrace = true

  -- Example 2
  ktrace = {
    tracefile = "/var/prosody/ktrace.out",
    tracepoints = "DEFAULT -KTRFAC_SYSCALL -KTRFAC_SYSRET",
  }
```

## License

Copyright (c) 2022, 2026 William Ahern &lt;william@25thandClement.com&gt;

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to
deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
IN THE SOFTWARE.
