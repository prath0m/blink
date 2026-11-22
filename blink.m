// blink.m — blink a custom message in Morse code on your Mac's keyboard backlight
//
// Build:  make
// Run:    ./blink "HELLO WORLD"
//
// The whole keyboard backlight flashes: short flash = dot, long flash = dash.
// MacBook keyboards have a single backlight zone, so every key lights together.
//
// The backlight is controlled through Apple's private CoreBrightness framework
// (KeyboardBrightnessClient), loaded at runtime. While the message plays, automatic
// brightness and idle dimming are paused so macOS doesn't fight the blinking. Your
// original brightness and settings are restored at the end, and on Ctrl+C.

#import <Foundation/Foundation.h>

#include <ctype.h>
#include <dlfcn.h>
#include <errno.h>
#include <getopt.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define BLINK_VERSION "1.0.0"

/* ------------------------------------------------------------------------- */
/* CoreBrightness private API                                                */
/* ------------------------------------------------------------------------- */

typedef unsigned long long KeyboardID;

@protocol KeyboardBrightnessClient <NSObject>
// Treated as +0: if the private API ever breaks the "copy" naming rule, the worst
// case is a tiny leak instead of a crash.
- (NSArray<NSNumber *> *)copyKeyboardBacklightIDs NS_RETURNS_NOT_RETAINED;
- (float)brightnessForKeyboard:(KeyboardID)kb;
- (BOOL)setBrightness:(float)level forKeyboard:(KeyboardID)kb;
- (BOOL)setBrightness:(float)level fadeSpeed:(int)speed commit:(BOOL)commit forKeyboard:(KeyboardID)kb;
- (BOOL)isAutoBrightnessEnabledForKeyboard:(KeyboardID)kb;
- (BOOL)enableAutoBrightness:(BOOL)enable forKeyboard:(KeyboardID)kb;
- (BOOL)isIdleDimmingSuspendedOnKeyboard:(KeyboardID)kb;
- (BOOL)suspendIdleDimming:(BOOL)suspend forKeyboard:(KeyboardID)kb;
@end

#define MAX_KEYBOARDS 8
static id<KeyboardBrightnessClient> g_client = nil;
static struct {
    KeyboardID id;
    float brightness;     // original brightness, restored on exit
    bool auto_on;         // auto-brightness was on (we turn it off while blinking)
    bool idle_paused_by_us;
} g_kb[MAX_KEYBOARDS];
static int g_nkb = 0;
static bool g_fade_api = false;
static float g_on_level = 1.0f;

static void set_level(KeyboardID kb, float level, bool commit) {
    if (g_fade_api)
        [g_client setBrightness:level fadeSpeed:0 commit:commit forKeyboard:kb];
    else
        [g_client setBrightness:level forKeyboard:kb];
}

static bool backlight_open(void) {
    if (!dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                RTLD_NOW)) {
        fprintf(stderr, "error: couldn't load CoreBrightness: %s\n", dlerror());
        return false;
    }
    Class cls = NSClassFromString(@"KeyboardBrightnessClient");
    if (!cls) {
        fprintf(stderr, "error: this macOS version has no KeyboardBrightnessClient\n");
        return false;
    }
    g_client = [cls new];
    g_fade_api = [g_client respondsToSelector:@selector(setBrightness:fadeSpeed:commit:forKeyboard:)];
    if (![g_client respondsToSelector:@selector(copyKeyboardBacklightIDs)] ||
        ![g_client respondsToSelector:@selector(brightnessForKeyboard:)] ||
        (!g_fade_api && ![g_client respondsToSelector:@selector(setBrightness:forKeyboard:)])) {
        fprintf(stderr, "error: the keyboard brightness API changed in this macOS version\n");
        return false;
    }

    bool can_auto = [g_client respondsToSelector:@selector(isAutoBrightnessEnabledForKeyboard:)] &&
                    [g_client respondsToSelector:@selector(enableAutoBrightness:forKeyboard:)];
    bool can_idle = [g_client respondsToSelector:@selector(isIdleDimmingSuspendedOnKeyboard:)] &&
                    [g_client respondsToSelector:@selector(suspendIdleDimming:forKeyboard:)];

    for (NSNumber *n in [g_client copyKeyboardBacklightIDs]) {
        if (g_nkb == MAX_KEYBOARDS) break;
        KeyboardID kb = n.unsignedLongLongValue;
        g_kb[g_nkb].id = kb;
        g_kb[g_nkb].brightness = [g_client brightnessForKeyboard:kb];
        g_kb[g_nkb].auto_on = can_auto && [g_client isAutoBrightnessEnabledForKeyboard:kb];
        g_kb[g_nkb].idle_paused_by_us = false;

        // Stop the light sensor and the "turn off after inactivity" timer from
        // changing the backlight mid-message.
        if (g_kb[g_nkb].auto_on) [g_client enableAutoBrightness:NO forKeyboard:kb];
        if (can_idle && ![g_client isIdleDimmingSuspendedOnKeyboard:kb]) {
            [g_client suspendIdleDimming:YES forKeyboard:kb];
            g_kb[g_nkb].idle_paused_by_us = true;
        }
        g_nkb++;
    }
    if (g_nkb == 0) {
        fprintf(stderr, "error: no keyboard with a backlight was found\n");
        return false;
    }
    return true;
}

static void backlight(bool on) {
    for (int i = 0; i < g_nkb; i++) set_level(g_kb[i].id, on ? g_on_level : 0.0f, false);
}

static void backlight_close(void) {
    for (int i = 0; i < g_nkb; i++) {
        set_level(g_kb[i].id, g_kb[i].brightness, true);
        if (g_kb[i].auto_on) [g_client enableAutoBrightness:YES forKeyboard:g_kb[i].id];
        if (g_kb[i].idle_paused_by_us) [g_client suspendIdleDimming:NO forKeyboard:g_kb[i].id];
    }
    g_nkb = 0;
}

/* ------------------------------------------------------------------------- */
/* Morse table                                                               */
/* ------------------------------------------------------------------------- */

static const struct { char c; const char *code; } MORSE[] = {
    {'A', ".-"},     {'B', "-..."},   {'C', "-.-."},   {'D', "-.."},    {'E', "."},
    {'F', "..-."},   {'G', "--."},    {'H', "...."},   {'I', ".."},     {'J', ".---"},
    {'K', "-.-"},    {'L', ".-.."},   {'M', "--"},     {'N', "-."},     {'O', "---"},
    {'P', ".--."},   {'Q', "--.-"},   {'R', ".-."},    {'S', "..."},    {'T', "-"},
    {'U', "..-"},    {'V', "...-"},   {'W', ".--"},    {'X', "-..-"},   {'Y', "-.--"},
    {'Z', "--.."},
    {'0', "-----"},  {'1', ".----"},  {'2', "..---"},  {'3', "...--"},  {'4', "....-"},
    {'5', "....."},  {'6', "-...."},  {'7', "--..."},  {'8', "---.."},  {'9', "----."},
    {'.', ".-.-.-"}, {',', "--..--"}, {'?', "..--.."}, {'\'', ".----."}, {'!', "-.-.--"},
    {'/', "-..-."},  {'(', "-.--."},  {')', "-.--.-"}, {'&', ".-..."},  {':', "---..."},
    {';', "-.-.-."}, {'=', "-...-"},  {'+', ".-.-."},  {'-', "-....-"}, {'_', "..--.-"},
    {'"', ".-..-."}, {'$', "...-..-"}, {'@', ".--.-."},
};

static const char *morse_for(char c) {
    c = (char)toupper((unsigned char)c);
    for (size_t i = 0; i < sizeof MORSE / sizeof MORSE[0]; i++)
        if (MORSE[i].c == c) return MORSE[i].code;
    return NULL;
}

/* ------------------------------------------------------------------------- */
/* Timing / signals                                                          */
/* ------------------------------------------------------------------------- */

static volatile sig_atomic_t g_stop = 0;
static long g_unit_ms = 150;
static bool g_dry_run = false;

static void on_signal(int sig) { (void)sig; g_stop = 1; }

// Sleep for `units` Morse time units. Returns false if the user pressed Ctrl+C.
static bool wait_units(int units) {
    if (g_stop) return false;
    long ms = units * g_unit_ms;
    struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L}, rem;
    while (nanosleep(&ts, &rem) == -1 && errno == EINTR) {
        if (g_stop) return false;
        ts = rem;
    }
    return !g_stop;
}

static void light(bool on) {
    if (!g_dry_run) backlight(on);
}

/* ------------------------------------------------------------------------- */
/* Playback                                                                  */
/* ------------------------------------------------------------------------- */

// Standard Morse timing: dot = 1 unit, dash = 3, gap inside a letter = 1,
// between letters = 3, between words = 7.
static long message_units(const char *msg) {
    long units = 0;
    bool first = true, word_gap = false;
    for (const char *p = msg; *p; p++) {
        if (isspace((unsigned char)*p)) { word_gap = !first; continue; }
        const char *code = morse_for(*p);
        if (!code) continue;
        if (!first) units += word_gap ? 7 : 3;
        first = false;
        word_gap = false;
        for (const char *s = code; *s; s++) units += (s != code) + (*s == '.' ? 1 : 3);
    }
    return units;
}

// Blink the message once. Returns false if interrupted.
static bool play(const char *msg) {
    bool first = true, word_gap = false;
    for (const char *p = msg; *p; p++) {
        if (isspace((unsigned char)*p)) { word_gap = !first; continue; }
        const char *code = morse_for(*p);
        if (!code) continue;

        if (!first) {
            if (word_gap) printf("     /\n");
            if (!wait_units(word_gap ? 7 : 3)) return false;
        }
        first = false;
        word_gap = false;

        printf("  %c  ", toupper((unsigned char)*p));
        fflush(stdout);
        for (const char *s = code; *s; s++) {
            if (s != code && !wait_units(1)) return false;
            light(true);
            putchar(*s);
            fflush(stdout);
            bool ok = wait_units(*s == '.' ? 1 : 3);
            light(false);
            if (!ok) return false;
        }
        putchar('\n');
    }
    return true;
}

/* ------------------------------------------------------------------------- */
/* main                                                                      */
/* ------------------------------------------------------------------------- */

static void usage(const char *prog) {
    printf("Usage: %s [options] \"your message\"\n"
           "       echo \"your message\" | %s [options]\n\n"
           "Blinks the message in Morse code on the keyboard backlight.\n\n"
           "Options:\n"
           "  -w, --wpm N          speed in words per minute (default 8)\n"
           "  -b, --brightness N   backlight brightness for flashes, 1-100 (default 100)\n"
           "  -r, --repeat N       play N times, 0 = loop until Ctrl+C (default 1)\n"
           "  -n, --dry-run        print the Morse code without blinking anything\n"
           "  -V, --version        print the version\n"
           "  -h, --help           show this help\n",
           prog, prog);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int wpm = 8, repeat = 1, brightness = 100;

        static const struct option opts[] = {
            {"wpm", required_argument, NULL, 'w'},
            {"brightness", required_argument, NULL, 'b'},
            {"repeat", required_argument, NULL, 'r'},
            {"dry-run", no_argument, NULL, 'n'},
            {"version", no_argument, NULL, 'V'},
            {"help", no_argument, NULL, 'h'},
            {NULL, 0, NULL, 0},
        };
        int ch;
        while ((ch = getopt_long(argc, argv, "w:b:r:nVh", opts, NULL)) != -1) {
            switch (ch) {
            case 'w':
                wpm = atoi(optarg);
                if (wpm < 1 || wpm > 60) { fprintf(stderr, "error: --wpm must be 1-60\n"); return 2; }
                break;
            case 'b':
                brightness = atoi(optarg);
                if (brightness < 1 || brightness > 100) { fprintf(stderr, "error: --brightness must be 1-100\n"); return 2; }
                break;
            case 'r':
                repeat = atoi(optarg);
                if (repeat < 0) { fprintf(stderr, "error: --repeat must be >= 0\n"); return 2; }
                break;
            case 'n': g_dry_run = true; break;
            case 'V': printf("blink %s\n", BLINK_VERSION); return 0;
            case 'h': usage(argv[0]); return 0;
            default: usage(argv[0]); return 2;
            }
        }
        g_on_level = brightness / 100.0f;

        // Message: remaining args joined by spaces, or one line from stdin.
        NSMutableString *joined = [NSMutableString string];
        for (int i = optind; i < argc; i++) {
            if (i > optind) [joined appendString:@" "];
            [joined appendString:@(argv[i])];
        }
        if (optind >= argc) {
            char *line = NULL;
            size_t cap = 0;
            if (getline(&line, &cap, stdin) <= 0) { usage(argv[0]); return 2; }
            line[strcspn(line, "\r\n")] = '\0';
            [joined appendString:@(line)];
            free(line);
        }
        const char *msg = joined.UTF8String;

        // Report characters that have no Morse code.
        bool warned = false;
        for (const char *p = msg; *p; p++) {
            if (isspace((unsigned char)*p) || morse_for(*p)) continue;
            if (!warned) { fprintf(stderr, "warning: skipping characters with no Morse code:"); warned = true; }
            if ((unsigned char)*p < 0x80) fprintf(stderr, " '%c'", *p);
            else if (((unsigned char)*p & 0xC0) != 0x80) fprintf(stderr, " (non-ASCII)");
        }
        if (warned) fputc('\n', stderr);

        long units = message_units(msg);
        if (units == 0) { fprintf(stderr, "error: nothing to blink\n"); return 2; }
        g_unit_ms = 1200 / wpm;  // PARIS standard: one unit = 1200 ms / WPM

        if (!g_dry_run && !backlight_open()) return 1;

        struct sigaction sa = {0};
        sa.sa_handler = on_signal;
        sigaction(SIGINT, &sa, NULL);
        sigaction(SIGTERM, &sa, NULL);

        printf("%s \"%s\" on the keyboard backlight at %d WPM (%.1f s per pass)%s\n\n",
               g_dry_run ? "Dry run:" : "Blinking", msg, wpm, units * g_unit_ms / 1000.0,
               repeat == 1 ? "" : ". Ctrl+C to stop.");

        if (!g_dry_run) {  // start from a dark keyboard so the first flash is clear
            light(false);
            wait_units(7);
        }

        for (int pass = 0; (repeat == 0 || pass < repeat) && !g_stop; pass++) {
            if (pass > 0) {
                printf("\n");
                if (!wait_units(14)) break;
            }
            if (!play(msg)) break;
        }

        printf(g_stop ? "\nStopped.\n" : "\nDone.\n");
        if (!g_dry_run) backlight_close();
    }
    return 0;
}
