# Third-party provenance

The starter was authored for this project. The application bundles the pinned Sparkle updater framework described below; it has no bundled SMC/fan-control binary. The implemented control adapters include MIT-attributed researched ABI/key layouts as documented below.

Apple platform frameworks are referenced through public SDK APIs for observation/UI. Private charge/fan adapter provenance and complete notices are recorded below; consulted-only telemetry sources are listed at the end of this document.

The optional PNG concept references described in `Design/` were generated as original illustrative UI concepts using the built-in image generation tool. They contain demo readings and the owner-confirmed Tilvero identity. They are design references, not extracted Apple system assets or runtime screenshots. Production menu-bar artwork is drawn by code.

Before reusing external source, preserve applicable notices and record the exact source/revision. In particular, do not assume the battery project's bundled GPL SMC binary is covered by its main MIT license, and do not copy unlicensed GlassFan code.

The original Tilvero source, documentation and repository artwork are licensed under GNU GPL version3 only (`GPL-3.0-only`), Copyright (c) 2026 RaNDoM6913. See [LICENSE](LICENSE) and [COPYRIGHT](COPYRIGHT). The third-party MIT notices below remain applicable to their respective material.

## Implemented control adapter provenance (2026-10-27)

The local native/SMC adapters contain researched ABI/key layouts adapted with MIT attribution. Full immutable references, affected local scope and complete notices are retained in [Helper/THIRD_PARTY_NOTICES.md](Helper/THIRD_PARTY_NOTICES.md). Those notices must travel with any redistributed app/source. No GPL smc binary or unlicensed GlassFan implementation is bundled.

The read-only SMC sensor reader (`Sources/PowerTelemetry/SMCSensorReader.swift`, power and battery-temperature keys `PSTR`, `PDTR`, `TB0T`, `TB1T`, `TB2T` only, no write command) reuses the same AppleSMC message layout adapted from the MIT-licensed Stats project (revision and notice as above).

Telemetry normalization was independently implemented from installed IOPS headers and source contracts. Consulted-only sources include Apple PowerManagement `d415e45501842834a280930c3eed9186544a67f0`, Apple XNU `IOPMPowerSource.h`, Ampere `843498d7beb711c0e1b18e48c8520debe67f6e3f`, and Stats `5cf09a8cb0561ff24c28be4e5374d579d0601818`. Source-qualified encodings do not establish sensor calibration or physical hardware-control support.


## Sparkle 2.10.1

The application links and embeds Sparkle 2.10.1, from [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1), exact revision `ab7d71291238df6e0492143b120c9b696a35f603`. The upstream SwiftPM artifact checksum is `4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a`. The following complete upstream license, including its bundled components, is retained verbatim. This license must travel in the application Legal resources and source distribution.

```text
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

```

## vorssaint-utils (design reference, GPL-3.0-or-later)

Source: https://github.com/vorssaint/vorssaint-utils (commit 26d3c9e199eb3afc8f43ce8bd83210b5754421bd),
Copyright (C) 2026 Vorssaint, licensed GPL-3.0-or-later (compatible with this project's GPL-3.0-only terms).

`Sources/TilveroApp/LidSleepOverrideService.swift` follows the approach of its closed-lid Keep Awake
(`KeepAwakeManager.swift`, `SudoersSupport.swift`, `ShellSupport.swift`): the `pmset disablesleep` override,
a one-command sudoers rule granted by uid, proving the passwordless path by using it, a recovery marker written
before the override is set, restore on end/quit/next launch and the bounded sleep request after a restore with
the lid already closed. The code in this repository is written independently; the rule text pattern and the
`SleepDisabled` output check are the same idea and are credited here.
