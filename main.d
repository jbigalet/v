import std.stdio;
import std.conv;
import std.array;
import std.string;
import core.vararg;
import core.thread;
import std.algorithm;
import std.random;
import core.sys.posix.signal;
import core.stdc.stdlib;
import cstdio = core.stdc.stdio;
import core.sys.posix.sys.ioctl;
import std.functional;
import core.sys.posix.unistd;
import core.sys.linux.termios;
import std.typecons;
import std.process;
import std.mmfile;

import autogen.caps;
import keysym;

enum SIGWINCH = 28;

/*
   Info about the terminfo compiled format are hard to find,
   as almost everyone uses ncurses / tic / infocmp / tput

   Most relevant stuff was found on:

    - terminfo(5)   [! the capacity list is sorted by alphabetical order,
                       not in order of appearance in a terminfo file ]
                    [ it probably is generated by ncurses/man/MKterminfo.sh, which sorts it ]
    - Terminfo Source Format (ENHANCED CURSE) on the Single UNIX Specification - opengroup.org
    - unibilium's header description (unibilium/secret/terminfo.pod)


    - tic's source (ncurses/include/tic.h) [ only available resource with the
                                             ordered capacity table? ]

    A lot of ncurses' terminfo handling code seem to be generated using ncurses/include/Caps file
    There are a bunch of awk / makefile / sh scripts using it in ncurses/ncurses/tinfo/ and in ncurses/man

    TODO a bit more doc
*/

// TODO terminfo extended capacities

struct Terminfo {
    struct Header {
        ushort magic;
        ushort name_size;
        ushort bool_count;
        ushort num_count;
        ushort string_count;
        ushort table_size;
    };

    Header header;
    string name;
    string description;
    bool[] bools;
    ushort[] nums;
    char[][] strings;
}

Terminfo parse_terminfo(string path) {
    File f = File(path, "r");
    Terminfo ti;
    f.rawRead((&ti.header)[0..1]);
    assert(ti.header.magic == octal!432);

    // name <=> term_name | [ ... | ] description
    char[] _name_section = new char[ti.header.name_size];
    f.rawRead(_name_section);
    string name_section = cast(string)_name_section;
    string[] splitted_name = name_section.split("|");
    assert(splitted_name.length >= 2);
    ti.name = splitted_name[0];
    ti.description = splitted_name[$-1][0..$-1];  // remove trailing \0

    ti.bools = new bool[ti.header.bool_count];
    f.rawRead(ti.bools);

    if((ti.header.name_size + ti.header.bool_count) % 2 != 0)
        f.seek(1, SEEK_CUR);  // padding

    ti.nums = new ushort[ti.header.num_count];
    f.rawRead(ti.nums);

    // string table

    ushort[] string_offsets = new ushort[ti.header.string_count];
    f.rawRead(string_offsets);
    char[] string_table = new char[ti.header.table_size];
    f.rawRead(string_table);
    ti.strings = new char[][ti.header.string_count];
    foreach(i, off; string_offsets)
        if(off != 0xffff) {
            assert(off < 0x7fff);
            long string_end = indexOf(string_table, '\0', off);
            if(off == string_end) {
                ti.strings[i] = new char[0];
            } else {
                assert(string_end > off,
                       format("index error %d, at %d, offset %u",
                              string_end, i, off));
                ti.strings[i] = string_table[off..string_end];
            }
        }

    return ti;
}

void print_term_caps(const ref Terminfo ti) {
    writeln("bools:");
    foreach(i, b; ti.bools)
        if(b)
            writefln("\t%s", cast(bool_caps)i);

    writeln();
    writeln("nums:");
    foreach(i, n; ti.nums)
        if(n != 0xffff)
            writefln("\t%s = %d", cast(num_caps)i, n);

    /* writeln(); */
    /* writeln("strings:"); */
    /* foreach(i, s; ti.strings) */
    /*     if(s.length != 0) */
    /*         writefln("\t%s = %s", cast(str_caps)i, ti.strings[i]); */
}


// TODO very slow to do this every time (setb/g strings are pretty huge for instance)
// TODO string cap interpretation only supports int args atm
// (xterm & rxvt only seem to need ints)
// but the spec allows string as arguments
// TODO 'u6' cap does a %d with nothing on the stack...

string _interpret_cap(string s, ref uint i, ref int[] stack, ref int[] args, bool eval) {
    // i <=> string index
    string o = "";
    while(i < s.length) {
        char c = s[i++];
        if(c != '%') {
            if(eval)
                o ~= c;
        } else {
            c = s[i++];
            switch(c) {
                case '%':
                    if(!eval) break;
                    o ~= '%';
                    break;

                case 'd':
                    if(!eval) break;
                    assert(stack.length > 0);
                    o ~= to!string(stack.back);
                    stack.popBack();
                    break;

                case 'p':
                    if(!eval) break;
                    char n = s[i++];
                    assert(n >= '1' && n <= '9');
                    int arg_idx = (n - '1');
                    assert(arg_idx < args.length);
                    stack ~= args[arg_idx];
                    break;

                case 'i':
                    if(!eval) break;
                    if(args.length > 0) args[0]++;
                    if(args.length > 1) args[1]++;
                    break;

                case '{':
                    int n = 0;
                    while(true) {
                        char d = s[i++];
                        if(d == '}')
                            break;
                        else if(d >= '0' && d <= '9')
                            n = 10*n + (d - '0');
                        else
                            assert(0);
                    }
                    if(!eval) break;
                    stack ~= n;
                    break;

                case '?':
                    o ~= _interpret_cap(s, i, stack, args, eval);  // read & interpret everything inside the condition
                    assert(s[i] == 't');
                    i++;
                    bool current_eval = eval;
                    while(true) {
                        bool eval_then = false;
                        bool eval_else = false;
                        if(current_eval) {
                            assert(stack.length > 0);
                            if(stack.back != 0)
                                eval_then = true;
                            else
                                eval_else = true;
                            stack.popBack();
                        }
                        o ~= _interpret_cap(s, i, stack, args, eval_then);
                        char next = s[i++];
                        if(next == ';')
                            break;
                        assert(next == 'e');
                        o ~= _interpret_cap(s, i, stack, args, eval_else);
                        next = s[i++];
                        if(next == ';')
                            break;
                        assert(next == 't', "expected ; or t after e, got " ~ to!string(next));  // "else-if a la Algol 68"
                        current_eval = eval_else;
                    }
                    break;

                // TODO autogen logical operations
                case '>':
                    if(!eval) break;
                    assert(stack.length >= 2);
                    int a = stack.back;
                    stack.popBack();
                    int b = stack.back;
                    stack.popBack();
                    stack ~= (b > a) ? 1 : 0;  // TODO seemed more logical to swap the args but its against the spec, which may no be correct
                    break;

                case '=':
                    if(!eval) break;
                    assert(stack.length >= 2, "trying to eval = but cannot pop twice. stack is: " ~ to!string(stack) ~ ", before: " ~ s[0..i] ~ " ; after: " ~ s[i+1..$]);
                    int a = stack.back;
                    stack.popBack();
                    int b = stack.back;
                    stack.popBack();
                    stack ~= (b == a) ? 1 : 0;  // TODO seemed more logical to swap the args but its against the spec, which may no be correct
                    break;

                case ';':
                case 'e':
                case 't':
                    i--;
                    return o;

                // TODO handle everything else
                default: assert(0, "unknown cap param type %" ~ to!string(c));
            }
        }
    }
    return o;
}

string interpret_string_cap(ref Terminfo ti, str_caps cap, int[] args...) {
    // TODO asserts should also crash in release mode
    assert(cap < ti.header.string_count && ti.strings[cap].length > 0);
    string s = ti.strings[cap].idup;
    assert(s.indexOf('<') == -1);  // TODO
    assert(s.indexOf('^') == -1);  // TODO
    assert(s.indexOf("%s") == -1);  // TODO

    int[] stack;
    uint str_idx = 0;
    string o = _interpret_cap(s, str_idx, stack, args, true);
    assert(str_idx == s.length);
    return o;
}


struct Terminal {
    Terminfo info;
    int width;
    int height;
    Nullable!termios old_termios;
    bool ca_mode = false;

    void update_size() {
        winsize size;
        ioctl(0, TIOCGWINSZ, &size);
        width  = size.ws_col;
        height = size.ws_row;
    }

    /* void interpret_cap(str_caps cap)(int[] args...) { */
    /*     write(interpret_string_cap(this.info, cap, args)); */
    /* } */

    @property auto opDispatch(string name, T...)(T args) {
        static if(name == "enter_ca_mode")
            ca_mode = true;
        else static if(name == "exit_ca_mode")
            ca_mode = false;

        return write(mixin("interpret_string_cap(this.info, str_caps." ~ name ~ ", args)"));
        /* return toDelegate(mixin("&interpret_cap!(str_caps." ~ name ~ ")")); */
    }
}


Terminal term;  // for the signal handlers
Buffer main_buf;
View main_view;

extern(C)
void size_update_handler(int d=0) {
    term.update_size();
    main_view.redraw();
}

void cleanup_term() {
    if(term.ca_mode)
        term.exit_ca_mode();

    if(!term.old_termios.isNull()) {
        tcsetattr(STDIN_FILENO, TCSANOW, &term.old_termios.get());
        term.old_termios.nullify();
    }

    writeln("cleaning up...");
}

extern(C) void sigint_handler(int d) {
    cleanup_term();
    writeln("caught sigint");
    /* exit(1); */  // TODO
    assert(0);
}

extern(C) void sigsegv_handler(int d) {
    cleanup_term();
    writeln("caught sigsegv");
    /* exit(1); */
    assert(0);
}


// Xlib bindings

struct Display;
alias ulong Window;

// TODO make mixin generating bitflags
enum EventMask : long {
    NoEventMask              = 0,
    KeyPressMask             = 1 << 0,
    KeyReleaseMask           = 1 << 1,
    ButtonPressMask          = 1 << 2,
    ButtonReleaseMask        = 1 << 3,
    EnterWindowMask          = 1 << 4,
    LeaveWindowMask          = 1 << 5,
    PointerMotionMask        = 1 << 6,
    PointerMotionHintMask    = 1 << 7,
    Button1MotionMask        = 1 << 8,
    Button2MotionMask        = 1 << 9,
    Button3MotionMask        = 1 << 10,
    Button4MotionMask        = 1 << 11,
    Button5MotionMask        = 1 << 12,
    ButtonMotionMask         = 1 << 13,
    KeymapStateMask          = 1 << 14,
    ExposureMask             = 1 << 15,
    VisibilityChangeMask     = 1 << 16,
    StructureNotifyMask      = 1 << 17,
    ResizeRedirectMask       = 1 << 18,
    SubstructureNotifyMask   = 1 << 19,
    SubstructureRedirectMask = 1 << 20,
    FocusChangeMask          = 1 << 21,
    PropertyChangeMask       = 1 << 22,
    ColormapChangeMask       = 1 << 23,
    OwnerGrabButtonMask      = 1 << 24,
}

enum EventType : int {
    KeyPress = 2,
    KeyRelease,
    ButtonPress,
    ButtonRelease,
    MotionNotify,
    EnterNotify,
    LeaveNotify,
    FocusIn,
    FocusOut,
    KeymapNotify,
    Expose,
    GraphicsExpose,
    NoExpose,
    VisibilityNotify,
    CreateNotify,
    DestroyNotify,
    UnmapNotify,
    MapNotify,
    MapRequest,
    ReparentNotify,
    ConfigureNotify,
    ConfigureRequest,
    GravityNotify,
    ResizeRequest,
    CirculateNotify,
    CirculateRequest,
    PropertyNotify,
    SelectionClear,
    SelectionRequest,
    SelectionNotify,
    ColormapNotify,
    ClientMessage,
    MappingNotify,
    GenericEvent,
    LASTEvent,
}



// TODO bind yet to be binded sub events

// X's bool type is an int -_-
enum Bool : int {
    False,
    True
}

struct XKeyEvent {
    int type;                /* of event */
    ulong serial;            /* # of last request processed by server */
    Bool send_event;         /* true if this came from a SendEvent request */
    Display* display;        /* Display the event was read from */
    Window window;           /* "event" window it is reported relative to */
    Window root;             /* root window that the event occurred on */
    Window subwindow;        /* child window */
    ulong time;              /* milliseconds */
    int x, y;                /* pointer x, y coordinates in event window */
    int x_root, y_root;      /* coordinates relative to root */
    uint state;              /* key or button mask */
    uint keycode;            /* detail */
    Bool same_screen;        /* same screen flag */
}

alias XKeyPressedEvent  = XKeyEvent;
alias XKeyReleasedEvent = XKeyEvent;

union XEvent {
    int type;
    /* XAnyEvent xany; */
    XKeyEvent xkey;
    /* XButtonEvent xbutton; */
    /* XMotionEvent xmotion; */
    /* XCrossingEvent xcrossing; */
    /* XFocusChangeEvent xfocus; */
    /* XExposeEvent xexpose; */
    /* XGraphicsExposeEvent xgraphicsexpose; */
    /* XNoExposeEvent xnoexpose; */
    /* XVisibilityEvent xvisibility; */
    /* XCreateWindowEvent xcreatewindow; */
    /* XDestroyWindowEvent xdestroywindow; */
    /* XUnmapEvent xunmap; */
    /* XMapEvent xmap; */
    /* XMapRequestEvent xmaprequest; */
    /* XReparentEvent xreparent; */
    /* XConfigureEvent xconfigure; */
    /* XGravityEvent xgravity; */
    /* XResizeRequestEvent xresizerequest; */
    /* XConfigureRequestEvent xconfigurerequest; */
    /* XCirculateEvent xcirculate; */
    /* XCirculateRequestEvent xcirculaterequest; */
    /* XPropertyEvent xproperty; */
    /* XSelectionClearEvent xselectionclear; */
    /* XSelectionRequestEvent xselectionrequest; */
    /* XSelectionEvent xselection; */
    /* XColormapEvent xcolormap; */
    /* XClientMessageEvent xclient; */
    /* XMappingEvent xmapping; */
    /* XErrorEvent xerror; */
    /* XKeymapEvent xkeymap; */
    long[24] pad;
};

struct XComposeStatus {
    char* compose_ptr;
    int chars_matched;
}

extern (C) Display* XOpenDisplay(const char*);
extern (C) int XSelectInput(Display*, Window, EventMask);
extern (C) int XNextEvent(Display*, XEvent*);
extern (C) Bool XkbSetDetectableAutoRepeat(Display*, Bool, Bool*);
extern (C) KeySym XLookupKeysym(XKeyEvent*, int);
extern (C) int XLookupString(XKeyEvent*, char*, int, KeySym*, XComposeStatus*);

enum EditMode {
    normal,
    insert,
}

struct VState {
    EditMode mode = EditMode.normal;
}
VState vstate = VState.init;

// area holding characters - either a readonly mmap buffer or a append only buffer
class Block {
    enum Type {
        mmaped,
        allocated,
    };
    Type type;
    union {
        MmFile file;
        struct {
            ulong current_size;
            char[] data;
        }
    }
}

// intrusive double linked list. a piece (or 'span') points to a chunk of text inside a Block
class Piece {
    char[] data;
    Piece prev = null;
    Piece next = null;
    Block block;
    Buffer buffer;

    bool is_sentinel() {
        return data.length == 0;
    }
}

// TODO not a great name
// not a buffer in the programming sense, but in 'text editor buffer' sense
// - a modified (or not) text file
class Buffer {
    Piece begin;  // sentinels
    Piece end;

    Block current_block;  // current block with some place left

    static Buffer fromFile(string name) {
        Buffer b = new Buffer();

        Block block = new Block();
        block.type = Block.Type.mmaped;
        block.file = new MmFile(name);

        b.begin = new Piece();
        b.begin.data = new char[0];
        b.begin.buffer = b;
        b.end = new Piece();
        b.end.data = new char[0];
        b.end.buffer = b;

        Piece piece = new Piece();
        piece.prev = b.begin;
        piece.next = b.end;
        piece.data = cast(char[])block.file[0..block.file.length()];
        piece.block = block;
        piece.buffer = b;

        b.begin.prev = null;
        b.begin.next = piece;
        b.end.prev = piece;
        b.end.next = null;

        return b;
    }
}

struct Location {
    Piece piece = null;
    ulong offset = 0;

    invariant {
        assert(offset < 1000000);
    }

    bool valid() {
        return piece !is null && !piece.is_sentinel();
    }

    static Location invalid = Location(null, 0);

    Location opBinary(string op)(long n) {
        if(n == 0)
            return this;

        // TODO this could be shorter

        static if(op == "+") {
            if(n < 0)
                return this - (-n);

            if(piece.next is null)
                return this;

            if(piece.prev is null)  // 'begin' sentinel
                return Location(piece.next, 0) + (n - 1);

            assert(piece.data.length > 0);
            if(offset + n <= piece.data.length-1)
                return Location(piece, offset+n);

            if(piece.next.next is null)  // next is the end sentinel
                return Location(piece.next, 0);

            assert(offset + n >= piece.data.length);
            return Location(piece.next, 0)
                 + (offset + n - piece.data.length);

        } else static if(op == "-") {
            if(n < 0)
                return this + (-n);

            if(piece.prev is null)
                return this;

            if(piece.next is null) {  // 'end' sentinel
                assert(piece.prev.data.length > 0);
                return Location(piece.prev, piece.prev.data.length-1) - (n-1);
            }

            if(offset >= n)
                return Location(piece, offset - n);

            if(piece.prev.prev is null)  // previous is the begin sentinel
                return Location(piece.prev, 0);

            assert(n-cast(long)offset-1 >= 0);
            assert(piece.prev.data.length > 0);
            return Location(piece.prev, piece.prev.data.length-1)
                 - (n - offset - 1);

        } else {
            static assert(0, "Location does not support binary operator '" ~ op ~ "'");
        }
    }

    char opUnary(string op)() if(op == "*") {
        /* assert(piece != null && !piece.is_sentinel()); */
        if(piece is null || piece.is_sentinel())  // TODO =(
            return '\0';
        return piece.data[offset];
    }

    Location opUnary(string op)() if(op != "*") {
        static if(op == "++") {
            this = this + 1;
            return this;
        } else static if(op == "--") {
            this = this - 1;
            return this;
        } else {
            static assert(0, "Location does not support unary operator '" ~ op ~ "'");
        }
    }
}

Location find_before(Location l, char c) {
    /* if(!l.valid()) return Location.invalid; */
    while(l.valid())
        if(*(--l) == c)
            return l;
    /* return Location.invalid; */
    return l;
}

Location find_after(Location l, char c) {
    if(*l == c) return l;
    while(l.valid())
        if(*(++l) == c)
            return l;
    /* return Location.invalid; */
    return l;
}

ulong dist_to_line_start(Location l) {
    ulong r;
    while(l.valid()) {
        r++;
        if(*(--l) == '\n')
            break;
    }
    return r;
}

// inserts 'text' before cursor at 'l'
void insert(Location l, string text) {
    Block block = l.piece.buffer.current_block;
    if(block is null || block.current_size + text.length < block.data.length) {
        l.piece.buffer.current_block = new Block();
        l.piece.buffer.current_block.type = Block.Type.allocated;
        l.piece.buffer.current_block.current_size = 0;
        l.piece.buffer.current_block.data = new char[1 << 20];
        block = l.piece.buffer.current_block;
    }

    block.data[block.current_size..block.current_size+text.length] = text;

    // TODO copy pasta

    Piece piece = new Piece();
    piece.data = block.data[block.current_size..block.current_size+text.length];
    piece.block = block;
    piece.buffer = l.piece.buffer;

    if(l.offset == 0) {
        piece.prev = l.piece.prev;
        piece.next = l.piece;

        piece.prev.next = piece;
        piece.next.prev = piece;

        main_view.top_left = Location(l.piece.buffer.begin.next, 0);
        main_view.cursor = Location(piece, 0);

    } else {
        Piece before = new Piece();
        before.data = l.piece.data[0..l.offset];
        before.block = l.piece.block;
        before.buffer = l.piece.buffer;
        before.prev = l.piece.prev;
        before.next = piece;

        Piece next = new Piece();
        next.data = l.piece.data[l.offset..$];
        next.block = l.piece.block;
        next.buffer = l.piece.buffer;
        next.prev = piece;
        next.next = l.piece.next;

        piece.prev = before;
        piece.next = next;

        before.prev.next = before;
        next.next.prev = next;

        main_view.top_left = Location(l.piece.buffer.begin.next, 0);
        main_view.cursor = Location(piece, 0);
    }
}

// 'view' of a buffer
class View {
    Buffer* buf;
    Location top_left;
    Location cursor;

    this(Buffer* buffer) {
        assert(buffer != null);
        buf = buffer;
        top_left = Location( buf.begin.next, 0 );
        cursor = top_left;
    }
}

void redraw(View v) {
    Location loc = v.top_left;
    uint col = 0;
    uint line = 0;
    term.cursor_address(0, 0);
    bool restore_cursor_color = true;
    while(line < term.height && loc.valid()) {
        if(restore_cursor_color) {
            restore_cursor_color = false;
            term.set_background(0);
            term.set_foreground(7);
        }

        if(loc == v.cursor) {
            term.set_background(7);
            term.set_foreground(0);
            restore_cursor_color = true;
        }

        char c = *loc;
        loc++;
        if(c == '\n') {
            term.clr_eol();
            line++;
            col = 0;
            term.cursor_address(line, col);
        } else {
            write(c);
            col++;
        }

        if(col >= term.width) {
            line++;
            col = 0;
            term.cursor_address(line, col);
        }
    }
    term.clr_eos();
    stdout.flush();
}

void main(string[] args) {
    Terminfo ti = parse_terminfo("/usr/share/terminfo/r/rxvt-unicode-256color");  // TODO path not hardcoded
    term = Terminal(ti);
    term.update_size();

    // setup stdin in mode. On exit, restore the old state
    termios[10] old_termios;  // there seem to be junk after the real termios info, loaded by tcgetattr. to avoid overwriting the world, we have a dummy array (but actually only use the 1st item) TODO =(
    tcgetattr(STDIN_FILENO, &old_termios[0]);
    term.old_termios = old_termios[0];

    scope(exit) cleanup_term();
    sigset(SIGWINCH, &size_update_handler);
    sigset(SIGINT,   &sigint_handler);
    sigset(SIGSEGV,  &sigsegv_handler);

    termios new_termios = old_termios[0];
    new_termios.c_lflag &= ~(ECHO | ICANON);
    tcsetattr(STDIN_FILENO, TCSANOW, &new_termios);

    string s_window_id = environment.get("WINDOWID");
    if(s_window_id is null) assert(0);
    int window_id = to!int(s_window_id);
    writeln("window id: ", window_id);

    Display* display = XOpenDisplay(null);
    Window current_window = window_id;
    XSelectInput(display, current_window, EventMask.KeyPressMask | EventMask.KeyReleaseMask);

    // dont emit 'release' events on keyrepeat, only 'pressed' ones
    Bool supported;
    XkbSetDetectableAutoRepeat(display, Bool.True, &supported);

    term.enter_ca_mode();
    term.clear_screen();
    term.cursor_invisible();
    stdout.flush();

    bool[] downed_key = new bool[KeySym.max];

    main_buf = Buffer.fromFile("Makefile");
    main_view = new View(&main_buf);
    while(true) {
        main_view.redraw();

        XEvent ev;
        XNextEvent(display, &ev);
        switch(ev.type) {
            case EventType.KeyPress:
            {
                char str;
                KeySym key;
                int strlen = XLookupString(&ev.xkey, &str, 1, &key, null);
                bool is_repeat = downed_key[key];
                downed_key[key] = true;

                switch(vstate.mode) {
                    case EditMode.normal:
                    {

                        // C-y
                        if(key == KeySym.y && downed_key[KeySym.Control_L]) {
                            Location loc = find_before(main_view.top_left-1, '\n');
                            main_view.top_left = loc + 1;

                        // C-e
                        } else if(key == KeySym.e && downed_key[KeySym.Control_L]) {
                            Location loc = find_after(main_view.top_left, '\n');
                            if(loc.valid())
                                main_view.top_left = loc + 1;

                        // C-d
                        } else if(key == KeySym.d && downed_key[KeySym.Control_L]) {
                            for(uint i=0 ; i<term.height/2 ; i++) {
                                Location loc = find_after(main_view.top_left, '\n');
                                if(loc.valid())
                                    main_view.top_left = loc + 1;
                                else
                                    break;
                            }

                        // C-u
                        } else if(key == KeySym.u && downed_key[KeySym.Control_L]) {
                            for(uint i=0 ; i<term.height/2 ; i++) {
                                Location loc = find_before(main_view.top_left-1, '\n');
                                main_view.top_left = loc + 1;
                            }

                        // 'arrows'
                        } else if(key == KeySym.j) {
                            Location loc = main_view.cursor - 1;
                            if(loc.valid() && *loc != '\n')
                                main_view.cursor--;

                        } else if(key == KeySym.m) {
                            Location loc = main_view.cursor + 1;
                            if(loc.valid() && *loc != '\n')
                                main_view.cursor++;

                        } else if(key == KeySym.k) {
                            Location loc = find_after(main_view.cursor, '\n');
                            if(loc.valid()) {
                                ulong line_offset = dist_to_line_start(main_view.cursor);
                                for(uint i=0 ; i<line_offset ; i++)
                                    if(*(++loc) == '\n')
                                        break;

                                if(loc.valid())
                                    main_view.cursor = loc;
                            }

                        } else if(key == KeySym.l) {
                            long line_offset = dist_to_line_start(main_view.cursor);
                            Location loc = main_view.cursor - line_offset;
                            if(loc.valid()) {
                                long previous_line_length = dist_to_line_start(loc);
                                Location new_loc = loc - max(0, previous_line_length-line_offset);
                                if(new_loc.valid())
                                    main_view.cursor = new_loc;
                            }

                        } else if(key == KeySym.dollar) {
                            main_view.cursor = find_after(main_view.cursor, '\n');

                        } else if(key == KeySym._0) {
                            main_view.cursor = find_before(main_view.cursor, '\n') + 1;

                        } else if(key == KeySym.i) {
                            vstate.mode = EditMode.insert;

                        }

                        break;
                    }  // end case normal mode

                    case EditMode.insert:
                    {

                        if(key == KeySym.Escape) {
                            vstate.mode = EditMode.normal;

                        } else if(strlen == 1) {
                            /* insert(main_view.cursor, "-plop-"); */
                            insert(main_view.cursor, to!string(str));
                            main_view.cursor++;
                        }

                        break;
                    }  // end case insert mode

                    default: assert(0);

                }  // end switch on mode

                break;
            }  // end case key press

            case EventType.KeyRelease:
            {
                char str;
                KeySym key;
                int strlen = XLookupString(&ev.xkey, &str, 1, &key, null);
                downed_key[key] = false;
                break;
            }

            default: assert(0);
        }
    }
}
