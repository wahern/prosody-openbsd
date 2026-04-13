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

### mod_unveil

The module `mod_unveil` *should* be loaded as early as possible to ensure
the process is already sandboxed before any module begins loading state.
Unfortunately, Prosody loads modules in mostly random order (by iterating a
hash--not array--built from `modules_enabled` and other built-in lists).
Fortunately, code can be executed directly from the configuration file. In
case future changes are required to ensure an early module loading, this
code can be `Include`'d from `prosody.cfg.lua`.

```shell
  $ cp /usr/local/share/examples/prosody/openbsd.cfg.lua /etc/prosody/
  $ echo 'Include "openbsd.cfg.lua"' >> /etc/prosody/prosody.cfg.lua
```

`Include`'ing `openbsd.cfg.lua` loads `mod_unveil`, enabling `pledge` and
`unveil` restrictions by default.

### pledge Option

String of additional pledge promises, or a boolean feature gate flag.
Defaults to `true`. `pledge` is a global option only.

The default set of built-in pledge promises should be sufficient for typical
installations. `pledge`'d promises are reported in the `info` log at
startup.

NB: In the future the pledge component will be split off into a separate
module, mod_pledge.

#### Examples

```lua
  -- Example 1
  pledge = "exec unix" -- add exec and unix pledge(2) promises

  -- Example 2
  pledge = false -- disable pledge(2) support
```

### unveil Option

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

### mod_ktrace

To enable, set the `ktrace` prosody configuration option to boolean `true`
or to a table value. The allowable table keys are:

* tracefile - ktrace(2) output path string. By default a trace is written
  to `/var/prosody/ktrace-TIMESTAMP-PID.out`

* tracepoints - Space-delimited string list of KTRFAC_* flags (see ktrace(2)).
  The builtin default set of tracepoints can be referenced as `DEFAULT`.
  Preceding a tracepoint flag with `-` causes it to be excluded from
  the set of tracepoints.

* duration - Duration in integer seconds after which tracing is stopped.
  WARNING: Do not use if pledge is enabled as the call to stop the trace
  occurs after pledge'ing and will fail, killing the process (unless the
  error promise is pledged). No pledge promises enable the ktrace
  capability.

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
