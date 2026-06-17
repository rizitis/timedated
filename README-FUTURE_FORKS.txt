 The only thing certain about a person from the moment he comes into this world is that one day he too will die!
Also, the appetite in a person is like the changes in the weather, today we are so fine, tomorrow we are gloomy and melancholic and so on.
So if the good scenario is that I am bored or that I have gone fishing in Crete
and I am not doing anything else, which happens often and I disappear from everything,
here you will find what you need for your fork
You can start from today... :)

=== PO files ===

I don't feel like dealing with the po/system.
I'm giving some useful information for anyone who wants to deal with their own fork in the future to save time.

It consists of:
meson.build -- calls i18n.gettext() (2 lines)
POTFILES.in -- list of files with translatable strings
LINGUAS -- list of languages ​​(only ru_RU.utf8)
timedated.pot -- template
ru_RU_utf8.po -- the Russian translation

Two options:
A) Remove all i18n (clean package):
Delete the entire po/ directory
In the root meson.build remove:
i18n = import('i18n')
subdir('po')
the GETTEXT_PACKAGE defines (project arguments + cdata)
In the code (rcl-main.c) remove:
#include <glib/gi18n-lib.h>
bind_textdomain_codeset(...), textdomain(...)
Change _("...") to plain "..."
In all .c/.h remove #include <glib/gi18n-lib.h>

B) Leave as is (no work):
Harmless, ~few KB Russian .mo
It works, just doesn't offer much.

My honest opinion: Option A is a lot of work with zero functional benefit and risk of introducing bugs. For a package that is stable, it's not worth the risk.

If the Russian .mo bothers you, the simplest solution: empty LINGUAS (remove the ru_RU.utf8 line). Then no translations will be built/installed, but the i18n infrastructure remains for the future without touching any code.

Extending translations Technically easy, but there is a major problem: what will you translate?
As we saw, only 3 strings have _() wrapper in the code (in rcl-main.c):
_("Replace the old daemon")
_("Show extra debugging information")
_("Enable debugging (implies --verbose)")

That's all. That is, each language will translate only these 3 lines of help text. If you add languages ​​as is: Each .po will translate only these 3 lines that appear in timedated --help. Practically useless nobody runs --help on a system daemon
For the translation to make sense, you should first wrap the messages that the user sees with _()  i.e. the D-Bus error messages that appear in the Plasma GUI:
// NOW:
"set-time: Automatic time synchronization is enabled"

// SHOULD BE:
_("set-time: Automatic time synchronization is enabled")

These errors are shown to the user via the Plasma dialog, so their translation makes real sense.

My honest recommendation: It's only worth it if you wrap the user-facing error messages first. Otherwise you're adding languages ​​for 3 useless help lines.


=== wheel group VS root ===

If someone doesn't want the wheel group, they already have the option.
The privileged-group is a meson option, so the user changes it in the build:
GROUP=${GROUP:-wheel}

meson setup build \
--prefix=/usr \
-Dprivileged-group="$GROUP" \
...

Then the user does:
GROUP=root bash timedated.SlackBuild

But think about it practically:
Wheel is the standard group for admin privileges everywhere
If someone sets root, then only root gets auto-authorization,
other users will ask for a password every time (which is the PolKit fallback anyway)
In practice, wheel is the correct default for 99% of users
Important: Even if you leave wheel, a system that has no users in the wheel group will simply ask for a root password via PolKit, it doesn't break anything. Wheel is not restrictive, it's a "fast path" for admins.


=== libversion ===

Why did I delete these 4 lines:
soversion = 3
current = 1
revision = 0
libversion = '@0@.@1@.@2@'.format(soversion, current, revision)

Because libversion is defined but not used anywhere else. It's dead code from the original template.
They had them because the original timedated from Radix cross Linux (Andrey Kosteltsev) probably
started from a template/boilerplate used for projects that build shared libraries.

In the GNOME/GLib world, many projects build .so libraries, and the standard pattern is:
soversion = 3 # ABI version -- changes when compatibility is broken
current = 1 # interface number
revision = 0 # implementation revision
libversion = '3.1.0'

These are then passed to shared_library(..., version: libversion, soversion: soversion) to create e.g. libtimedate.so.3.1.0 with symlink libtimedate.so.3.

Why are they here when they are not needed:
The original developer probably:
Copied meson.build from a library project, or
Initially intended to make the rcl-* code a shared library but ended up making it a daemon only, or
Just left it as "might need it later"

=== Precautionary thinking ===

In order of probability, if the build ever breaks:
PolKit (most likely)
polkit-gobject-1 ≥ 123 is the most fragile. PolKit has changed API historically (e.g. the switch to duktape/JS engine, deprecations). If Slackware upgrades PolKit and changes something in the polkit_authority_* API, your daemon may not build. Checkpoint: the _check_polkit_* functions in rcl-timedate.c.

2. GLib (moderately likely)
GLib often makes deprecations. Because we have GLIB_VERSION_MIN_REQUIRED / MAX_ALLOWED fixed at 2.76, if you use (or the generated code uses) something deprecated, it will throw warnings/errors. Also, gdbus-codegen output changes between GLib versions, the generated code may not match old hand-written code.

3. PCRE2 (low)
Stable API, rarely breaks. You use it very little (only regex matching).

4. gdbus-codegen / Meson (low but sneaky)
If the Meson API or the gnome.gdbus_codegen signature changes (e.g. autocleanup, object_manager options), the build breaks at the code generation stage before it even gets to compilation. This is confusing because the error doesn't point to your own code.

Practical debugging tip:
If it breaks, the error message tells you the stage:
meson setup fails > dependency missing/version (PolKit, GLib, PCRE)
ninja fails on *-generated.c > gdbus-codegen/GLib issue
ninja fails on rcl-*.c > API change (most likely PolKit or GLib deprecation)
link error > missing -lm or some lib

Keep date-based releases, good idea to note in NEWS which GLib/PolKit versions each release was tested with so if it breaks later, you know the baseline that was working.
I didn't do it because I'm bored :D

=== max versions inside? is that wrong? ===

Ιt's not wrong, it's intentional. Look:
common_cflags = cc.get_supported_arguments([
'-DGLIB_VERSION_MIN_REQUIRED=' + glib_version_def,
'-DGLIB_VERSION_MAX_ALLOWED=' + glib_version_def,
])

Both are fixed at 2.76.
This doesn't mean that the daemon won't run with a newer GLib. It means something more subtle:
GLIB_VERSION_MAX_ALLOWED = 2.76 tells the compiler:
"If I use a GLib API that was added after 2.76, issue a warning."

It's a compile-time guard, not a runtime restriction.
The purpose: it protects you from accidentally using new APIs that won't exist on systems with old GLib. This way your code remains compatible with the minimum you declare (2.76).

Is it wrong? No, it's best practice for portable code.
But: Possible problem:
Because MAX_ALLOWED == MIN_REQUIRED == 2.76
if the generated code from a newer gdbus-codegen uses an API > 2.76, you will get deprecation warnings in the build. With warning_level=1 these are just warnings (they don't break the build), but if someone ever sets
werror=true, it will break.
If you want to relax it so that it follows the installed GLib, you could raise glib_min_version to something more recent (e.g. the one in the latest Slackware-stable release) this reduces portability but for Slackware-current which almost always has the latest GLib, it is safe.

My suggestion:
Does it work? Then leave it as is. It works, builds, and protects you.
MAX_ALLOWED doesn't limit the runtime it just keeps you disciplined in compiling ;)
