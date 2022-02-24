# prosody-openbsd

## Description

`prosody-openbsd` is an OpenBSD sandboxing module for Prosody, using
[pledge(2)](https://man.openbsd.org/pledge.2) and
[unveil(2)](https://man.openbsd.org/unveil.2) to minimize process capabilities
and filesystem visibility.

## Installation

The Makefile and default compiler flags assume an OpenBSD build host, and
the default installation paths assume an OpenBSD 7.0 Prosody 0.11.13
package.

```shell
  $ make install
```

## Configuration

The module `mod_openbsd` *should* be loaded as early as possible to ensure
the process is already sandboxed before any module begins loading state.
Unfortunately, Prosody loads modules in mostly random order (by iterating a
hash--not array--built from `modules_enabled` and other built-in lists).
Fortunately, code can be executed directly from the configuration file. In
case future changes are required to ensure an early module loading, this
code can be `Include`d from `prosody.cfg.lua`.

```shell
  $ cp /usr/local/share/examples/prosody/openbsd.cfg.lua /etc/prosody/
  $ echo 'Include "openbsd.cfg.lua"' >> /etc/prosody/prosody.cfg.lua
```

## License

Copyright (c) 2022 William Ahern &lt;william@25thandClement.com&gt;

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
