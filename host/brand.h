/* Every name a person can see, once. C builds its strings from these (adjacent string literals); Swift reads the
   same macros through the bridging header (ios/Henge/Brand.swift); tools/henge-agent.m, built on its own for the
   guest, includes this file too. Each macro is one plain string literal, so that Swift imports it.
   Internal names (henge_vm_*, the folder ios/Henge, settings keys) are not here: nobody sees them. */
#ifndef SOLSTICE_BRAND_H
#define SOLSTICE_BRAND_H

#define SOLSTICE_NAME "Solstice"

/* In macOS: the shared folder in the home folder and the volume's name, the helper and its launchd labels. */
#define SOLSTICE_SHARE_NAME "Solstice"
#define SOLSTICE_AGENT_BINARY "solstice-agent"
#define SOLSTICE_AGENT_LABEL "com.solstice.agent"
#define SOLSTICE_SPINS_LABEL "com.solstice.ticketspins"
#define SOLSTICE_SUPPORT_FOLDER "Solstice"          /* ~/Library/Application Support/<this> */

/* What the helper in macOS and the server (host/share.c) say to each other. */
#define SOLSTICE_URL_PREFIX "/.solstice/"
#define SOLSTICE_HEADER_TOKEN "X-Solstice-Token"
#define SOLSTICE_HEADER_SEQ "X-Solstice-Seq"

/* What macOS shows for the virtual hardware. */
#define SOLSTICE_DEVICE_KEYBOARD "Solstice Keyboard"
#define SOLSTICE_DEVICE_TRACKPAD "Solstice Trackpad"
#define SOLSTICE_DEVICE_POINTER "Solstice Pointer"
#define SOLSTICE_DEVICE_DISPLAY "Solstice display"
#define SOLSTICE_DEVICE_DISK_ID "solstice-disk"
#define SOLSTICE_HOSTNAME "solstice"

/* Files in the app's Documents folder. */
#define SOLSTICE_LOG_FILE "solstice.log"
#define SOLSTICE_LOG_PREV_FILE "solstice-prev.log"
#define SOLSTICE_NATIVE_LOG_FILE "solstice-native.log"
#define SOLSTICE_NATIVE_LOG_PREV_FILE "solstice-native-prev.log"
#define SOLSTICE_ENV_FILE "solstice-env.txt"
#define SOLSTICE_STREAM_FILE "solstice-stream.log"  /* tools/solstice-log-listen.py's default */

/* Earlier names, only so that Set Up can remove what an earlier version put into a Mac, and so that the server
   can tell an earlier helper to run Set Up again. Nothing else may use them. */
#define SOLSTICE_OLD_URL_PREFIX "/.henge/"
#define SOLSTICE_OLD_AGENT_LABEL "com.henge.agent"
#define SOLSTICE_OLD_SPINS_LABEL "com.henge.ticketspins"
#define SOLSTICE_OLD_AGENT_BINARY "henge-agent"
#define SOLSTICE_OLD_SUPPORT_FOLDER "Henge"
#define SOLSTICE_OLD_SHARE_NAME "Henge"

#endif
