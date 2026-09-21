// cherrytouch - variante dylib, injectee DANS backboardd via ElleKit.
//
// Pourquoi une dylib et plus un daemon autonome : sur iOS 15+, seul le
// processus qui possede le digitizer (backboardd) peut livrer des touches a
// l'app au premier plan. Un process autonome cree bien les evenements et les
// dispatche, mais ils sont ignores (verifie par instrumentation). En etant
// charge dans backboardd, on dispatche depuis le bon contexte, avec les droits
// de backboardd lui-meme, donc sans entitlement a signer de notre cote.
//
// La dylib ouvre un serveur TCP sur 127.0.0.1:8794 depuis un thread detache au
// chargement. Meme protocole que le daemon : une commande JSON par ligne,
// coordonnees normalisees [0,1]. Tout est defensif : rien ici ne doit pouvoir
// faire tomber backboardd, sous peine de respring en boucle.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <mach/mach.h>
#import <mach/mach_time.h>

// --- IOSurface (declarations manuelles : le SDK jailbreak n'a pas le header) --
typedef struct __IOSurface *IOSurfaceRef;
extern IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
extern kern_return_t IOSurfaceLock(IOSurfaceRef buffer, uint32_t options, uint32_t *seed);
extern kern_return_t IOSurfaceUnlock(IOSurfaceRef buffer, uint32_t options, uint32_t *seed);
extern void *IOSurfaceGetBaseAddress(IOSurfaceRef buffer);
extern size_t IOSurfaceGetBytesPerRow(IOSurfaceRef buffer);
extern const CFStringRef kIOSurfaceWidth;
extern const CFStringRef kIOSurfaceHeight;
extern const CFStringRef kIOSurfaceBytesPerElement;
extern const CFStringRef kIOSurfacePixelFormat;
#define kIOSurfaceLockReadOnly 0x00000001

// Capture au niveau du serveur de rendu : rend l'ecran courant dans une
// IOSurface fournie. Reutilisee d'une frame a l'autre, elle n'alloue rien par
// frame, contrairement a _UICreateScreenUIImage (~11 Mo/frame). C'est la base
// d'une capture legere en memoire, indispensable au H.264 sans respring.
extern void CARenderServerRenderDisplay(uint32_t client, CFStringRef display,
                                        IOSurfaceRef surface, int32_t x, int32_t y);
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <pthread.h>
#include <spawn.h>
#include <dlfcn.h>
#include <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>

extern char **environ;

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef double IOHIDFloat;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(
    CFAllocatorRef allocator, uint64_t timeStamp, uint32_t type, uint32_t index,
    uint32_t identity, uint32_t eventMask, uint32_t buttonMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
    IOHIDFloat tipPressure, IOHIDFloat twist, boolean_t range, boolean_t touch, uint32_t options);
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(
    CFAllocatorRef allocator, uint64_t timeStamp, uint32_t index, uint32_t identity,
    uint32_t eventMask, IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
    IOHIDFloat tipPressure, IOHIDFloat twist, boolean_t range, boolean_t touch, uint32_t options);
extern IOHIDEventRef IOHIDEventCreateKeyboardEvent(
    CFAllocatorRef allocator, uint64_t timeStamp, uint16_t usagePage, uint16_t usage,
    boolean_t down, uint32_t flags);
extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, int value);
extern void IOHIDEventSetFloatValue(IOHIDEventRef event, uint32_t field, float value);
extern void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t senderID);
extern uint32_t IOHIDEventGetType(IOHIDEventRef event);
extern uint64_t IOHIDEventGetSenderID(IOHIDEventRef event);
typedef struct __IOHIDServiceClient *IOHIDServiceRef;
typedef void (*IOHIDEventSystemClientEventCallback)(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event);
extern void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef client, IOHIDEventSystemClientEventCallback callback, void *target, void *refcon);
extern void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef client, CFRunLoopRef runLoop, CFStringRef mode);
#define kIOHIDEventTypeDigitizer 11

// Capture de l'ecran depuis le contexte de SpringBoard (fonction privee UIKit).
extern UIImage *_UICreateScreenUIImage(void);

// senderID du vrai service digitizer, vole a un toucher physique. Sans lui, le
// systeme ignore les evenements synthetiques (verifie). Change a chaque reboot.
static uint64_t gSenderID = 0;

// Niveau de pression memoire du systeme : 0 normal, 1 avertissement, 2 critique.
// La capture d'ecran plein format est gourmande ; sur un iPhone deja charge, elle
// peut faire tomber la memoire libre sous le seuil ou iOS tue SpringBoard (le
// "respring" qui ramene au verrouillage). On surveille donc la pression et on
// ralentit le flux quand elle monte, pour ne jamais franchir ce seuil.
static volatile int gMemPressure = 0;

static void start_mem_monitor(void) {
    dispatch_source_t src = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    if (!src) return;
    dispatch_source_set_event_handler(src, ^{
        unsigned long flags = dispatch_source_get_data(src);
        if (flags & DISPATCH_MEMORYPRESSURE_CRITICAL) gMemPressure = 2;
        else if (flags & DISPATCH_MEMORYPRESSURE_WARN) gMemPressure = 1;
        else gMemPressure = 0;
    });
    dispatch_resume(src);
}

#define kIOHIDDigitizerEventRange    0x00000001
#define kIOHIDDigitizerEventTouch    0x00000002
#define kIOHIDDigitizerEventPosition 0x00000004

// Type de transducteur (3e param de IOHIDEventCreateDigitizerEvent).
#define kIOHIDDigitizerTransducerTypeHand   1

// Champ "l'evenement provient de l'ecran integre". Sans lui, iOS ne route pas
// l'evenement comme une vraie touche tactile. Valeur = base digitizer + offset.
#define kIOHIDEventFieldDigitizerIsDisplayIntegrated 0xB0019

// Phases d'un geste : elles n'utilisent pas le meme masque d'evenement.
typedef enum { PHASE_DOWN, PHASE_MOVE, PHASE_UP } TouchPhase;

static const uint16_t kListenPort = 8794;
static const int kMaxFingers = 10;
static IOHIDEventSystemClientRef gClient = NULL;

// Declaration anticipee : wake_screen est defini plus bas (pres de keep_awake)
// mais appele plus haut (commande "wake" dans handle_command).
static void wake_screen(void);

static uint64_t now_ns(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / tb.denom;
}

// Vole le senderID du service digitizer a un vrai toucher physique (une fois
// par session de boot). Sans lui, aucune injection ne prend.
static void sender_callback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event) {
    (void)target; (void)refcon; (void)service;
    if (IOHIDEventGetType(event) != kIOHIDEventTypeDigitizer) return;
    uint64_t sid = IOHIDEventGetSenderID(event);
    // Nos propres evenements injectes portent gSenderID : ils sont ignores ici
    // (sid == gSenderID), donc pas de boucle. Un VRAI toucher porte l'ID reel du
    // digitizer ; s'il differe de ce qu'on avait (ex. valeur restauree perimee
    // apres un reboot), il fait autorite : on met a jour ET on reecrit le fichier
    // pour les prochains rechargements. La capture est ainsi auto-corrective.
    if (sid == 0 || sid == gSenderID) return;
    gSenderID = sid;
    FILE *f = fopen("/var/jb/tmp/cherry-senderid", "w");
    if (f) { fprintf(f, "%llu", (unsigned long long)gSenderID); fclose(f); }
}

// Restaure le senderID capte plus tot dans la meme session de boot. Le senderID
// identifie le service digitizer cote noyau : il ne change qu'au REDEMARRAGE
// COMPLET, pas a un respring ni a un rechargement du tweak. Le relire evite donc
// d'avoir a toucher physiquement l'ecran apres chaque rechargement pour que
// l'injection reprenne, ce qui est indispensable quand on pilote a distance.
static void restore_sender_id(void) {
    if (gSenderID != 0) return;
    FILE *f = fopen("/var/jb/tmp/cherry-senderid", "r");
    if (!f) return;
    unsigned long long v = 0;
    if (fscanf(f, "%llu", &v) == 1 && v != 0) gSenderID = (uint64_t)v;
    fclose(f);
}

static void start_sender_capture(void) {
    // On restaure d'abord le senderID sauvegarde (survie aux resprings), puis on
    // garde la capture live active : un vrai toucher le rafraichit (utile apres
    // un reboot, ou il faut de toute facon un premier contact).
    restore_sender_id();
    // Doit tourner sur un runloop actif : celui du thread principal de SpringBoard.
    dispatch_async(dispatch_get_main_queue(), ^{
        IOHIDEventSystemClientRef c = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        IOHIDEventSystemClientScheduleWithRunLoop(c, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        IOHIDEventSystemClientRegisterEventCallback(c, sender_callback, NULL, NULL);
    });
}

// Construction fidele a zxtouch (IOS13-SimulateTouch), seule combinaison qui
// livre reellement la touche : parent type 3, champs 0xb00xx, senderID du vrai
// digitizer. identite/masque du doigt selon la phase (3=down, 4=move, 2=up).
static void inject_finger(int fingerId, double x, double y, TouchPhase phase) {
    if (!gClient || gSenderID == 0) return;
    if (x < 0) x = 0; if (x > 1) x = 1;
    if (y < 0) y = 0; if (y > 1) y = 1;

    uint32_t fmask; boolean_t range, touch;
    if (phase == PHASE_DOWN)      { fmask = 3; range = 1; touch = 1; }
    else if (phase == PHASE_MOVE) { fmask = 4; range = 1; touch = 1; }
    else                          { fmask = 2; range = 0; touch = 0; }

    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, mach_absolute_time(), 3, 99, 1, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0);
    if (!parent) return;
    IOHIDEventSetIntegerValue(parent, 0xb0019, 1);  // IsDisplayIntegrated
    IOHIDEventSetIntegerValue(parent, 0x4, 1);

    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, mach_absolute_time(), fingerId, 3, fmask,
        x, y, 0, 0, 0, range, touch, 0);
    if (finger) {
        IOHIDEventSetFloatValue(finger, 0xb0014, 0.04f);  // rayon majeur
        IOHIDEventSetFloatValue(finger, 0xb0015, 0.04f);  // rayon mineur
        IOHIDEventAppendEvent(parent, finger, 0);
        CFRelease(finger);
    }

    IOHIDEventSetIntegerValue(parent, 0xb0007, 0x23);
    IOHIDEventSetIntegerValue(parent, 0xb0008, 0x1);
    IOHIDEventSetIntegerValue(parent, 0xb0009, 0x1);

    IOHIDEventSetSenderID(parent, gSenderID);
    IOHIDEventSystemClientDispatchEvent(gClient, parent);
    CFRelease(parent);
}

static void tap(double x, double y) {
    inject_finger(0, x, y, PHASE_DOWN);
    usleep(40 * 1000);
    inject_finger(0, x, y, PHASE_UP);
}

static void swipe(double x1, double y1, double x2, double y2, int ms) {
    if (ms < 16) ms = 16;
    int steps = ms / 8; if (steps < 2) steps = 2;
    inject_finger(0, x1, y1, PHASE_DOWN);
    for (int i = 1; i <= steps; i++) {
        double t = (double)i / steps;
        inject_finger(0, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, PHASE_MOVE);
        usleep((ms * 1000) / steps);
    }
    inject_finger(0, x2, y2, PHASE_UP);
}

// --- clavier -------------------------------------------------------------
//
// Meme principe que le tactile : evenement HID clavier (page 0x07) porte le
// senderID du vrai peripherique, dispatche via le meme client. iOS le traite
// comme un clavier materiel et l'insere dans le champ au premier plan.

#define KB_PAGE 0x07

static void dispatch_key(uint16_t usage, boolean_t down) {
    if (!gClient || gSenderID == 0) return;
    IOHIDEventRef e = IOHIDEventCreateKeyboardEvent(
        kCFAllocatorDefault, mach_absolute_time(), KB_PAGE, usage, down, 0);
    if (!e) return;
    IOHIDEventSetSenderID(e, gSenderID);
    IOHIDEventSystemClientDispatchEvent(gClient, e);
    CFRelease(e);
}

static void press_key(uint16_t usage, bool shift) {
    if (shift) dispatch_key(0xE1, 1);   // Shift gauche
    dispatch_key(usage, 1);
    usleep(5 * 1000);
    dispatch_key(usage, 0);
    if (shift) dispatch_key(0xE1, 0);
    usleep(5 * 1000);
}

// Bouton lateral (power) : evenement HID page Consumer (0x0C), usage Power (0x30),
// meme client / senderID que le tactile et le clavier. Sur un ecran ETEINT, un
// appui court reveille l'appareil quel que soit l'iOS (equivalent d'un vrai appui
// bouton) : c'est la voie de reveil UNIVERSELLE, independante des selecteurs
// SpringBoard qui varient d'un iOS a l'autre. Sur un ecran ALLUME, il l'endormirait :
// l'appelant ne doit l'invoquer que si l'ecran est eteint.
static void press_side_button(void) {
    if (!gClient || gSenderID == 0) return;
    IOHIDEventRef d = IOHIDEventCreateKeyboardEvent(
        kCFAllocatorDefault, mach_absolute_time(), 0x0C, 0x30, 1, 0);
    if (d) { IOHIDEventSetSenderID(d, gSenderID); IOHIDEventSystemClientDispatchEvent(gClient, d); CFRelease(d); }
    usleep(60 * 1000);
    IOHIDEventRef u = IOHIDEventCreateKeyboardEvent(
        kCFAllocatorDefault, mach_absolute_time(), 0x0C, 0x30, 0, 0);
    if (u) { IOHIDEventSetSenderID(u, gSenderID); IOHIDEventSystemClientDispatchEvent(gClient, u); CFRelease(u); }
}

// Traduit un caractere ASCII en (usage HID, shift). Couvre lettres, chiffres et
// la ponctuation utile aux URLs, pseudos, hashtags et legendes. Retourne false
// pour un caractere hors clavier US (accents, emojis) : ceux-la passent par le
// presse-papier (paste).
static bool usage_for_char(unichar c, uint16_t *usage, bool *shift) {
    *shift = false;
    if (c >= 'a' && c <= 'z') { *usage = 0x04 + (c - 'a'); return true; }
    if (c >= 'A' && c <= 'Z') { *usage = 0x04 + (c - 'A'); *shift = true; return true; }
    if (c >= '1' && c <= '9') { *usage = 0x1E + (c - '1'); return true; }
    switch (c) {
        case '0': *usage = 0x27; return true;
        case ' ': *usage = 0x2C; return true;
        case '\n': *usage = 0x28; return true;
        case '\t': *usage = 0x2B; return true;
        case '-': *usage = 0x2D; return true;
        case '_': *usage = 0x2D; *shift = true; return true;
        case '=': *usage = 0x2E; return true;
        case '+': *usage = 0x2E; *shift = true; return true;
        case '[': *usage = 0x2F; return true;
        case '{': *usage = 0x2F; *shift = true; return true;
        case ']': *usage = 0x30; return true;
        case '}': *usage = 0x30; *shift = true; return true;
        case '\\': *usage = 0x31; return true;
        case '|': *usage = 0x31; *shift = true; return true;
        case ';': *usage = 0x33; return true;
        case ':': *usage = 0x33; *shift = true; return true;
        case '\'': *usage = 0x34; return true;
        case '"': *usage = 0x34; *shift = true; return true;
        case '`': *usage = 0x35; return true;
        case '~': *usage = 0x35; *shift = true; return true;
        case ',': *usage = 0x36; return true;
        case '<': *usage = 0x36; *shift = true; return true;
        case '.': *usage = 0x37; return true;
        case '>': *usage = 0x37; *shift = true; return true;
        case '/': *usage = 0x38; return true;
        case '?': *usage = 0x38; *shift = true; return true;
        case '!': *usage = 0x1E; *shift = true; return true;
        case '@': *usage = 0x1F; *shift = true; return true;
        case '#': *usage = 0x20; *shift = true; return true;
        case '$': *usage = 0x21; *shift = true; return true;
        case '%': *usage = 0x22; *shift = true; return true;
        case '^': *usage = 0x23; *shift = true; return true;
        case '&': *usage = 0x24; *shift = true; return true;
        case '*': *usage = 0x25; *shift = true; return true;
        case '(': *usage = 0x26; *shift = true; return true;
        case ')': *usage = 0x27; *shift = true; return true;
    }
    return false;
}

// Tape un texte caractere par caractere. Les caracteres hors clavier US sont
// ignores ici (le paste les gere).
static void type_text(NSString *text) {
    if (!text) return;
    NSUInteger n = text.length;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [text characterAtIndex:i];
        uint16_t usage; bool shift;
        if (usage_for_char(c, &usage, &shift)) press_key(usage, shift);
    }
}

// Colle un texte : le met dans le presse-papier systeme puis injecte Cmd+V.
// Gere tout (accents, emojis, liens), contrairement a la frappe caractere par
// caractere. Le champ doit deja avoir le focus.
static void paste_text(NSString *text) {
    if (!text) return;
    dispatch_sync(dispatch_get_main_queue(), ^{
        [UIPasteboard generalPasteboard].string = text;
    });
    usleep(40 * 1000);
    dispatch_key(0xE3, 1);   // Cmd gauche (GUI)
    dispatch_key(0x19, 1);   // V
    usleep(8 * 1000);
    dispatch_key(0x19, 0);
    dispatch_key(0xE3, 0);
}

// Lit le presse-papier systeme et l'ecrit (UTF-8) dans un fichier, que l'agent
// rapatrie par SSH (comme une capture). Sert la recuperation de la cle 2FA en
// mode creation : le VA tape « Copier la cle » dans Instagram, on relit la valeur
// EXACTE. UIPasteboard doit etre lu sur le thread principal. Ecrit toujours le
// fichier (chaine vide si presse-papier vide) pour que le rapatriement ne boucle
// pas indefiniment cote agent.
static void read_pasteboard(NSString *path) {
    if (!path) path = @"/var/jb/tmp/cherry-pb.txt";
    __block NSString *s = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try { s = [UIPasteboard generalPasteboard].string; }
        @catch (__unused NSException *e) { s = nil; }
    });
    NSData *d = [(s ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    [d writeToFile:path atomically:YES];
}

// Comme read_pasteboard(), mais RENVOIE le contenu (UTF-8) au lieu de l'ecrire
// dans un fichier : l'agent le lit directement sur la connexion 8794 (commande
// "readpbsock"), plus aucun SSH. Jamais nil (NSData vide si presse-papier vide),
// pour que l'agent ne bloque pas.
static NSData *pasteboard_data(void) {
    __block NSString *s = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try { s = [UIPasteboard generalPasteboard].string; }
        @catch (__unused NSException *e) { s = nil; }
    });
    return [(s ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
}

// Vrai seulement quand l'ecran systeme est configure. Juste apres un respring,
// pendant que SpringBoard demarre, +[UIScreen mainScreen] LEVE une exception
// (assertion "UIScreen ... before ..."). Si un client demande un flux ou une
// capture a cet instant precis, laisser l'exception remonter TUE SpringBoard (et
// declenche le safe mode). On gate donc toute capture sur cet etat, et on avale
// l'exception plutot que de faire tomber SpringBoard. Le client reessaiera.
static bool screen_ready(void) {
    @try {
        UIScreen *s = [UIScreen mainScreen];
        return s != nil && s.bounds.size.width > 0;
    } @catch (__unused NSException *e) {
        return false;
    }
}

// Lit les dimensions ecran (pixels) SANS jamais laisser une exception remonter.
// screen_ready() puis un appel direct a +[UIScreen mainScreen] restait une course :
// l'ecran pouvait basculer (verrouillage, transition SpringBoard) entre les deux,
// et l'appel reel levait alors une exception fatale sur le thread de capture. On
// enveloppe donc l'usage lui-meme. Renvoie false si l'ecran n'est pas exploitable.
static bool screen_dims(int *w, int *h, CGFloat *scaleOut) {
    @try {
        UIScreen *s = [UIScreen mainScreen];
        if (s == nil) return false;
        CGFloat scale = s.scale;
        int pw = (int)(s.bounds.size.width * scale);
        int ph = (int)(s.bounds.size.height * scale);
        if (pw <= 0 || ph <= 0) return false;
        if (w) *w = pw;
        if (h) *h = ph;
        if (scaleOut) *scaleOut = scale;
        return true;
    } @catch (__unused NSException *e) {
        return false;
    }
}

// Capture l'ecran et l'ecrit en PNG. _UICreateScreenUIImage doit etre appelee
// sur le thread principal ; on y saute le temps de recuperer l'image.
static void screenshot(NSString *path) {
    if (!screen_ready()) return;
    if (!path) path = @"/var/jb/tmp/cherry-shot.png";
    __block UIImage *img = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        // @try dans le bloc : meme course que screenshot_png/capture_jpeg, une
        // exception de _UICreateScreenUIImage sur le main thread tuerait backboardd.
        @try { img = _UICreateScreenUIImage(); }
        @catch (__unused NSException *e) { img = nil; }
    });
    if (!img) return;
    NSData *png = UIImagePNGRepresentation(img);
    [png writeToFile:path atomically:YES];
}

// Comme screenshot(), mais RENVOIE le PNG plein ecran (nil si capture impossible)
// au lieu de l'ecrire sur disque : l'agent le lit sur la connexion 8794 (commande
// "shotsock"), plus aucun SSH. Meme garde screen_ready() que screenshot() pour ne
// pas tuer SpringBoard pendant son demarrage.
static NSData *screenshot_png(void) {
    if (!screen_ready()) return nil;
    __block UIImage *img = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        // @try DANS le bloc (execute sur la file main de backboardd) :
        // _UICreateScreenUIImage peut lever une exception si l'ecran bascule juste
        // apres screen_ready() (course documentee dans screen_dims). Non attrapee
        // ici, elle remonterait sur le main thread et tuerait backboardd (respring).
        // Meme durcissement que capture_jpeg().
        @try { img = _UICreateScreenUIImage(); }
        @catch (__unused NSException *e) { img = nil; }
    });
    if (!img) return nil;
    return UIImagePNGRepresentation(img);
}

static double num(NSDictionary *d, NSString *k) {
    id v = d[k];
    return [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : 0.0;
}

// Lance une app au premier plan. On passe par les utilitaires du jailbreak
// (sbdidlaunch pour un bundle, uiopen pour un schema d'URL), presents sous
// /var/jb/usr/bin. posix_spawn ne bloque pas SpringBoard : on n'attend pas la
// fin de l'enfant. Aucune dependance a lier, donc rien qui puisse casser le
// chargement de la dylib.
static void spawn_tool(const char *path, const char *arg) {
    if (!path || !arg) return;
    char *argv[] = { (char *)path, (char *)arg, NULL };
    pid_t pid = 0;
    posix_spawn(&pid, path, NULL, NULL, argv, environ);
}

static void launch_app(NSString *bundle, NSString *scheme) {
    if ([bundle isKindOfClass:[NSString class]] && bundle.length) {
        spawn_tool("/var/jb/usr/bin/sbdidlaunch", bundle.UTF8String);
        return;
    }
    if ([scheme isKindOfClass:[NSString class]] && scheme.length) {
        spawn_tool("/var/jb/usr/bin/uiopen", scheme.UTF8String);
    }
}

// Ferme une app par nom de process (killall), SANS SSH (commande "kill"). Deux
// passes, SIGTERM puis SIGKILL, comme l'ancienne voie SSH. posix_spawn ne bloque
// pas backboardd ; l'automatisation appelante laisse ensuite un delai (~2 s) avant
// de relancer l'app, le temps que le killall s'applique.
static void kill_proc(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || !name.length) return;
    const char *n = name.UTF8String;
    const char *killall = "/var/jb/usr/bin/killall";
    char *a1[] = { (char *)killall, (char *)n, NULL };
    pid_t p1 = 0; posix_spawn(&p1, killall, NULL, NULL, a1, environ);
    char *a2[] = { (char *)killall, (char *)"-9", (char *)n, NULL };
    pid_t p2 = 0; posix_spawn(&p2, killall, NULL, NULL, a2, environ);
}

static void handle_command(NSDictionary *cmd) {
    NSString *t = cmd[@"t"];
    if (![t isKindOfClass:[NSString class]]) return;
    if ([t isEqualToString:@"shot"]) {
        screenshot(cmd[@"path"]);
    } else if ([t isEqualToString:@"tap"]) {
        tap(num(cmd, @"x"), num(cmd, @"y"));
    } else if ([t isEqualToString:@"swipe"]) {
        int ms = (int)num(cmd, @"ms"); if (ms <= 0) ms = 250;
        swipe(num(cmd, @"x1"), num(cmd, @"y1"), num(cmd, @"x2"), num(cmd, @"y2"), ms);
    } else if ([t isEqualToString:@"down"]) {
        int id_ = (int)num(cmd, @"id"); if (id_ < 0 || id_ >= kMaxFingers) id_ = 0;
        inject_finger(id_, num(cmd, @"x"), num(cmd, @"y"), PHASE_DOWN);
    } else if ([t isEqualToString:@"move"]) {
        int id_ = (int)num(cmd, @"id"); if (id_ < 0 || id_ >= kMaxFingers) id_ = 0;
        inject_finger(id_, num(cmd, @"x"), num(cmd, @"y"), PHASE_MOVE);
    } else if ([t isEqualToString:@"up"]) {
        int id_ = (int)num(cmd, @"id"); if (id_ < 0 || id_ >= kMaxFingers) id_ = 0;
        inject_finger(id_, num(cmd, @"x"), num(cmd, @"y"), PHASE_UP);
    } else if ([t isEqualToString:@"type"]) {
        id txt = cmd[@"text"];
        if ([txt isKindOfClass:[NSString class]]) type_text(txt);
    } else if ([t isEqualToString:@"paste"]) {
        id txt = cmd[@"text"];
        if ([txt isKindOfClass:[NSString class]]) paste_text(txt);
    } else if ([t isEqualToString:@"readpb"]) {
        // Lit le presse-papier et l'ecrit dans le fichier indique (mode creation).
        read_pasteboard(cmd[@"path"]);
    } else if ([t isEqualToString:@"key"]) {
        id name = cmd[@"key"];
        if ([name isEqualToString:@"enter"] || [name isEqualToString:@"return"]) press_key(0x28, false);
        else if ([name isEqualToString:@"backspace"]) press_key(0x2A, false);
        else if ([name isEqualToString:@"space"]) press_key(0x2C, false);
        else if ([name isEqualToString:@"escape"]) press_key(0x29, false);
    } else if ([t isEqualToString:@"home"]) {
        // Retour a l'ecran d'accueil : geste de balayage depuis le bord bas.
        swipe(0.5, 0.995, 0.5, 0.55, 250);
    } else if ([t isEqualToString:@"launch"]) {
        // Ouvre une app au premier plan (bundle prioritaire, sinon schema d'URL).
        launch_app(cmd[@"bundle"], cmd[@"scheme"]);
    } else if ([t isEqualToString:@"wake"]) {
        // Rallume l'ecran a la demande (avant une automatisation, par ex.).
        wake_screen();
    }
}

// Capture l'ecran en JPEG pour le streaming.
//
// Cle de performance ET de stabilite : ne bloquer le thread principal de
// SpringBoard que le strict minimum. Avant, tout se faisait sur le main thread
// (rendu + aplatissement + encodage, en pleine resolution) : 3 fps et,
// surtout, le watchdog d'iOS finissait par tuer SpringBoard (le fameux
// "respring" en cours d'usage).
//
// Ici, seul _UICreateScreenUIImage tourne sur le main (le rendu UIKit l'exige).
// On y recupere juste le CGImage, puis on quitte le main. La reduction de taille
// et l'encodage JPEG, les operations couteuses, se font sur le thread appelant
// (le thread du flux). CGBitmapContext et ImageIO ne dependent pas de UIKit et
// sont surs hors du main thread.
static NSData *capture_jpeg(int targetWidth, float quality) {
    __block CGImageRef src = NULL;
    dispatch_sync(dispatch_get_main_queue(), ^{
        // Pool dedie : l'UIImage plein ecran (~11 Mo) est liberee des la sortie
        // du bloc. Sans ca, a 10+ captures/s elle s'accumule sur le pool du
        // thread principal jusqu'a la prochaine iteration de son runloop, ce qui
        // provoque un pic memoire et un kill de SpringBoard par iOS.
        @autoreleasepool {
            @try {
                UIImage *img = _UICreateScreenUIImage();
                if (img && img.CGImage) src = CGImageRetain(img.CGImage);
            } @catch (__unused NSException *e) {
                src = NULL;  // ecran pas pret (boot) : on renvoie rien, pas de crash
            }
        }
    });
    if (!src) return nil;

    size_t sw = CGImageGetWidth(src), sh = CGImageGetHeight(src);
    if (targetWidth <= 0 || targetWidth > (int)sw) targetWidth = (int)sw;
    int tw = targetWidth;
    int th = (int)((double)sh * tw / (double)sw);

    static CGColorSpaceRef cs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cs = CGColorSpaceCreateDeviceRGB(); });

    // Contexte reutilise d'une frame a l'autre : sans ca, on allouait puis
    // liberait ~2 Mo par frame, et a 10 fps la pression memoire faisait
    // tuer SpringBoard par le jetsam d'iOS (retour au verrouillage). Le flux
    // est mono-thread, donc pas de concurrence sur ce contexte statique.
    static CGContextRef g_ctx = NULL;
    static int g_w = 0, g_h = 0;
    if (!g_ctx || g_w != tw || g_h != th) {
        if (g_ctx) CGContextRelease(g_ctx);
        g_ctx = CGBitmapContextCreate(NULL, tw, th, 8, 0, cs,
            kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        g_w = tw; g_h = th;
        if (g_ctx) CGContextSetInterpolationQuality(g_ctx, kCGInterpolationLow);
    }
    if (!g_ctx) { CGImageRelease(src); return nil; }

    CGContextDrawImage(g_ctx, CGRectMake(0, 0, tw, th), src);
    CGImageRelease(src);

    CGImageRef scaled = CGBitmapContextCreateImage(g_ctx);
    if (!scaled) return nil;

    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)out, CFSTR("public.jpeg"), 1, NULL);
    if (dest) {
        NSDictionary *opts = @{ (__bridge id)kCGImageDestinationLossyCompressionQuality: @(quality) };
        CGImageDestinationAddImage(dest, scaled, (__bridge CFDictionaryRef)opts);
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    CGImageRelease(scaled);
    return out.length ? out : nil;
}

// IOSurface reutilisee pour la capture au niveau serveur de rendu.
static IOSurfaceRef g_surface = NULL;
static int g_surf_w = 0, g_surf_h = 0;

static IOSurfaceRef ensure_surface(int w, int h) {
    if (g_surface && g_surf_w == w && g_surf_h == h) return g_surface;
    if (g_surface) { CFRelease(g_surface); g_surface = NULL; }
    NSDictionary *props = @{
        (id)kIOSurfaceWidth: @(w),
        (id)kIOSurfaceHeight: @(h),
        (id)kIOSurfaceBytesPerElement: @(4),
        (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
    };
    g_surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    g_surf_w = w; g_surf_h = h;
    return g_surface;
}

// Rend l'ecran dans l'IOSurface reutilisee, puis encode en JPEG (pour le test :
// on verifie que la capture est correcte et legere avant de brancher le H.264).
static NSData *capture_renderserver_jpeg(float quality) {
    int w = 0, h = 0;
    if (!screen_dims(&w, &h, NULL)) return nil;
    IOSurfaceRef surf = ensure_surface(w, h);
    if (!surf) return nil;

    // Le rendu doit se faire sur le thread principal.
    dispatch_sync(dispatch_get_main_queue(), ^{
        CARenderServerRenderDisplay(0, CFSTR("LCD"), surf, 0, 0);
    });

    IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
    void *base = IOSurfaceGetBaseAddress(surf);
    size_t bpr = IOSurfaceGetBytesPerRow(surf);
    static CGColorSpaceRef cs2;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{ cs2 = CGColorSpaceCreateDeviceRGB(); });
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs2,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (ctx) CGContextRelease(ctx);
    IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
    if (!img) return nil;

    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)out, CFSTR("public.jpeg"), 1, NULL);
    if (dest) {
        NSDictionary *o = @{ (__bridge id)kCGImageDestinationLossyCompressionQuality: @(quality) };
        CGImageDestinationAddImage(dest, img, (__bridge CFDictionaryRef)o);
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    CGImageRelease(img);
    return out.length ? out : nil;
}

// Envoie tout le buffer, en gerant les ecritures partielles.
static bool send_all(int fd, const void *data, size_t len) {
    const char *p = (const char *)data;
    while (len > 0) {
        ssize_t w = write(fd, p, len);
        if (w <= 0) return false;
        p += w; len -= (size_t)w;
    }
    return true;
}

// --- streaming H.264 (VideoToolbox, encodeur materiel) --------------------
//
// Chemin leger en memoire : l'ecran est rendu dans une IOSurface REUTILISEE
// (CARenderServerRenderDisplay), enveloppee une fois dans un CVPixelBuffer, et
// encode par l'encodeur H.264 materiel. Aucune allocation de ~11 Mo par frame,
// donc plus de pression memoire ni de respring. Le flux (unites NAL AVCC) part
// vers le navigateur qui decode via WebCodecs.
//
// Trame envoyee : 1 octet type (0=config avcC, 1=keyframe, 2=delta)
//               + 4 octets longueur (big endian) + donnees.

static VTCompressionSessionRef g_vt = NULL;
static CVPixelBufferRef g_pixbuf = NULL;
static volatile int g_h264_fd = -1;   // socket du flux H.264 en cours (-1 = aucun)
static bool g_sent_config = false;

static void h264_send(uint8_t type, const uint8_t *data, size_t len) {
    int fd = g_h264_fd;
    if (fd < 0) return;
    uint8_t hdr[5] = { type, (uint8_t)(len >> 24), (uint8_t)(len >> 16),
                       (uint8_t)(len >> 8), (uint8_t)len };
    if (!send_all(fd, hdr, 5) || !send_all(fd, data, len)) g_h264_fd = -1;
}

static void h264_output_cb(void *refcon, void *srcFrame, OSStatus status,
                           VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
    (void)refcon; (void)srcFrame; (void)flags;
    if (status != noErr || !sample || !CMSampleBufferDataIsReady(sample)) return;

    bool keyframe = false;
    CFArrayRef attachs = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (attachs && CFArrayGetCount(attachs)) {
        CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(attachs, 0);
        keyframe = !CFDictionaryContainsKey(d, kCMSampleAttachmentKey_NotSync);
    }

    // Avant chaque keyframe, on renvoie la config (avcC : SPS + PPS). Ainsi un
    // dashboard qui se connecte en cours de flux peut s'initialiser des la
    // prochaine keyframe (~2 s), sans avoir manque la premiere.
    if (keyframe) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sample);
        const uint8_t *sps = NULL, *pps = NULL;
        size_t sps_len = 0, pps_len = 0;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, &sps, &sps_len, NULL, NULL) == noErr &&
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 1, &pps, &pps_len, NULL, NULL) == noErr &&
            sps_len >= 4) {
            NSMutableData *avcc = [NSMutableData data];
            uint8_t head[6] = { 1, sps[1], sps[2], sps[3], 0xFF, 0xE1 };
            [avcc appendBytes:head length:6];
            uint8_t sl[2] = { (uint8_t)(sps_len >> 8), (uint8_t)sps_len };
            [avcc appendBytes:sl length:2]; [avcc appendBytes:sps length:sps_len];
            uint8_t one = 1; [avcc appendBytes:&one length:1];
            uint8_t pl[2] = { (uint8_t)(pps_len >> 8), (uint8_t)pps_len };
            [avcc appendBytes:pl length:2]; [avcc appendBytes:pps length:pps_len];
            h264_send(0, avcc.bytes, avcc.length);
            g_sent_config = true;
        }
    }

    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sample);
    size_t total = 0; char *ptr = NULL;
    if (bb && CMBlockBufferGetDataPointer(bb, 0, NULL, &total, &ptr) == noErr && ptr) {
        h264_send(keyframe ? 1 : 2, (const uint8_t *)ptr, total);
    }
}

static bool h264_setup(int w, int h, int fps, int bitrate) {
    if (g_vt) return true;
    OSStatus s = VTCompressionSessionCreate(kCFAllocatorDefault, w, h,
        kCMVideoCodecType_H264, NULL, NULL, NULL, h264_output_cb, NULL, &g_vt);
    if (s != noErr || !g_vt) return false;
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    int kf = fps * 2;
    CFNumberRef nkf = CFNumberCreate(NULL, kCFNumberIntType, &kf);
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_MaxKeyFrameInterval, nkf);
    CFRelease(nkf);
    CFNumberRef nbr = CFNumberCreate(NULL, kCFNumberIntType, &bitrate);
    VTSessionSetProperty(g_vt, kVTCompressionPropertyKey_AverageBitRate, nbr);
    CFRelease(nbr);
    VTCompressionSessionPrepareToEncodeFrames(g_vt);
    return true;
}

static void stream_h264_loop(int fd, int fps, int bitrate) {
    if (fps <= 0) fps = 30;
    // Ne JAMAIS toucher l'ecran avant que SpringBoard soit pret : un client (ex.
    // l'agent qui se reconnecte juste apres un respring) peut demander le flux
    // pendant le boot, et +[UIScreen mainScreen] leverait une exception fatale.
    int w = 0, h = 0;
    // Dimensions lues de facon protegee : si l'ecran bascule a cet instant, on
    // abandonne proprement (le client reessaiera) plutot que de tuer SpringBoard.
    if (!screen_dims(&w, &h, NULL)) return;

    // Le CVPixelBuffer est cree par CoreVideo avec un IOSurface adosse
    // (kCVPixelBufferIOSurfacePropertiesKey) : c'est cet IOSurface, compatible
    // avec l'encodeur materiel, que l'on remplit via CARenderServerRenderDisplay.
    // Une IOSurface brute n'etait pas lue correctement par l'encodeur (frames
    // noires). Reutilise d'une frame a l'autre : aucune allocation par frame.
    if (!g_pixbuf) {
        NSDictionary *attrs = @{
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(w),
            (id)kCVPixelBufferHeightKey: @(h),
        };
        if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                (__bridge CFDictionaryRef)attrs, &g_pixbuf) != kCVReturnSuccess)
            return;
    }
    IOSurfaceRef surf = CVPixelBufferGetIOSurface(g_pixbuf);
    if (!surf) return;
    if (!h264_setup(w, h, fps, bitrate)) return;

    g_sent_config = false;
    g_h264_fd = fd;
    double period = 1.0 / fps;
    int64_t frame = 0;
    while (g_h264_fd == fd) {
        @autoreleasepool {
            double t0 = CFAbsoluteTimeGetCurrent();
            dispatch_sync(dispatch_get_main_queue(), ^{
                CARenderServerRenderDisplay(0, CFSTR("LCD"), surf, 0, 0);
            });
            CMTime pts = CMTimeMake(frame, fps);
            VTCompressionSessionEncodeFrame(g_vt, g_pixbuf, pts, kCMTimeInvalid, NULL, NULL, NULL);
            frame++;
            double dt = CFAbsoluteTimeGetCurrent() - t0;
            if (dt < period) usleep((useconds_t)((period - dt) * 1000000.0));
        }
    }
    VTCompressionSessionCompleteFrames(g_vt, kCMTimeInvalid);
}

// Boucle de streaming : chaque frame = 4 octets de longueur (big endian) + JPEG.
// SpringBoard n'est pas sandboxe, il peut donc servir ce flux directement.
//
// On cadence par le temps ECOULE, pas par un sommeil fixe : si une frame prend
// 40 ms a produire, on repart aussitot ; sinon on attend jusqu'a la periode
// cible. On ne cherche donc jamais a depasser le materiel, ce qui evite de
// saturer le main thread (et donc le respring).
// Memoire libre du systeme, en Mo. Appel mach quasi gratuit (~microsecondes),
// donc utilisable a chaque frame.
static double free_mb(void) {
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS)
        return 1e9;
    return (double)vm.free_count * (double)vm_page_size / 1e6;
}

// Seuil de memoire libre sous lequel on NE capture PAS du tout : une seule
// capture plein ecran alloue un gros tampon transitoire ; si la memoire libre
// est deja basse, ce pic suffit a faire tuer SpringBoard par iOS. En dessous du
// seuil, on saute la frame et on laisse la memoire remonter.
#define CAPTURE_FLOOR_MB 70.0

static void stream_loop(int fd, double fps, int width, float quality) {
    if (fps <= 0) fps = 30.0;
    if (!screen_ready()) return;  // SpringBoard pas pret : le client reessaiera
    double base = 1.0 / fps;
    for (;;) {
        @autoreleasepool {
            double t0 = CFAbsoluteTimeGetCurrent();
            double f = free_mb();

            // Ne capturer que si la marge memoire est suffisante ET si le
            // systeme ne signale pas de pression. Sinon on saute la frame.
            NSData *jpeg = nil;
            if (f > CAPTURE_FLOOR_MB && gMemPressure < 2) {
                jpeg = capture_jpeg(width, quality);
            }
            if (jpeg) {
                uint32_t n = (uint32_t)jpeg.length;
                uint8_t hdr[4] = { n >> 24, n >> 16, n >> 8, n };
                if (!send_all(fd, hdr, 4)) return;
                if (!send_all(fd, jpeg.bytes, jpeg.length)) return;
            }

            // Rythme adapte a la marge memoire : plus elle est confortable, plus
            // on va vite ; serree, on espace pour laisser iOS reclamer.
            double eff;
            if (f < CAPTURE_FLOOR_MB || gMemPressure == 2) eff = 0.5;  // on attend
            else if (f > 350 && gMemPressure == 0) eff = base;         // plein regime
            else if (f > 200) eff = 0.12;                              // ~8 fps
            else if (f > 120) eff = 0.22;                              // ~4.5 fps
            else               eff = 0.4;                              // ~2.5 fps

            double dt = CFAbsoluteTimeGetCurrent() - t0;
            if (dt < eff) usleep((useconds_t)((eff - dt) * 1000000.0));
        }
    }
}

static void serve_client(int fd);

// Enveloppe pour pthread_create : sert un client puis se termine.
static void *client_thread(void *arg) {
    int fd = *(int *)arg;
    free(arg);
    serve_client(fd);
    return NULL;
}

static void serve_client(int fd) {
    NSMutableData *buf = [NSMutableData data];
    char chunk[4096];
    for (;;) {
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n <= 0) break;
        [buf appendBytes:chunk length:n];
        for (;;) {
            const char *bytes = (const char *)buf.bytes;
            NSUInteger len = buf.length, nl = NSNotFound;
            for (NSUInteger i = 0; i < len; i++) { if (bytes[i] == '\n') { nl = i; break; } }
            if (nl == NSNotFound) break;
            @autoreleasepool {
                NSData *line = [buf subdataWithRange:NSMakeRange(0, nl)];
                [buf replaceBytesInRange:NSMakeRange(0, nl + 1) withBytes:NULL length:0];
                if (line.length == 0) continue;
                id obj = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
                if ([obj isKindOfClass:[NSDictionary class]]) {
                    NSString *t = obj[@"t"];
                    if ([t isEqualToString:@"stream"]) {
                        // Passe en mode flux continu : ne rend jamais la main.
                        double fps = [obj[@"fps"] respondsToSelector:@selector(doubleValue)] ? [obj[@"fps"] doubleValue] : 30.0;
                        int width = [obj[@"w"] respondsToSelector:@selector(intValue)] ? [obj[@"w"] intValue] : 480;
                        float q = [obj[@"q"] respondsToSelector:@selector(floatValue)] ? [obj[@"q"] floatValue] : 0.4f;
                        stream_loop(fd, fps, width, q);
                        close(fd); return;
                    }
                    if ([t isEqualToString:@"streamh264"]) {
                        // Flux H.264 materiel, leger en memoire (voir stream_h264_loop).
                        int fps = [obj[@"fps"] respondsToSelector:@selector(intValue)] ? [obj[@"fps"] intValue] : 30;
                        int br = [obj[@"bitrate"] respondsToSelector:@selector(intValue)] ? [obj[@"bitrate"] intValue] : 6000000;
                        stream_h264_loop(fd, fps, br);
                        close(fd); return;
                    }
                    if ([t isEqualToString:@"status"]) {
                        // Indique si l'injection est prete (senderID capture).
                        char line[64];
                        int m = snprintf(line, sizeof(line), "{\"ready\":%s}\n", gSenderID ? "true" : "false");
                        write(fd, line, m);
                        continue;
                    }
                    if ([t isEqualToString:@"rstest"]) {
                        // Teste la capture serveur-de-rendu : 30 rendus dans la
                        // surface reutilisee. Mesure la memoire libre avant/apres
                        // (doit rester stable = pas de churn), et renvoie la
                        // taille d'une frame + son debut hex pour verifier.
                        double f0 = free_mb();
                        NSData *last = nil;
                        double tr = 0;
                        for (int i = 0; i < 30; i++) {
                            @autoreleasepool {
                                double a = CFAbsoluteTimeGetCurrent();
                                NSData *j = capture_renderserver_jpeg(0.4f);
                                tr += CFAbsoluteTimeGetCurrent() - a;
                                if (j) last = j;
                            }
                        }
                        double f1 = free_mb();
                        // Ecrit une frame sur disque pour verification visuelle.
                        if (last) [last writeToFile:@"/var/jb/tmp/rs.jpg" atomically:YES];
                        char line[220];
                        int m = snprintf(line, sizeof(line),
                            "{\"ok\":%s,\"size\":%lu,\"ms_per\":%.1f,\"free_avant\":%.0f,\"free_apres\":%.0f}\n",
                            last ? "true" : "false", (unsigned long)(last ? last.length : 0),
                            tr / 30 * 1000, f0, f1);
                        write(fd, line, m);
                        continue;
                    }
                    if ([t isEqualToString:@"bench"]) {
                        // Micro-benchmark : separe le temps du rendu (main thread)
                        // de celui de la reduction+encodage (hors main). Dit ou est
                        // le goulot sans ecrire sur disque.
                        int w = [obj[@"w"] respondsToSelector:@selector(intValue)] ? [obj[@"w"] intValue] : 480;
                        double render = 0, encode = 0; int okc = 0;
                        for (int i = 0; i < 20; i++) {
                            double a = CFAbsoluteTimeGetCurrent();
                            __block CGImageRef s2 = NULL;
                            dispatch_sync(dispatch_get_main_queue(), ^{ @autoreleasepool {
                                UIImage *im = _UICreateScreenUIImage();
                                if (im && im.CGImage) s2 = CGImageRetain(im.CGImage);
                            }});
                            double b = CFAbsoluteTimeGetCurrent();
                            if (s2) {
                                CGImageRelease(s2);
                                NSData *j = capture_jpeg(w, 0.4f);
                                double c = CFAbsoluteTimeGetCurrent();
                                render += (b - a); encode += (c - b); okc++;
                                (void)j;
                            }
                        }
                        char line[160];
                        int m = snprintf(line, sizeof(line),
                            "{\"n\":%d,\"render_ms\":%.1f,\"total_ms\":%.1f}\n",
                            okc, okc ? render / okc * 1000 : 0, okc ? (render + encode) / okc * 1000 : 0);
                        write(fd, line, m);
                        continue;
                    }
                    if ([t isEqualToString:@"shotsock"]) {
                        // Capture PNG renvoyee SUR LA CONNEXION (plus de SSH) :
                        // [longueur 4 octets big-endian][octets PNG]. Longueur 0 =
                        // capture impossible (l'agent le traite comme un echec).
                        NSData *png = screenshot_png();
                        uint32_t nn = (uint32_t)(png ? png.length : 0);
                        uint8_t hdr[4] = { (uint8_t)(nn >> 24), (uint8_t)(nn >> 16), (uint8_t)(nn >> 8), (uint8_t)nn };
                        send_all(fd, hdr, 4);
                        if (nn) send_all(fd, png.bytes, png.length);
                        continue;
                    }
                    if ([t isEqualToString:@"readpbsock"]) {
                        // Presse-papier renvoye SUR LA CONNEXION (plus de SSH),
                        // meme cadrage : [longueur 4 octets][UTF-8]. Longueur 0 = vide.
                        NSData *pb = pasteboard_data();
                        uint32_t nn = (uint32_t)pb.length;
                        uint8_t hdr[4] = { (uint8_t)(nn >> 24), (uint8_t)(nn >> 16), (uint8_t)(nn >> 8), (uint8_t)nn };
                        send_all(fd, hdr, 4);
                        if (nn) send_all(fd, pb.bytes, pb.length);
                        continue;
                    }
                    if ([t isEqualToString:@"kill"]) {
                        // Ferme une app par nom de process, sans SSH.
                        id nm = obj[@"name"];
                        if ([nm isKindOfClass:[NSString class]]) kill_proc(nm);
                        continue;
                    }
                    handle_command(obj);
                }
            }
        }
    }
    close(fd);
}

static void *server_thread(void *arg) {
    (void)arg;
    gClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!gClient) { NSLog(@"[cherrytouch] client IOHID indisponible dans backboardd"); return NULL; }

    for (;;) {   // resiste a un rechargement : reessaie le bind si le port traine
        int server = socket(AF_INET, SOCK_STREAM, 0);
        if (server < 0) { sleep(2); continue; }
        int one = 1;
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        struct sockaddr_in addr = {0};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(kListenPort);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            close(server); sleep(2); continue;
        }
        listen(server, 8);
        NSLog(@"[cherrytouch] pret sur 127.0.0.1:%d", kListenPort);
        for (;;) {
            int client = accept(server, NULL, NULL);
            if (client < 0) break;
            // Un thread par client : un flux continu (stream) ne doit pas geler
            // le service des autres connexions (tap, shot).
            int *slot = malloc(sizeof(int));
            *slot = client;
            pthread_t ch;
            pthread_attr_t a;
            pthread_attr_init(&a);
            pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
            if (pthread_create(&ch, &a, client_thread, slot) != 0) {
                close(client);
                free(slot);
            }
            pthread_attr_destroy(&a);
        }
        close(server);
    }
    return NULL;
}

// Reveille l'ecran A LA DEMANDE (commande {"t":"wake"}), y compris depuis la
// veille PROFONDE (ecran eteint + verrouille + device idle). Cascade de voies,
// de la plus UNIVERSELLE a la plus specifique, toutes allumage-seul :
//   1. Bouton lateral (HID Consumer/Power) : equivalent d'un vrai appui bouton,
//      reveille quel que soit l'iOS. Envoye UNIQUEMENT si l'ecran est eteint
//      (garde displayStatus), sinon il l'endormirait. Teste OK iPhone X iOS 16.7
//      (displayStatus 0 -> 1 avec ce seul mecanisme).
//   2. IOKit PowerManagement (DeclareUserActivity) + BKSDisplayServicesSetScreen
//      Blanked(0) : redondance inoffensive, n'eteignent jamais.
//   3. SBBacklightController.turnOnScreenFullyWithBacklightSource: : rallumage
//      "propre" cote SpringBoard (marche iOS 16), inutile si le bouton a deja
//      reveille, mais gratuit et sans risque.
// Ensuite l'auto-lock iOS rendort l'ecran tout seul -> pas d'ecran allume H24.
//
// Surete : appele depuis handle_command (thread client detache). Les appels C /
// HID sont non bloquants. L'appel SpringBoard part en dispatch_async vers le main
// (non bloquant, jamais sync). Tout est garde : symbole/selecteur absent ou
// displayStatus indisponible (999) = etape sautee, jamais de crash, jamais de
// blocage du chargement, jamais de toggle (le bouton ne part que si ecran eteint).
typedef uint32_t ct_pm_aid_t;  // == IOPMAssertionID

// Etat physique de l'ecran (1=allume, 0=eteint) via notification systeme.
static uint64_t ct_display_status(void) {
    static int tok = -1;
    if (tok == -1) {
        if (notify_register_check("com.apple.iokit.hid.displayStatus", &tok) != NOTIFY_STATUS_OK) tok = -2;
    }
    uint64_t st = 999;
    if (tok >= 0) notify_get_state(tok, &st);
    return st;
}

static void wake_screen(void) {
    static kern_return_t (*declareUserActivity)(CFStringRef, int, ct_pm_aid_t *) = NULL;
    static void (*setBlanked)(int) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        declareUserActivity = (kern_return_t (*)(CFStringRef, int, ct_pm_aid_t *))
            dlsym(RTLD_DEFAULT, "IOPMAssertionDeclareUserActivity");
        void *bb = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY | RTLD_NOLOAD);
        if (!bb) bb = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
        if (bb) setBlanked = (void (*)(int))dlsym(bb, "BKSDisplayServicesSetScreenBlanked");
    });
    // 1) Voie UNIVERSELLE : bouton lateral, uniquement si l'ecran est eteint.
    if (ct_display_status() == 0) press_side_button();
    // 2) Redondances non bloquantes, allumage-seul.
    if (declareUserActivity) {
        static ct_pm_aid_t aid = 0;
        declareUserActivity(CFSTR("cherry-wake"), 0 /*kIOPMUserActiveLocal*/, &aid);
    }
    if (setBlanked) setBlanked(0);
    // 3) SBBacklightController (SpringBoard), sur le main thread (dispatch_async).
    Class blc = objc_getClass("SBBacklightController");
    if (blc) dispatch_async(dispatch_get_main_queue(), ^{
        id bl = ((id(*)(id, SEL))objc_msgSend)((id)blc, sel_registerName("sharedInstance"));
        if (!bl) return;
        SEL sTurn = sel_registerName("turnOnScreenFullyWithBacklightSource:");
        if ([bl respondsToSelector:sTurn])
            ((void(*)(id, SEL, long long))objc_msgSend)(bl, sTurn, (long long)1);
    });
}

__attribute__((constructor))
static void cherrytouch_init(void) {
    // Trace de diagnostic ecrite des le chargement, avant toute condition :
    // permet de savoir dans quel process ElleKit nous a injectes.
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"?";
        NSString *line = [NSString stringWithFormat:@"%@ ctor dans '%@' pid %d\n",
                          [NSDate date], proc, getpid()];
        FILE *f = fopen("/var/jb/tmp/cherrytouch-inject.log", "a");
        if (f) { fputs(line.UTF8String, f); fclose(f); }
    }
    // Plus de maintien-allume permanent : reveil A LA DEMANDE uniquement (voir
    // wake_screen). L'iPhone dort selon l'auto-lock iOS et se rallume sur {"t":"wake"}.
    start_sender_capture();
    start_mem_monitor();
    // Le filtre ElleKit garantit deja backboardd uniquement : on demarre le
    // serveur sans autre condition pour ne pas rater un nom de process inattendu.
    pthread_t th;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&th, &attr, server_thread, NULL);
    pthread_attr_destroy(&attr);
}
